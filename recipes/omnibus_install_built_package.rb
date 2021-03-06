::Chef::Recipe.send(:include, ::ApiUmbrella::OmnibusHelpers)

package_path = "#{Chef::Config[:file_cache_path]}/api-umbrella-omnibus-test.#{omnibus_package_extension}"
package_dir = omnibus_package_dir
package = omnibus_package

if(node[:omnibus][:env][:aws_s3_bucket])
  include_recipe "aws"

  aws_s3_file(package_path) do
    bucket node[:omnibus][:env][:aws_s3_bucket]
    aws_access_key_id node[:omnibus][:env][:aws_access_key]
    aws_secret_access_key node[:omnibus][:env][:aws_secret_key]
    arch = "x86_64"
    remote_path "#{package_dir}/#{arch}/#{package}/#{package}"
  end
else
  link(package_path) do
    to File.join(node[:omnibus][:build_dir], "pkg", package_dir, package)
  end
end

if(node[:platform_family] == "debian")
  # dpkg doesn't install dependencies. We should look into a real apt repo.
  package "gcc"
end

package "api-umbrella" do
  source package_path
  case node[:platform_family]
  when "debian"
    provider Chef::Provider::Package::Dpkg
  end
end
