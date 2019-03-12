require 'yaml/store'

module CrossCloudCi
  module Common
    def self.init_config(options = {})
      case ENV["CROSS_CLOUD_CI_ENV"]
      when "cidev"
        gitlab_base_url="https://gitlab.cidev.cncf.ci"
        cross_cloud_yml="https://raw.githubusercontent.com/crosscloudci/cncf-configuration/integration/cross-cloud.yml"
        cross_cloud_ref="master"
        cross_project_ref="master"
        dashboard_api_host_port="cidevapi.cncf.ci"
      when "staging"
        gitlab_base_url="https://gitlab.staging.cncf.ci"
        cross_cloud_yml="https://raw.githubusercontent.com/crosscloudci/cncf-configuration/staging/cross-cloud.yml"
        cross_cloud_ref="staging"
        cross_project_ref="staging"
        dashboard_api_host_port="stagingapi.cncf.ci"
      when "production"
        gitlab_base_url="https://gitlab.cncf.ci"
        cross_cloud_yml="https://raw.githubusercontent.com/crosscloudci/cncf-configuration/production/cross-cloud.yml"
        cross_cloud_ref="production"
        cross_project_ref="production"
        dashboard_api_host_port="productionapi.cncf.ci"
      when "demo"
        gitlab_base_url="https://gitlab.demo.cncf.ci"
        cross_cloud_yml="https://raw.githubusercontent.com/crosscloudci/cncf-configuration/production/cross-cloud.yml"
        cross_cloud_ref="production"
        cross_project_ref="production"
        dashboard_api_host_port="demoapi.cncf.ci"
      when "onapdemo"
        gitlab_base_url="https://gitlab.onap.cncf.ci"
        cross_cloud_yml="https://raw.githubusercontent.com/crosscloudci/cncf-configuration/production/cross-cloud.yml"
        cross_cloud_ref="production"
        cross_project_ref="production"
        dashboard_api_host_port="onapapi.cncf.ci"
      # Default
      else
        gitlab_base_url="https://gitlab.dev.cncf.ci"
        # gitlab_base_url="https://dev.vulk.co:4002/api"
        # cross_cloud_yml="https://raw.githubusercontent.com/crosscloudci/cncf-configuration/project-details-36/cross-cloud.yml"
        cross_cloud_yml="https://raw.githubusercontent.com/crosscloudci/cncf-configuration/master/cross-cloud.yml"
        cross_cloud_ref="master"
        cross_project_ref="master"
        dashboard_api_host_port="devapi.cncf.ci"
      end

      # Environment overrides
      dashboard_api_host_port = ENV["DASHBOARD_API_HOST_PORT"] unless ENV["DASHBOARD_API_HOST_PORT"].nil?
      gitlab_base_url = ENV["GITLAB_BASE_URL"] unless ENV["GITLAB_BASE_URL"].nil?
      cross_cloud_yml = ENV["CROSS_CLOUD_YML"] unless ENV["CROSS_CLOUD_YML"].nil?
      cross_cloud_ref = ENV["CROSS_CLOUD_REF"] unless ENV["CROSS_CLOUD_REF"].nil?
      cross_project_ref = ENV["CROSS_PROJECT_REF"] unless ENV["CROSS_PROJECT_REF"].nil?

      @config = {
        :cross_cloud_yml => cross_cloud_yml,
        :dashboard => {
          :dashboard_api_host_port => dashboard_api_host_port
        },
        :gitlab => {
          :base_url => gitlab_base_url,
          :api_url => "#{gitlab_base_url}/api/v4",
          :api_token => ENV["GITLAB_API_TOKEN"],
          :pipeline => {
            "cross-cloud" => {
              :cross_cloud_ref => cross_cloud_ref,
              :api_token => ENV["GITLAB_CROSS_CLOUD_TOKEN"]
            },
            "cross-project" => {
              :cross_project_ref => cross_project_ref,
              :api_token => ENV["GITLAB_CROSS_PROJECT_TOKEN"]
            },
            "kubernetes" => {
              :api_token => ENV["GITLAB_KUBERNETES_TOKEN"]
            },
            "prometheus" => {
              :api_token => ENV["GITLAB_PROMETHEUS_TOKEN"]
            },
            "coredns" => {
              :api_token => ENV["GITLAB_COREDNS_TOKEN"]
            },
            "linkerd" => {
              :api_token => ENV["GITLAB_LINKERD_TOKEN"]
            },
            "fluentd" => {
              :api_token => ENV["GITLAB_FLUENTD_TOKEN"]
            },
            "so" => {
              :api_token => ENV["GITLAB_SO_TOKEN"]
            },
            "envoy" => {
              :api_token => ENV["GITLAB_ENVOY_TOKEN"]
            }
          }
        }
      }

      response = Faraday.get @config[:cross_cloud_yml]


      # TODO: Decide if we want to return nil/raise an error and let a higher level handle the error
      if response.nil?
        @logger.fatal "Failed to retrieve cross-cloud configuration!"
        exit 1
      else
        cross_cloud_config = YAML.parse(response.body).to_ruby
      end

      if cross_cloud_config.nil?
        @logger.fatal "cross-cloud.yml configuration empty/undefined"
        exit 1
        #return nil
      end

      @config[:projects] = cross_cloud_config["projects"]

      # Helm configuration
      @config[:projects]["linkerd"][:helm] = {
        :label_master => "app=linkerd-master-linkerd",
        :label_stable => "app=linkerd-stable-linkerd",
        :filter_master => ".items[0].spec.containers[0].image",
        :filter_stable => ".items[0].spec.containers[0].image"
      }

      @config[:projects]["coredns"][:helm] = {
        :label_master => "app=coredns-master-coredns",
        :label_stable => "app=coredns-stable-coredns",
        :filter_master => ".items[0].spec.containers[0].image",
        :filter_stable => ".items[0].spec.containers[0].image"
      }

      @config[:projects]["prometheus"][:helm] = {
        :label_master => "app=prometheus-master-prometheus",
        :label_stable => "app=prometheus-stable-prometheus",
        :filter_master => ".items[0].spec.containers[0].image",
        :filter_stable => ".items[0].spec.containers[0].image"
      }

      @config[:clouds] = cross_cloud_config["clouds"]

      @config[:gitlab][:pipeline].each do |p|
        cp = cross_cloud_config["gitlab_pipeline"][p[0]] 
        next if cp.nil?
        cp.each_pair do |k,v|
          @config[:gitlab][:pipeline][p[0]][k] = v
        end
      end
      @config
    end

    def self.load_saved_data(client, store_file)
      store = YAML::Store.new(store_file)

      if client.builds.nil?
        client.builds = store.transaction { store.fetch(:builds, { :provision_layer => [], :app_layer => [] }) }
      end

      if client.provisionings.nil?
        client.provisionings = store.transaction { store.fetch(:provisionings, []) }
      end

      if client.app_deploys.nil?
        client.app_deploys = store.transaction { store.fetch(:app_deploys, []) }
      end

      true
    end
  end
end
