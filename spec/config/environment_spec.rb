require './config/environment'
RSpec.describe CrossCloudCi::Common do
 context "init_config" do
   it "should initialize the yaml" do
      config = CrossCloudCi::Common.init_config #    expect(config[:projects]["kubernetes"]["head_ref"]).to eq "master"
   end

   it "should read the logo from the crosscloud.yml if present in both crosscloud.yml and cncfci.yml" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["linkerd"]["logo_url"]).to eq "https://raw.githubusercontent.com/cncf/artwork/53f1179f7950f27e330fce4e983304de59811b52/linkerd/icon/color/linkerd-icon-color.png"
      expect(config[:projects]["prometheus"]["logo_url"]).to eq "https://raw.githubusercontent.com/cncf/artwork/1d4e7cf3b60af40e008b2e2413f7a2d1ff784b52/prometheus/icon/color/prometheus-icon-color.png"
   end

   it "should have an arch array with arm" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["kubernetes"]["arch"]).to eq ["amd64", "arm64"] 
   end

   it "should overwrite cross_cloud.yml with cncnfci.yml" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["coredns"]["arch"]).to eq ["amd64", "arm64"] 
   end

   it "should overwrite configuration_repo cross_cloud.yml with cncnfci.yml" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["coredns"]["configuration_repo"]).to eq "https://raw.githubusercontent.com/crosscloudci/coredns-configuration" 
   end

   it "should overwrite configuration_repo_path cross_cloud.yml with cncnfci.yml" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["coredns"]["configuration_repo_path"]).to eq "https://raw.githubusercontent.com/crosscloudci/coredns-configuration/master/cncfci.yml" 
   end
   ## crosscloudci/crosscloudci#103
   it "should overwrite cross_cloud.yml with release details in project configuration" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["fluentd"]["stable_ref"]).to_not be_nil 
      expect(config[:projects]["fluentd"]["head_ref"]).to eq "master"
   end
   it "should overwrite cross_cloud.yml with ci system details in project configuration" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["testproj"]["ci_system"][0]["ci_system_type"]).to eq "travis-ci"
      expect(config[:projects]["testproj"]["ci_system"][0]["ci_project_url"]).to eq "https://example.com/cncfci/testproj"
      expect(config[:projects]["testproj"]["ci_system"][0]["arch"][0]).to eq "amd64"
      expect(config[:projects]["testproj"]["deploy"]).to eq false
   end

   it "should be able to see linkerd2" do
      config = CrossCloudCi::Common.init_config
      expect(config[:projects]["linkerd2"]["arch"]).to eq ["amd64"] 
   end
  end
end 
