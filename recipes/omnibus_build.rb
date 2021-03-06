#
# Cookbook Name:: api-umbrella
# Recipe:: omnibus_build
#
# Copyright 2014, NREL
#
# All rights reserved - Do Not Redistribute
#

::Chef::Recipe.send(:include, ::ApiUmbrella::OmnibusHelpers)

include_recipe "git"
include_recipe "omnibus"

node.set[:authorization][:sudo][:include_sudoers_d] = true
node.set[:authorization][:sudo][:sudoers_defaults] = [
  "env_reset",
  "!secure_path",
  "!requiretty",
]
include_recipe "sudo"

include_recipe "api-umbrella::development_ulimit"

# Check out the omnibus repo if it doesn't exist. This is for building on EC2
# where this isn't a synced folder like on Vagrant.
execute "git clone https://github.com/NREL/omnibus-api-umbrella.git #{node[:omnibus][:build_dir]}" do
  user node[:omnibus][:build_user]
  group node[:omnibus][:build_user_group]
  not_if { ::Dir.exists?(node[:omnibus][:build_dir]) }
end

# Output to a temp log file, in addition to the screen. Since the build takes
# a long time, this allows us to login to the machine to view progress, while
# also ensuring the output is captured by Chef in case things error.
build_log_file = "#{node[:omnibus][:build_dir]}/.kitchen/logs/#{node[:hostname]}-api-umbrella-build.log"
build_log_dir = File.dirname(build_log_file)
node.run_state[:api_umbrella_log_redirect] = "2>&1 | tee -a #{build_log_file}; test ${PIPESTATUS[0]} -eq 0"

# Make sure the log directory exists.
directory build_log_dir do
  user node[:omnibus][:build_user]
  group node[:omnibus][:build_user_group]
  recursive true
  not_if { ::Dir.exists?(build_log_dir) }
end

# Workaround for the fact that chef's bash resource doesn't have an easy way to
# run a command as a non-root user, taking into account that user's login stuff
# (without this, the omnibus bash environment variables don't get setup
# properly, so omnibus's ruby version doesn't get picked up).
# See: https://tickets.opscode.com/browse/CHEF-2288
def command_as_build_user(command)
  env = [
    # Do everything in bundler without "host_machine" gems (these are only
    # needed on the host machine and can save time during install).
    "BUNDLE_WITHOUT=host_machine",

    # Reset the home directory, since that doesn't change properly under
    # Ubuntu.
    "HOME=/home/#{node[:omnibus][:build_user]}",
  ]

  if node[:omnibus][:env]
    node[:omnibus][:env].each do |key, value|
      unless(value.to_s.empty?)
        env << "#{key.to_s.upcase}=#{value}"
      end
    end
  end

  "sudo -u #{node[:omnibus][:build_user]} bash -l -c 'cd #{node[:omnibus][:build_dir]} && env #{env.join(" ")} #{command} #{node.run_state[:api_umbrella_log_redirect]}'"
end

# Places the built packages in a directory based on the platform and version.
# This prevents builds from different OS versions from colliding and
# overwriting each other.
package_dir = File.join(node[:omnibus][:build_dir], "pkg/#{omnibus_package_dir}")

# Cache the downloads in a local directory on the host machine, so that the
# cache persists across the kitchen instances getting destroyed and re-created.
# This helps speed things up a bit. Note, that we're not sharing the cache
# across instances, though, so we can allow parallel builds without worrying
# about two instances trying to download the same file simultaneously.
cache_dir = File.join(node[:omnibus][:build_dir], "download-cache/#{node[:platform]}-#{node[:platform_version]}")

build_script = <<-EOH
  set -e
  rm -rf #{package_dir}
  #{command_as_build_user("env")}
  #{command_as_build_user("bundle install")}
  #{command_as_build_user("bundle exec omnibus build api-umbrella -l info --override package_dir:#{package_dir} cache_dir:#{cache_dir}")}

  # There's a hard-coded "package_me" step in omnibus that copies the built
  # packages to the root pkg/ directory. We don't need theese, since we want
  # them in the OS-specific directories.
  #{command_as_build_user("rm -f pkg/*.deb pkg/*.rpm pkg/*.json")}

  # Publish the build file.
  if [ -n "#{node[:omnibus][:env][:aws_s3_bucket]}" ]; then
    #{command_as_build_user("bundle exec omnibus publish s3 #{node[:omnibus][:env][:aws_s3_bucket]} #{package_dir}/#{omnibus_package}")}
  fi

  # Add a file marker so we know this specific instance has successfully built
  # the packages.
  #{command_as_build_user("touch /var/cache/omnibus/.instance-build-complete")}
EOH

progress_output_thread = nil
bash "build api-umbrella" do
  cwd node[:omnibus][:build_dir]
  code build_script
  timeout 7200
  only_if do
    builds = Dir.glob("#{package_dir}/*")
    if(builds.any? && File.exists?("/var/cache/omnibus/.instance-build-complete"))
      false
    else
      Chef::Log.info("\n\n\nBuilding api-umbrella, this could take a while...\n(tail #{build_log_file} to view progress)\n")

      # Since this is a long running task, continue to show some output on a 30
      # second interval. This is an attempt to prevent SSH connections from
      # dropping due to inactivity when provisioning on remote EC2 instance.
      progress_output_thread = Thread.new do
        while true
          Chef::Log.info(".")
          sleep 30
        end
      end

      true
    end
  end
end

ruby_block "stop_build_progress_output" do
  block do
    if(progress_output_thread)
      progress_output_thread.kill
    end
  end
end
