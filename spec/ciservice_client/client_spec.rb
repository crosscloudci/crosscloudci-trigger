require './lib/crosscloudci/ciservice_client/client'
RSpec.describe CrossCloudCI::CiService do
 context "build_active_projects" do
   it "should have a valid arch array" do
     config = CrossCloudCi::Common.init_config
     client = CrossCloudCI::CiService::Client.new(config)
     gitlab_proxy = double()
     client.gitlab_proxy = gitlab_proxy
     allow(client).to receive(:sync_k8s_build)
     allow(client).to receive(:build_delay)
     allow(gitlab_proxy).to receive(:trigger_pipeline) do 
       a = Object.new 
       class << a  
         attr_accessor :id  
       end  
       a.id = 1
       a
     end
     expect(gitlab_proxy).to receive(:trigger_pipeline)
     data = client.build_active_projects
     expect(data["kubernetes"]["arch"]).to eq ["amd64", "arm64"]
   end
 end
 context "build_project" do
   it "should have a valid arm response" do
     config = CrossCloudCi::Common.init_config
     client = CrossCloudCI::CiService::Client.new(config)
     gitlab_proxy = double()
     client.gitlab_proxy = gitlab_proxy
     allow(client).to receive(:sync_k8s_build)
     allow(client).to receive(:build_delay)
     allow(gitlab_proxy).to receive(:trigger_pipeline) do 
       a = Object.new 
       class << a  
         attr_accessor :id  
       end  
       pipeline_id = 1
       a.id = pipeline_id 
       a
     end
     expect(gitlab_proxy).to receive(:trigger_pipeline)
     name = "prometheus" 
     k8s = client.all_gitlab_projects.find{|x| x["name"].downcase == name}
     project_id = k8s["id"]
     ref = config[:projects][name]["head_ref"]
     options = {:dashboard_api_host_port => config[:dashboard][:dashboard_api_host_port], :cross_cloud_yml => config[:cross_cloud_yml]}
     options[:arch] = "arm64" 
     # build_project(9, master, {:dashboard_api_host_port=>"https://devapi.cncf.ci", :cross_cloud_yml=>"https://raw.githubusercontent.com/crosscloudci/cncf-configuration/master/cross-cloud.yml", :arch=>"arm64"})
     data = client.build_project(project_id, ref, options)
     # {:project_name=>"kubernetes", :ref=>"master", :project_id=>14, :pipeline_id=>1, :arch=>"arm64"}    
     expect(data[:arch]).to eq "arm64"
     pipeline_id = 1
     expect(data[:pipeline_id]).to eq pipeline_id 
     build = client.builds[:app_layer].find{|x| x[:project_name] == name}
     expect(build[:arch]).to eq "arm64" 
   end
 end
 context "provision_active_clouds" do
   it "should accept arm builds" do
     #######
     # builds
     # ####
     config = CrossCloudCi::Common.init_config
     client = CrossCloudCI::CiService::Client.new(config)
     gitlab_proxy = double()
     client.gitlab_proxy = gitlab_proxy
     allow(client).to receive(:sync_k8s_build)
     allow(client).to receive(:build_delay)
     allow(gitlab_proxy).to receive(:trigger_pipeline) do 
       a = Object.new 
       class << a  
         attr_accessor :id  
       end  
       a.id = 1
       a
     end
     expect(gitlab_proxy).to receive(:trigger_pipeline)
     data = client.build_active_projects
     expect(data["kubernetes"]["arch"]).to eq ["amd64", "arm64"]
     #######

     provision_data = client.provision_active_clouds
     expect(provision_data[0][1]["active"]).to eq true 
   end
 end
 context "provision_cloud" do
   it "should accept arm provisions" do
     #######
     # builds
     # ####
     config = CrossCloudCi::Common.init_config
     client = CrossCloudCI::CiService::Client.new(config)
     gitlab_proxy = double()
     client.gitlab_proxy = gitlab_proxy
     allow(client).to receive(:sync_k8s_build)
     allow(client).to receive(:build_delay)
     allow(gitlab_proxy).to receive(:trigger_pipeline) do 
       a = Object.new 
       class << a  
         attr_accessor :id  
       end  
       a.id = 1
       a
     end
     expect(gitlab_proxy).to receive(:trigger_pipeline)
     data = client.build_active_projects
     expect(data["kubernetes"]["arch"]).to eq ["amd64", "arm64"]
     #######

     cloud_name = 'packet' 
     latest_k8s_builds = client.builds[:provision_layer].sort! {|x,y| x[:pipeline_id] <=> y[:pipeline_id]}
     kubernetes_stable = latest_k8s_builds.find {|b| b[:ref] != "master" && b[:arch] == "arm64" }
     build_id = kubernetes_stable[:pipeline_id] 
     ref = kubernetes_stable[:ref]
     options = {}
     options = {
       dashboard_api_host_port: client.config[:dashboard][:dashboard_api_host_port],
       cross_cloud_yml: client.config[:cross_cloud_yml], 
       kubernetes_build_id: build_id,
       kubernetes_ref: ref,
       api_token: client.config[:gitlab][:pipeline]["cross-cloud"][:api_token],
       provision_ref: client.config[:gitlab][:pipeline]["cross-cloud"][:cross_cloud_ref],
     }
     options[:arch] = kubernetes_stable[:arch]
     data = client.provision_cloud(cloud_name, options)
     expect(data[:arch]).to eq "arm64" 
   end
 end
 context "app_deploy_to_active_clouds" do
   it "should accept arm provisions" do
     #######
     # builds
     # ####
     config = CrossCloudCi::Common.init_config
     client = CrossCloudCI::CiService::Client.new(config)
     gitlab_proxy = double()
     client.gitlab_proxy = gitlab_proxy
     allow(client).to receive(:sync_k8s_build)
     allow(client).to receive(:build_delay)
     allow(gitlab_proxy).to receive(:trigger_pipeline) do 
       a = Object.new 
       class << a  
         attr_accessor :id  
       end  
       a.id = 1
       a
     end
     expect(gitlab_proxy).to receive(:trigger_pipeline)
     data = client.build_active_projects
     expect(data["kubernetes"]["arch"]).to eq ["amd64", "arm64"]
     ######
     # provisions
     ###### 
     provision_data = client.provision_active_clouds
     expect(provision_data[0][1]["active"]).to eq true 
     allow(gitlab_proxy).to receive(:get_pipeline_jobs).with(any_args) do 
       a = {"id" =>  1,
            "name" => "Provisioning"}
       [a]
     end
     ######
     # deploys
     ###### 
     deploy_data = client.app_deploy_to_active_clouds

     expect(deploy_data.find{|x| x == "testproj"}).to eq nil 
     expect(deploy_data.count).to be > 0 
   end
   # All projects current have arm enabled
   # it "should only accept arm provisions if arch includes arm" do
   #   #######
   #   # builds
   #   # ####
   #   config = CrossCloudCi::Common.init_config
   #   client = CrossCloudCI::CiService::Client.new(config)
   #   gitlab_proxy = double()
   #   client.gitlab_proxy = gitlab_proxy
     # allow(client).to receive(:sync_k8s_build)
     # allow(client).to receive(:build_delay)
   #   allow(gitlab_proxy).to receive(:trigger_pipeline) do 
   #     a = Object.new 
   #     class << a  
   #       attr_accessor :id  
   #     end  
   #     a.id = 1
   #     a
   #   end
   #   expect(gitlab_proxy).to receive(:trigger_pipeline)
   #   data = client.build_active_projects
   #   expect(data["kubernetes"]["arch"]).to eq ["amd64", "arm64"]
   #   ######
   #   # provisions
   #   ###### 
   #   provision_data = client.provision_active_clouds
   #   expect(provision_data[0][1]["active"]).to eq true 
   #   allow(gitlab_proxy).to receive(:get_pipeline_jobs).with(any_args) do 
   #     a = {"id" =>  1,
   #          "name" => "Provisioning"}
   #     [a]
   #   end
   #   ######
   #   # deploys
   #   ###### 
   #   deploy_data = client.app_deploy_to_active_clouds
   #   app_deploys = client.app_deploys.find {|p| p[:project_name] == "envoy" && p[:arch] == "arm64"}
   #   expect(app_deploys).to eq nil 
   # end
 end
 context "app_deploy" do
   it "should accept arm provisions" do
     #######
     # builds
     # ####
     config = CrossCloudCi::Common.init_config
     client = CrossCloudCI::CiService::Client.new(config)
     gitlab_proxy = double()
     client.gitlab_proxy = gitlab_proxy
     allow(client).to receive(:sync_k8s_build)
     allow(client).to receive(:build_delay)
     allow(gitlab_proxy).to receive(:trigger_pipeline) do 
       a = Object.new 
       class << a  
         attr_accessor :id  
       end  
       a.id = 1
       a
     end
     expect(gitlab_proxy).to receive(:trigger_pipeline)
     data = client.build_active_projects
     expect(data["kubernetes"]["arch"]).to eq ["amd64", "arm64"]
     ######
     # provisions
     ###### 
     provision_data = client.provision_active_clouds
     expect(provision_data[0][1]["active"]).to eq true 
     allow(gitlab_proxy).to receive(:get_pipeline_jobs).with(any_args) do 
       a = {"id" =>  1,
            "name" => "Provisioning"}
       [a]
     end

     # app
     name = "prometheus" 
     ref_type = "stable_ref"
     arch_type = "arm64"
     ref = config[:projects][name][ref_type]
     project_build = client.builds[:app_layer].find {|p| p[:project_name] == name && p[:ref] == ref && p[:arch] == arch_type}
     project_build_id = project_build[:pipeline_id]

     app = client.all_gitlab_projects.find{|x| x["name"].downcase == name}
     project_id = app["id"]

     ### deploy ###
     cloud_name = 'packet' 
     deployment_env = client.provisionings.find {|p| p[:cloud] == cloud_name && p[:target_project_ref] == client.config[:projects]["kubernetes"][ref_type] && p[:arch] == arch_type}

     options = {}
     options[:release_types]=[:stable, :head]
     options[:arch] = deployment_env[:arch] 
     deploy_data = client.app_deploy(project_id, project_build_id, deployment_env[:pipeline_id], cloud_name, options)
     expect(deploy_data[:arch]).to eq arch_type 
   end
 end
end 
