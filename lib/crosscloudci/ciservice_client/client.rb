require 'logger'
require 'base64'
require 'faraday'
require 'gitlab/gitlab_proxy'

module CrossCloudCi
  class CiServiceError < StandardError
  end
end

module CrossCloudCI
  module CiService
    class Client
      attr_accessor :logger
      attr_accessor :config
      attr_accessor :config_repo
      attr_accessor :gitlab_proxy
      attr_accessor :projects, :active_projects,  :all_gitlab_projects, :active_gitlab_projects, :active_clouds
      attr_accessor :builds, :builds2, :app_deploys, :provisionings


      #def initialize(options = {})
      def initialize(config)
        @config = config
        @logger = Logger.new(STDOUT)
        #@logger.level = Logger::DEBUG
        @logger.level = Logger::INFO

        @project_name_id_mapping = {}
        @builds = { :provision_layer => [], :app_layer => [] }
        @builds2 = []
        @provisionings = []
        @app_deploys = []

        @gitlab_proxy = CrossCloudCI::GitLabProxy.proxy(:endpoint => @config[:gitlab][:api_url], :api_token => @config[:gitlab][:api_token])

        load_project_data
        load_cloud_data
        #@gitlab_proxy = CrossCloudCI::GitLabProxy.proxy(:endpoint => options[:endpoint], :api_token => options[:api_token])
      end

      def build_project(project_id, ref, options = {})
        project_name = project_name_by_id(project_id)

        if options[:api_token]
          api_token = options[:api_token]
        else
          api_token = @config[:gitlab][:pipeline][project_name][:api_token]
        end

        trigger_variables = {}

        # @logger.info "[Build] #{project_name} project id: #{project_id}, api token: #{api_token}, ref:#{ref}, #{options}"

        trigger_variables[:DASHBOARD_API_HOST_PORT] = options[:dashboard_api_host_port] unless options[:dashboard_api_host_port].nil?
        trigger_variables[:CROSS_CLOUD_YML] = @config[:cross_cloud_yml]

        case ref 
        when "master"
          pipeline_release_type = "head"
        else
          pipeline_release_type = "stable"
        end

        trigger_variables[:PIPELINE_RELEASE_TYPE] = pipeline_release_type 

        arch = options[:arch] || "amd64"
        trigger_variables[:ARCH] = arch

        # @logger.info "options[:arch] #{options[:arch]}"
        #
        # @logger.info "trigger_variables[:ARCH] #{trigger_variables[:ARCH]}"


        # TODO: Lookup arch support for each project.  
        # # NOTE: Only supporting k8s for arm 
        # if project_name != "kubernetes" and arch != "amd64"
        #     @logger.info "[Build] No #{arch} support for #{project_name}"
        #     return
        # end

        gitlab_result = nil
        tries=3
        begin
          @logger.debug "[Build] calling Gitlab API for #{project_name} trigger_pipeline(#{project_id}, #{api_token}, #{ref}, #{trigger_variables})"
          gitlab_result = @gitlab_proxy.trigger_pipeline(project_id, api_token, ref, trigger_variables)
          @logger.debug "[Build] gitlab proxy result: #{gitlab_result.inspect}"
        rescue Gitlab::Error::InternalServerError => e
          @logger.error "[Build] Gitlab Proxy error: #{e}"

          tries -= 1
          if tries > 0
            @logger.info "[Build] Trying to trigger pipeline for project #{project_name} again: #{project_id}, ref #{ref}"
            retry
          else
            @logger.error "[Build] Failed to trigger pipeline for project #{project_name}: #{project_id}, ref #{ref}"
            return
          end
        end


        gitlab_pipeline_id = gitlab_result.id
        data = {  project_name: project_name, ref: ref, project_id: project_id, pipeline_id: gitlab_pipeline_id, arch: arch}
        if @config[:projects][project_name]["app_layer"]
          @builds[:app_layer] << data
        else
          @builds[:provision_layer] << data
        end
        #@builds2 << CrossCloudCI::CiService::Build.new(project_id, build_id, project_name, ref)
        data
      end

      # TODO: create generic pipeline_status method
      #     - should take list of jobs (or pull from config)
      #
      #def pipeline_status(project_name, build_id, jobs_array)
      #end

      def build_status(project_id, build_id)
        # TODO: look up project_id based on "cross-project" and remove arg project_id

        # TODO: wrap in exception handling
        jobs = @gitlab_proxy.get_pipeline_jobs(project_id, build_id)

        # TODO: use jobs from cross-cloud.yml
        job = jobs.select {|j| j["name"] == "compile"}
        unless job.empty?
          #status = job.first["status"]
          case job.first["status"]
          when "success"
            status = nil
          else
            status = job.first["status"]
          end
        end

        job = jobs.select {|j| j["name"] == "baseimage"}
        unless job.empty? || job.first["status"] == "created"
          # compile is higher precendent than compile-aufs or compile-overlayfs
          status ||= job.first["status"]
        end

        job = jobs.select {|j| j["name"] == "baseimage-arm"}
        unless job.empty? || job.first["status"] == "created"
          # compile is higher precendent than compile-aufs or compile-overlayfs
          status ||= job.first["status"]
        end

        job = jobs.select {|j| j["name"] == "compile"}
        unless job.empty? || job.first["status"] == "created"
          # compile is higher precendent than compile-aufs or compile-overlayfs
          status ||= job.first["status"]
        end

        job = jobs.select {|j| j["name"] == "compile-arm"}
        unless job.empty? || job.first["status"] == "created"
          # compile is higher precendent than compile-aufs or compile-overlayfs
          status ||= job.first["status"]
        end

        job = jobs.select {|j| j["name"] == "container"}
        unless job.empty? || job.first["status"] == "created"
          status = job.first["status"]
        end

        job = jobs.select {|j| j["name"] == "container-arm"}
        unless job.empty? || job.first["status"] == "created"
          # compile is higher precendent than container-aufs or container-overlayfs
          status ||= job.first["status"]
        end

        status
      end

      def k8s_nightly_sha
        #`curl -q -s https://storage.googleapis.com/kubernetes-release-dev/ci-cross/latest.txt`
        k8s_cross_latest_url="https://storage.googleapis.com/kubernetes-release-dev/ci-cross/latest.txt"
        response = Faraday.get k8s_cross_latest_url 
        if response.nil?
          @logger.fatal "Failed to retrieve latest k8s ci-cross release from #{k8s_cross_latest_url}"
          exit 1
        end
        response.body
      end

      def sync_k8s_nightly_build
        k8s_sha = k8s_nightly_sha
        git_host = @config[:gitlab][:base_url].sub(/^https?\:\/\//, '')
        sync_k8s_build(git_host, k8s_sha)
      end

      def sync_k8s_build(git_host, k8s_sha)
        sync_k8s = File.expand_path 'bin/sync-gitlab-kubernetes.sh' 
        puts "sync_k8s_build external script: #{sync_k8s}"
        puts "sync_k8s_build git host: #{git_host}, k8s sha: #{k8s_sha}"
        `#{sync_k8s} #{git_host} #{k8s_sha}`
      end

      # Separated out so that the tests can stub
      def build_delay
        sleep 120
      end

      # Purpose: loop through all active projects and call build project for each
      def build_active_projects
        load_project_data
        @active_projects.each do |proj|
          name = proj[0]

          puts "Active project: #{name}"

          @logger.debug "setting trigger variables"
          options = {:dashboard_api_host_port => @config[:dashboard][:dashboard_api_host_port], :cross_cloud_yml => @config[:cross_cloud_yml]}

          @logger.debug "setting project id"
          project_id =  all_gitlab_projects.select {|agp| agp["name"].downcase == name}.first["id"]
          project_name = project_name_by_id(project_id)

          if project_name == "kubernetes"
            @logger.debug "Syncing nightly build for #{project_name} HEAD release and pushing up all tags"
            # mirror off in gitlab.   
            sync_k8s_nightly_build
          end
          
          ["stable_ref", "head_ref"].each do |release_key_name|
            #next if name == "kubernetes" and release_key_name == "head_ref"
            ref = @config[:projects][name][release_key_name]

            # @logger.debug "project name #{project_name}"

            # TODO: check for arch support on the provider?
            arch_types = @config[:projects][project_name]["arch"]
            # @logger.debug "config projects #{@config[:projects]}"
            if arch_types.nil? 
              arch_types = ["amd64"]
            end
            @logger.debug "arch types for #{project_name} #{arch_types}"
            # arch_types = ["amd64", "arm64"]

            arch_types.each do |machine_arch|
              options[:arch] = machine_arch

              # Prom builds will clash if they run at the same time due to the names being based on the timestamp.
              # See https://github.com/prometheus/promu/blob/d629dfcdec49387b42164f3fe6dad353f922557e/cmd/crossbuild.go#L198
              if project_name == "prometheus"
                puts 'Starting prometheus build delay'
                build_delay
              end

              puts "Calling build_project(#{project_id}, #{ref}, #{options})"
              #self.build_project(project_id, api_token, ref, options)
              self.build_project(project_id, ref, options)
            end
          end
        end
      end




      # provision_cloud()
      #
      # Args
      #   - cloud - name of cloud to provision as a string. eg. "aws"
      #   - options hash
      #     * dashboard_api_host_port: host and port for dashboard
      #     * cross_cloud_yml: url for cross-cloud config
      #     * kubernetes_build_id: pipeline for kubernetes build to use for provisioning
      #     * kubernetes_ref: ref for kubernetes to provision (used to determine "release" on dashboard
      #     * OPTIONAL => api_token: Gitlab token for cross-cloud pipeline
      #
      #     TODO: pull dashboard info from config
      #     TODO: lookup ref from pipeline?
      def provision_cloud(cloud, options = {})
        trigger_variables = {}

        # GitLab pipeline to trigger
        project_name = "cross-cloud"
        project_id = project_id_by_name("cross-cloud")
        # related to environment, eg. cidev, master, staging, production
        #
        # TODO: use ref from yaml
        trigger_ref = options[:provision_ref]

        @logger.debug "setting api token for #{project_name}"
        if options[:api_token]
          api_token = options[:api_token]
        else
          api_token = @config[:gitlab][:pipeline][project_name][:api_token]
        end

        #@logger.debug "#{project_name} project id: #{project_id}, api token: #{api_token}, ref:#{ref}"
        @logger.debug "options var: #{options.inspect}"

        trigger_variables[:CLOUD] = cloud

        target_project_name = "kubernetes"
        target_project_id = project_id_by_name(target_project_name)
        kubernetes_project_id = target_project_id
        target_project_ref = options[:kubernetes_ref] unless options[:kubernetes_ref].nil?

        trigger_variables[:SOURCE] = options[:kubernetes_build_id] unless options[:kubernetes_build_id].nil?
        trigger_variables[:PROJECT_ID] = kubernetes_project_id
        trigger_variables[:PROJECT_BUILD_PIPELINE_ID] = options[:kubernetes_build_id] unless options[:kubernetes_build_id].nil?

        trigger_variables[:TARGET_PROJECT_ID] = target_project_id
        trigger_variables[:TARGET_PROJECT_NAME] = target_project_name
        trigger_variables[:TARGET_PROJECT_COMMIT_REF_NAME] = target_project_ref

        trigger_variables[:DASHBOARD_API_HOST_PORT] = options[:dashboard_api_host_port] unless options[:dashboard_api_host_port].nil?
        #trigger_variables[:CROSS_CLOUD_YML] = options[:cross_cloud_yml] unless options[:cross_cloud_yml].nil?
        trigger_variables[:CROSS_CLOUD_YML] = @config[:cross_cloud_yml]

        arch = options[:arch] || "amd64"
        trigger_variables[:ARCH] = arch

        case target_project_ref 
        when "master"
          pipeline_release_type = "head"
        else
          pipeline_release_type = "stable"
        end

        trigger_variables[:PIPELINE_RELEASE_TYPE] = pipeline_release_type 

        gitlab_result = nil
        tries=3
        begin
          @logger.debug "Calling Gitlab API for #{project_name} trigger_pipeline(#{project_id}, #{api_token}, #{trigger_ref}, #{trigger_variables})"
          gitlab_result = @gitlab_proxy.trigger_pipeline(project_id, api_token, trigger_ref, trigger_variables)
          @logger.debug "gitlab proxy result: #{gitlab_result.inspect}"
        rescue Gitlab::Error::InternalServerError => e
          @logger.error "Gitlab Proxy error: #{e}"

          tries -= 1
          if tries > 0
            @logger.info "Trying to trigger pipeline for project #{project_name} again: #{project_id}, ref #{trigger_ref}"
            retry
          else
            @logger.error "Failed to trigger pipeline for project #{project_name}: #{project_id}, ref #{trigger_ref}"
            return
          end
        end

        gitlab_pipeline_id = gitlab_result.id
        data = { project_name: target_project_name, target_project_ref: target_project_ref, trigger_ref: trigger_ref, target_project_id: target_project_id, project_id: project_id, pipeline_id: gitlab_pipeline_id, cloud: cloud, arch: arch }
        @provisionings << data
        data
      end

      def retrieve_kubeconfig(project_id, pipeline_id, api_token, cloud)
        # TODO: pull job name from cross cloud yaml
        job_id = pipeline_job_by_name(project_id, pipeline_id, "Provisioning")["id"]


        # TODO: move retrive into gitlab_proxy for single artifact download
        #
        # GET /projects/:id/jobs/:job_id/artifacts/*artifact_path
        #
        url = "#{@config[:gitlab][:base_url]}/cncf/cross-cloud/-/jobs/#{job_id}/artifacts/raw/data/#{cloud}/kubeconfig"
        #url = "#{@config[:gitlab][:base_url]}/projects/#{project_id}/-/jobs/#{job_id}/artifacts/data/#{cloud}/kubeconfig"

        @logger.debug url

        response = Faraday.get url
        if response.body.nil?
          @logger.error "Failed to download kubeconfig for cloud #{cloud}"
          return
        end

        response.body
      end

      def pipeline_job_by_name(project_id, pipeline_id, job_name)
        jobs = []
        tries=3
        begin
          jobs = @gitlab_proxy.get_pipeline_jobs(project_id, pipeline_id)

        rescue Gitlab::Error::InternalServerError => e
          @logger.error "Gitlab Proxy error: #{e}"

          tries -= 1
          if tries > 0
            @logger.info "Trying get_pipeline_jobs again"
            retry
          else
            @logger.error "Failed get_pipeline_jobs"
            return
          end
        end

        jobs.select {|j| j["name"] == job_name}.first
      end

      def provision_status(provision_id)
        project_id = project_id_by_name("cross-cloud")
        tries=3
        begin
          jobs = @gitlab_proxy.get_pipeline_jobs(project_id, provision_id)

        rescue Gitlab::Error::InternalServerError => e
          @logger.error "Gitlab Proxy error: #{e}"

          tries -= 1
          if tries > 0
            @logger.info "Trying get_pipeline_jobs again"
            retry
          else
            @logger.error "Failed get_pipeline_jobs"
            return
          end
        end

        job = jobs.select {|j| j["name"] == "Provisioning"}
        unless job.empty?
          status = job.first["status"]
        end

        status
      end

      def deprovision_cloud(provision_id)
        project_id = project_id_by_name("cross-cloud")
        destroy_job_name = "Kubernetes_destroy"
        jobs = @gitlab_proxy.get_pipeline_jobs(project_id, provision_id)
        job = jobs.select { |j| j["name"] == destroy_job_name }

        unless job.empty?
          job_id = job.first["id"]
          # job.first["status"] showing manual means the job has not ran
        end

        unless job_id 
          raise CrossCloudCi::CiServiceError.new("Job not found for provision id: #{provision_id}")
        end

        @gitlab_proxy.gitlab_client.job_play(project_id, job_id)
      end

      # provision_active_clouds()
      #
      #  - Required: config including cross-cloud config
      # - get active clouds
      #  - pull kubernetes kubeconfig
      # - pull kubernetes build id for stable and head/master from build stage
      # - loop for active couds
      # - loop for stable and head/master on each cloud
      # - use kubernetes build id for stable and head/master based on previous build stage
      # - use kubernetes ref for stable and head/master based on config
      def provision_active_clouds
        load_project_data
        load_cloud_data

        # TODO: Support loading builds from GitLab
        # TODO: Check for empty provisioning layer and project layer
        # if @builds.nil? or @builds.empty?
        if @builds[:provision_layer].nil? or 
            @builds[:provision_layer].empty?
          @logger.error "Builds needed before provisioning"
          return
        end

        # TODO: refactor to support multiple k8s environments (eg. RC, HEAD, arm)
        @logger.info "@builds: #{@builds}"
        @logger.info "@builds[:provision_layer]: #{@builds[:provision_layer]}"
        latest_k8s_builds = @builds[:provision_layer].sort! {|x,y| x[:pipeline_id] <=> y[:pipeline_id]}
        # if @builds[:provision_layer].count > 1
        #   latest_k8s_builds = @builds[:provision_layer].sort! {|x,y| x[:pipeline_id] <=> y[:pipeline_id]}.slice(-2,2)
        # else
        #   latest_k8s_builds = @builds[:provision_layer]
        # end

        # NOTE: disabling HEAD for https://github.com/crosscloudci/crosscloudci/issues/124
        # TODO: refactor to support multiple k8s environments (eg. RC, HEAD, arm)
        @logger.info "latest_k8s_builds: #{latest_k8s_builds}"
        # kubernetes_head = latest_k8s_builds.select {|b| b[:ref] == "master" }.first
        # kubernetes_stable = latest_k8s_builds.select {|b| b[:ref] != "master" }.first
        kubernetes_head = latest_k8s_builds.select {|b| b[:ref] == "master" }
        kubernetes_stable = latest_k8s_builds.select {|b| b[:ref] != "master" }

        @active_clouds.each do |cloud|
          cloud_name = cloud[0]
          @logger.info "Active cloud: #{cloud_name}"

          # TODO: refactor to support multiple k8s environments (eg. RC, HEAD, arm)
          # [:stable, :head].each do |release|
          #   if release == :stable
          #     builds = kubernetes_stable 
          #   else
          #     builds = kubernetes_head 
          #   end
          #   @logger.info "builds: #{builds}"


          latest_k8s_builds.each do |kubernetes_build|

            # kubernetes_build = ""
            # case release
            # when :stable
            #   kubernetes_build = kubernetes_stable
            # # NOTE: wait time not needed while only using stable. refactor for multiple envs
            # else
            #   # if cloud_name == "packet"
            #   #   @logger.info "Waiting 600 seconds for next Packet API call"
            #   #   sleep 600
            #   # end
            #   kubernetes_build = kubernetes_head
            # end

            @logger.info "kubernetes_build: #{kubernetes_build}"
            build_id = kubernetes_build[:pipeline_id] 
            ref = kubernetes_build[:ref]

            options = {}
            options = {
              dashboard_api_host_port: @config[:dashboard][:dashboard_api_host_port],
              cross_cloud_yml: @config[:cross_cloud_yml], 
              kubernetes_build_id: build_id,
              kubernetes_ref: ref,
              api_token: @config[:gitlab][:pipeline]["cross-cloud"][:api_token],
              provision_ref: @config[:gitlab][:pipeline]["cross-cloud"][:cross_cloud_ref],
            }

            # TODO: check for arch support on the provider?
            # arch_types = ["amd64", "arm64"]
            #
            # arch_types.each do |machine_arch|
              # options[:arch] = machine_arch
              options[:arch] = kubernetes_build[:arch]
              self.provision_cloud(cloud_name, options)
            # end
            # end

            #self.provision_cloud(cloud_name, {:kubernetes_build_id => 5413, :kubernetes_ref => "v1.8.1", :dashboard_api_host_port => "devapi.cncf.ci", :cross_cloud_yml => @config[:cross_cloud_yml], :api_token => @config[:gitlab][:pipeline]["cross-cloud"][:api_token], :provision_ref => @config[:gitlab][:pipeline]["cross-cloud"][:cross_cloud_ref]})
          end
        end

        #   trigger_variables = {:dashboard_api_host_port => @config[:dashboard][:dashboard_api_host_port], :cross_cloud_yml => @config[:cross_cloud_yml]}
        #   project_id =  all_gitlab_projects.select {|agp| agp["name"].downcase == name}.first["id"]
        #
        #   ["stable_ref", "head_ref"].each do |release_key_name|
        #     ref = @config[:projects][name][release_key_name]
        #     puts "Calling build_project(#{project_id}, #{ref}, #{trigger_variables})"
        #     #self.build_project(project_id, api_token, ref, trigger_variables)
        #     self.build_project(project_id, ref, trigger_variables)
        #   end
        # end
        #
      end



      ######################################
      ## App Deploy
      ##
      ## Required options
      ##  - project_id => gitlab id of project to deploy as an integer
      ##  - build_id => gitlab pipeline id for a project build (available in @builds)  as an integer
      ##  - provision_id => gitlab pipeline id for a kubernetes provisioning (available in @provisionings) as an integer
      ##  - cloud => the cloud to deploy to as a string
      ##  - options hash
      ##    - :chart_repo => helm chart repo
      ##   -  :dashboard_api_host_porta => dashhboard api host and port [OPTIONAL / override]
      ##   -  :cross_cloud_yml => url to cross-cloud.yml [OPTIONAL / override]
      def app_deploy(target_project_id, target_build_id, target_provision_id, target_cloud, options = {})
        #@logger.debug "#{project_name} project id: #{project_id}, api token: #{api_token}, ref:#{ref}"
        @logger.debug "options var: #{options.inspect}"

        # TODO: refactor out cloud or provision id

        ## GitLab pipeline to trigger
        # related to environment, eg. cidev, master, staging, production
        trigger_variables = {}
        trigger_project_name = "cross-project"
        trigger_project_id = project_id_by_name(trigger_project_name)
        trigger_api_token = @config[:gitlab][:pipeline][trigger_project_name][:api_token]
        trigger_ref = @config[:gitlab][:pipeline][trigger_project_name][:cross_project_ref]

        target_project_name = project_name_by_id(target_project_id)
        # org_name = config[:projects][target_project_name]["project_url"].split("/")[3]
        org_name = config[:projects][target_project_name]["repository_url"].split("/")[3]
        stable_chart = config[:projects][target_project_name]["stable_chart"]
        head_chart = config[:projects][target_project_name]["head_chart"]

        ####################################
        # TODO: move this out
        # TODO: pull cloud from provisioning
        cross_cloud_id = project_id_by_name("cross-cloud")
        cross_cloud_api_token = @config[:gitlab][:pipeline]["cross-cloud"][:api_token]

        deployment_env = @provisionings.select {|p| p[:pipeline_id] == target_provision_id}.first

        if deployment_env.nil?
          raise CrossCloudCi::CiServiceError.new("Kubernetes provisioning could not be found for Gitlab pipeline id #{pipeline_id}")
        end

        kubernetes_release_type = "stable"

        case deployment_env[:target_project_ref]
        when "master"
          kubernetes_release_type = "head"
        else
          kubernetes_release_type = "stable"
        end

        trigger_variables[:KUBERNETES_RELEASE_TYPE] = kubernetes_release_type
        trigger_variables[:PROVISION_PIPELINE_ID] = target_provision_id # cross-cloud k8s provisioning

        case trigger_ref 
        when "master"
          pipeline_release_type = "head"
        else
          pipeline_release_type = "stable"
        end

        trigger_variables[:PIPELINE_RELEASE_TYPE] = pipeline_release_type 

        # How to determine test env for the selector
        # 1. release type => stable / head
        # 2. target provision id = cross-cloud pipeline id
        #    * kubernetes ref (commit or version) can be derived


        # Retrieve Kubeconfig for the target cloud which was previously provisioned
        kubeconfig = retrieve_kubeconfig(cross_cloud_id, target_provision_id, cross_cloud_api_token, target_cloud)

        if kubeconfig.nil?
          raise CrossCloudCi::CiServiceError.new("Kubeconfig could not be downloaded")
        end

        kubeconfig_base64 = Base64.encode64(kubeconfig).gsub(/[\r\n]+/, '')
        trigger_variables[:KUBECONFIG] = kubeconfig_base64

        project_build = @builds[:app_layer].select {|b| b[:pipeline_id] == target_build_id}.first

        if project_build.nil?
          @logger.error "Target project build (pipeline id: #{target_build_id}) not found!"
          return nil 
        end

        target_project_ref = project_build[:ref]

        ## Setup Gitlab API trigger variables
        trigger_variables[:CLOUD] = target_cloud
        trigger_variables[:SOURCE] = target_build_id
        trigger_variables[:ORG] = org_name

        if options[:chart_repo]
          trigger_variables[:CHART_REPO] = options[:chart_repo] unless options[:chart_repo].nil?
        else
          if target_project_ref.downcase == "master"
            trigger_variables[:CHART_REPO] = head_chart
            @logger.info "Selecting stable_chart #{head_chart}"
          else
            @logger.info "Selecting stable_chart #{stable_chart}"
            trigger_variables[:CHART_REPO] = stable_chart
          end
        end
        # trigger_variables[:FILTER] = options[:filter] unless options[:filter].nil?
        # trigger_variables[:LABEL_ARGS] = options[:label_args] unless options[:label_args].nil?



        trigger_variables[:PROJECT_ID] = target_project_id
        trigger_variables[:CHART] = target_project_name
        trigger_variables[:PROJECT_BUILD_PIPELINE_ID] = target_build_id
        trigger_variables[:TARGET_PROJECT_ID] = target_project_id
        trigger_variables[:TARGET_PROJECT_NAME] = target_project_name
        #trigger_variables[:TARGET_PROJECT_COMMIT_REF_NAME] = options[:project_ref] unless options[:project_ref].nil?
        #trigger_variables[:TARGET_PROJECT_COMMIT_REF_NAME] = @builds[:app_layer][2].first[1][:ref]
        
        trigger_variables[:TARGET_PROJECT_COMMIT_REF_NAME] = target_project_ref

        # Deployment name must be  DNS compliant for k8s/helm
        trigger_variables[:DEPLOYMENT_NAME] = "#{target_project_name}-#{target_project_ref}".gsub(/\./,'')

        #trigger_variables[:DASHBOARD_API_HOST_PORT] = options[:dashboard_api_host_port] unless options[:dashboard_api_host_port].nil?
        if options[:dashboard_api_host_port]
          trigger_variables[:DASHBOARD_API_HOST_PORT] = options[:dashboard_api_host_port]
        else
          trigger_variables[:DASHBOARD_API_HOST_PORT] = @config[:dashboard][:dashboard_api_host_port]
        end

        if options[:cross_cloud_yml] 
          trigger_variables[:CROSS_CLOUD_YML] = options[:cross_cloud_yml]
        else
          trigger_variables[:CROSS_CLOUD_YML] = @config[:cross_cloud_yml]
        end

        arch = options[:arch] || "amd64"
        trigger_variables[:ARCH] = arch

        gitlab_result = nil
        tries=3
        begin
          @logger.debug "Calling Gitlab API for #{target_project_name} trigger_pipeline(#{trigger_project_id}, #{trigger_api_token}, #{trigger_ref}, #{trigger_variables})"
          gitlab_result = @gitlab_proxy.trigger_pipeline(trigger_project_id, trigger_api_token, trigger_ref, trigger_variables)
          @logger.debug "gitlab proxy result: #{gitlab_result.inspect}"
        rescue Gitlab::Error::InternalServerError => e
          @logger.error "Gitlab Proxy error: #{e}"

          tries -= 1
          if tries > 0
            @logger.info "Trying to trigger pipeline for project #{project_name} again: #{project_id}, ref #{trigger_ref}"
            retry
          else
            @logger.error "Failed to trigger pipeline for project #{project_name}: #{project_id}, ref #{trigger_ref}"
            return
          end
        end

        gitlab_pipeline_id = gitlab_result.id
        # TODO make this like provisioning - remove pipline_id from start
        # NOTE: trigger_ref is the cross-project branch to use!
        data = { project_name: target_project_name, target_project_ref: target_project_ref, ref: trigger_ref, project_id: target_project_id, pipeline_id: gitlab_pipeline_id, cloud: target_cloud, arch: arch} 
        @app_deploys << data
        data
      end

      def app_deploy_status(app_deploy_id)
        project_id = project_id_by_name("cross-project")
        tries=3
        begin
          jobs = @gitlab_proxy.get_pipeline_jobs(project_id, app_deploy_id)

        rescue Gitlab::Error::InternalServerError => e
          @logger.error "Gitlab Proxy error: #{e}"

          tries -= 1
          if tries > 0
            @logger.info "Trying get_pipeline_jobs again"
            retry
          else
            @logger.error "Failed get_pipeline_jobs"
            return
          end
        end
        status = jobs.select {|j| j["name"] == "e2e"}.first["status"]
        status
      end


      # TODO: #8) implement app deploy loop
      #  - Required: config including cross-cloud config
      #  - determine active projects
      #  - call app deploy function for each active project for master and stable refs
      #  - handle retry



      # app_deploy_to_active_clouds()
      #
      # - Required: config including cross-cloud config
      #
      # What does it do?
      # - get active clouds
      # - get active projects
      #
      # - loop through active projects
      # - loop for stable and head/master on each project
      # - loop for active clouds on the current ref (stable/head)
      #
      # Args:
      #   - options hash
      #     * :release_types => [:head, :stable] - List of release types to deploy -- OPTIONAL
      #
      def app_deploy_to_active_clouds(options = {})
        load_project_data
        load_cloud_data

        # TODO: Support loading builds from GitLab
        if @builds.nil? or @builds.empty?
          @logger.error "Builds needed before provisioning"
          return
        end

        if @provisionings.nil? or @provisionings.empty?
          @logger.error "Provisioning needed before app deploy"
          return
        end

        # latest_k8s_builds = @builds[:provision_layer].sort! {|x,y| x[:pipeline_id] <=> y[:pipeline_id]}.slice(-2,2)
        #
        # kubernetes_head = latest_k8s_builds.select {|b| b[:ref] == "master" }.first
        # kubernetes_stable = latest_k8s_builds.select {|b| b[:ref] != "master" }.first


        # - loop through active projects
        # - loop for stable and head/master on each project
        # - loop for active clouds on the current ref (stable/head)

        # NOTE: These are the key names in the cross-cloud.yml
        default_release_ref_keys = ["stable_ref", "head_ref"]

        release_types = options[:release_types] ||= [:stable, :head]

        release_ref_keys = []

        release_types.each do |rt|
          case rt
          when :stable
            release_ref_keys << "stable_ref"
          when :head
            release_ref_keys << "head_ref"
          else
            @logger.warn "[App Deploy Loop] Invalid release type given #{release_types}"
          end
        end

        release_ref_keys = default_release_ref_keys if release_ref_keys.empty?

        deployed_projects = []

        active_app_projects = @active_projects.select { |k,v| v["app_layer"] }
        #TODO skip projects that should not be deployed
        active_app_projects.each do |project|
          project_name = project[0]

          # issue 256
          if @config[:projects][project_name]["deploy"] == false then
            next 
          end

          project_id = project_name_by_id(project_name)

          @logger.info "[App Deploy] #{project_name}"

          trigger_variables = {}

          @logger.info "[App Deploy] release key names #{release_ref_keys}"

          #["stable_ref", "head_ref"].each do |release_key_name|
          release_ref_keys.each do |release_key_name|

            @active_clouds.each do |cloud|
              cloud_name = cloud[0]
              @logger.info "[App Deploy] Active cloud: #{cloud_name}"

              # kubernetes environment we will deploy to 
              #deployment_env = @provisionings.select {|p| p[:cloud] == cloud_name && p[:target_project_ref] == @config[:projects]["kubernetes"][release_key_name] }.first
              # NOTE: Only deploying to stable K8s for https://github.com/crosscloudci/crosscloudci/issues/124
              # TODO: Refactor to support multiple test environments

              deployment_env = []
              #TODO match arm/amd provisionings with arm@amd project build pipeline ids
              ["stable_ref", "head_ref"].each do |k8s_release_ref|
                @logger.info "[App Deploy] @provisionings: #{@provisionings}"
                deployment_env = @provisionings.select {|p| p[:cloud] == cloud_name && 
                                                        p[:target_project_ref] == @config[:projects]["kubernetes"][k8s_release_ref] }
                deployment_env.each do |env|
                  @logger.info "[App Deploy] Deploying env: #{env}"
                  @logger.info "[App Deploy] Deploying to #{cloud_name} running Kubernetes #{env[:target_project_ref]} provisioned in pipeline #{env[:pipeline_id]} arch: #{env[:arch]}"

                  # Dont deploy apps that dont have matching archs
                  if config[:projects][project_name]["arch"] && config[:projects][project_name]["arch"].find {|x| x == env[:arch]} 
                    project_ref = @config[:projects][project_name][release_key_name]
                    # only select projects for the currently selected deployment env arch
                    @logger.info "[App Deploy] @builds: #{@builds}"
                    project_build = @builds[:app_layer].find {|p| p[:project_name] == project_name && 
                                                              p[:ref] == project_ref &&
                                                              p[:arch] == env[:arch]}
                    if project_build
                      project_build_id = project_build[:pipeline_id]
                      project_arch = project_build[:arch]
                    end

                    puts "[App Deploy] #{project_name} (#{project_id}) #{project_ref} #{project_arch} #{trigger_variables}"
                    @logger.info "[App Deploy] self.app_deploy(#{project_id}, #{project_build_id}, #{env[:pipeline_id]}, #{cloud_name}, #{options})"

                    options[:arch] = env[:arch] 

                    deployed_projects << project_name
                    self.app_deploy(project_id, project_build_id, env[:pipeline_id], cloud_name, options)
                  end
                end
                if deployment_env.empty?
                  @logger.error "malformed @provisionings: #{@provisionings}"
                  @logger.error "@config[:projects]['kubernetes'][k8s_release_ref]: #{@config[:projects]['kubernetes'][k8s_release_ref]}"

                end
              end
            end
          end

        end

        deployed_projects.uniq
      end

      ##############################################################
      ## Trigger, scheduled job and Dashboard specific methods below
      ##############################################################

      def load_cloud_data
        if @active_clouds.nil?
          @active_clouds = @config[:clouds].find_all {|c| c[1]["active"]}
        end
      end

      def load_project_data

        if @active_projects.nil?
          @logger.info "[CiService] Loading active projects"
          # Create hash of active projects from cross-cloud.yml data
          @active_projects = @config[:projects].select {|p| p if @config[:projects][p]["active"] == true }
        end

        if @all_gitlab_projects.nil?
          @logger.info "[CiService] Loading GitLab project data"
          @all_gitlab_projects = @gitlab_proxy.get_projects
        end

        if @active_gitlab_projects.nil?
          @logger.info "[CiService] Creating data mappings"
          @active_gitlab_projects = @all_gitlab_projects.collect do |agp|
            agp_name = agp["name"].downcase
            proj_id = agp["id"]
            if agp_name == "cross-cloud" || agp_name == "cross-project"
              #@logger.debug "[CiService] Load GitLab Project - Creating mapping for #{agp_name}"
              @project_name_id_mapping[proj_id] = agp_name
              @project_name_id_mapping[agp_name] = proj_id
              nil
            elsif @active_projects[agp_name]
              #@logger.debug "[CiService] Load Project - Adding gitlab data to active projects for #{agp_name} (#{proj_id})"
              @active_projects[agp_name]["gitlab_data"] = agp

              # Support looking up project by id
              @project_name_id_mapping[proj_id] = agp_name
              @project_name_id_mapping[agp_name] = proj_id
              agp
            end
          end.compact!
        end
      end

      def project_id_by_name(name)
        @project_name_id_mapping[name]
      end

      def project_name_by_id(project_id)
        @project_name_id_mapping[project_id]
      end

      def list_project_name_id_mapping
        @project_name_id_mapping
      end

      # TODO: retrieve latest successful build
      # args: project id, ref

      private
        attr_accessor :project_name_id_mapping
    end
  end
end

