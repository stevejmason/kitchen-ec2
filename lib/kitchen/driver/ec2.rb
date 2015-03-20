# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2012, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'benchmark'
require 'json'
require 'fog'
require 'kitchen'

module Kitchen

  module Driver

    # Amazon EC2 driver for Test Kitchen.
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class Ec2 < Kitchen::Driver::SSHBase

      default_config :use_iam_profile,    false
      default_config :region,             'us-east-1'
      default_config :availability_zone,  'us-east-1b'
      default_config :flavor_id,          'm1.small'
      default_config :ebs_optimized,      false
      default_config :security_group_ids, ['default']
      default_config :tags,               { 'created-by' => 'test-kitchen' }
      default_config :user_data,          nil
      default_config :iam_profile_name,   nil
      default_config :price,   nil
      default_config :aws_access_key_id do |driver|
        ENV['AWS_ACCESS_KEY'] || ENV['AWS_ACCESS_KEY_ID']
      end
      default_config :aws_secret_access_key do |driver|
        ENV['AWS_SECRET_KEY'] || ENV['AWS_SECRET_ACCESS_KEY']
      end
      default_config :aws_session_token do |driver|
        ENV['AWS_SESSION_TOKEN'] || ENV['AWS_TOKEN']
      end
      default_config :aws_ssh_key_id do |driver|
        ENV['AWS_SSH_KEY_ID']
      end
      default_config :image_id do |driver|
        driver.default_ami
      end
      default_config :username do |driver|
        driver.default_username
      end
      default_config :endpoint do |driver|
        "https://ec2.#{driver[:region]}.amazonaws.com/"
      end

      default_config :interface, nil
      default_config :associate_public_ip do |driver|
        driver.default_public_ip_association
      end
      default_config :ssh_timeout, 1
      default_config :ssh_retries, 3

      required_config :aws_access_key_id
      required_config :aws_secret_access_key
      required_config :aws_ssh_key_id
      required_config :image_id

      # TODO: remove these in the next major version of TK
      deprecated_configs = [:ebs_volume_size, :ebs_delete_on_termination, :ebs_device_name]
      deprecated_configs.each do |d|
        validations[d] = lambda do |attr, val, driver|
          unless val.nil?
            driver.warn "WARN: The config key `#{attr}` is deprecated," +
              " please use `block_device_mappings`"
          end
        end
      end

      default_config :block_device_mappings, []
      validations[:block_device_mappings] = lambda do |attr, val, driver|
        val.each do |bdm|
          unless bdm.keys.include?(:ebs_volume_size) &&
            bdm.keys.include?(:ebs_delete_on_termination) &&
            bdm.keys.include?(:ebs_device_name)
            raise "Every :block_device_mapping must include the keys :ebs_volume_size, " +
              ":ebs_delete_on_termination and :ebs_device_name"
          end
        end
      end

      def create(state)
        return if state[:server_id]

        info("Creating <#{state[:server_id]}>...")
        info("If you are not using an account that qualifies under the AWS")
        info("free-tier, you may be charged to run these suites. The charge")
        info("should be minimal, but neither Test Kitchen nor its maintainers")
        info("are responsible for your incurred costs.")

        if config[:price]
          # Spot instance when a price is set
          server = submit_spot
        else
           # On-demand instance
          server = create_server
        end

        state[:server_id] = server.id
        info("EC2 instance <#{state[:server_id]}> created.")
        server.wait_for do
          print '.'
          # Euca instances often report ready before they have an IP
          hostname = Kitchen::Driver::Ec2.hostname(self)
          ready? && !hostname.nil? && hostname != '0.0.0.0'
        end
        print '(server ready)'
        state[:hostname] = hostname(server)
        wait_for_sshd(state[:hostname], config[:username], {
          :ssh_timeout => config[:ssh_timeout],
          :ssh_retries => config[:ssh_retries]
        })
        print "(ssh ready)\n"
        debug("ec2:create '#{state[:hostname]}'")
      rescue Fog::Errors::Error, Excon::Errors::Error => ex
        raise ActionFailed, ex.message
      end

      def destroy(state)
        return if state[:server_id].nil?

        server = connection.servers.get(state[:server_id])
        server.destroy unless server.nil?
        info("EC2 instance <#{state[:server_id]}> destroyed.")
        state.delete(:server_id)
        state.delete(:hostname)
      end

      def default_ami
        region = amis['regions'][config[:region]]
        region && region[instance.platform.name]
      end

      def default_username
        amis['usernames'][instance.platform.name] || 'root'
      end

      def default_public_ip_association
        !!config[:subnet_id]
      end

      private

      def connection
        Fog::Compute.new(
          :provider               => :aws,
          :use_iam_profile        => config[:use_iam_profile]       if     config[:use_iam_profile]
          :aws_access_key_id      => config[:aws_access_key_id]     unless config[:use_iam_profile],
          :aws_secret_access_key  => config[:aws_secret_access_key] unless config[:use_iam_profile],
          :aws_session_token      => config[:aws_session_token],
          :region                 => config[:region],
          :endpoint               => config[:endpoint],
        )
      end

      def create_server
        debug_server_config

        connection.servers.create(
          :availability_zone         => config[:availability_zone],
          :security_group_ids        => config[:security_group_ids],
          :tags                      => config[:tags],
          :flavor_id                 => config[:flavor_id],
          :ebs_optimized             => config[:ebs_optimized],
          :image_id                  => config[:image_id],
          :key_name                  => config[:aws_ssh_key_id],
          :subnet_id                 => config[:subnet_id],
          :iam_instance_profile_name => config[:iam_profile_name],
          :associate_public_ip       => config[:associate_public_ip],
          :user_data                 => (config[:user_data].nil? ? nil :
            (File.file?(config[:user_data]) ?
              File.read(config[:user_data]) : config[:user_data]
            )
          ),
          :block_device_mapping      => block_device_mappings
        )
      end

      def request_spot
        debug_server_config

        connection.spot_requests.create(
          :availability_zone         => config[:availability_zone],
          :groups                    => config[:security_group_ids],
          :tags                      => config[:tags],
          :flavor_id                 => config[:flavor_id],
          :ebs_optimized             => config[:ebs_optimized],
          :image_id                  => config[:image_id],
          :key_name                  => config[:aws_ssh_key_id],
          :subnet_id                 => config[:subnet_id],
          :iam_instance_profile_name => config[:iam_profile_name],
          :user_data                 => (config[:user_data].nil? ? nil :
            (File.file?(config[:user_data]) ?
              File.read(config[:user_data]) : config[:user_data]
            )
          ),
          :price                     => config[:price],
          :instance_count            => config[:instance_count]
        )
      end

      def debug_server_config
        debug("ec2:region '#{config[:region]}'")
        debug("ec2:availability_zone '#{config[:availability_zone]}'")
        debug("ec2:flavor_id '#{config[:flavor_id]}'")
        debug("ec2:ebs_optimized '#{config[:ebs_optimized]}'")
        debug("ec2:image_id '#{config[:image_id]}'")
        debug("ec2:security_group_ids '#{config[:security_group_ids]}'")
        debug("ec2:tags '#{config[:tags]}'")
        debug("ec2:key_name '#{config[:aws_ssh_key_id]}'")
        debug("ec2:subnet_id '#{config[:subnet_id]}'")
        debug("ec2:iam_profile_name '#{config[:iam_profile_name]}'")
        debug("ec2:associate_public_ip '#{config[:associate_public_ip]}'")
        debug("ec2:user_data '#{config[:user_data]}'")
        debug("ec2:ssh_timeout '#{config[:ssh_timeout]}'")
        debug("ec2:ssh_retries '#{config[:ssh_retries]}'")
        debug("ec2:spot_price '#{config[:price]}'")
      end

      def amis
        @amis ||= begin
          json_file = File.join(File.dirname(__FILE__),
            %w{.. .. .. data amis.json})
          JSON.load(IO.read(json_file))
        end
      end

      #
      # Ordered mapping from config name to Fog name.  Ordered by preference
      # when looking up hostname.
      #
      INTERFACE_TYPES =
        {
          'dns' => 'dns_name',
          'public' => 'public_ip_address',
          'private' => 'private_ip_address'
        }

      #
      # Lookup hostname of a provided server using the configured interface.
      #
      def hostname(server)
        Kitchen::Driver::Ec2.hostname(server, config[:interface])
      end

      #
      # Lookup hostname of provided server.  If interface_type is provided use
      # that interface to lookup hostname.  Otherwise, try ordered list of
      # options.
      #
      def self.hostname(server, interface_type=nil)
        if interface_type
          interface_type = INTERFACE_TYPES.fetch(interface_type) do
            raise Kitchen::UserError, "Invalid interface [#{interface_type}]"
          end
          server.send(interface_type)
        else
          potential_hostname = nil
          INTERFACE_TYPES.values.each do |type|
            potential_hostname ||= server.send(type)
          end
          potential_hostname
        end
      end

      def submit_spot
        spot = request_spot
        info("Spot instance <#{spot.id}> requested.")
        info("Spot price is <#{spot.price}>.")
        spot.wait_for { print '.'; spot.state == 'active' }
        print '(spot active)'

        # tag assignation on the instance.
        if config[:tags]
          connection.create_tags(
            spot.instance_id,
            spot.tags
          )
        end
        connection.servers.get(spot.instance_id)
      end

      # A mapping from config key values to what Fog expects
      CONFIG_TO_AWS = {
        :ebs_volume_size => 'Ebs.VolumeSize',
        :ebs_volume_type => 'Ebs.VolumeType',
        :ebs_delete_on_termination => 'Ebs.DeleteOnTermination',
        :ebs_snapshot_id => 'Ebs.SnapshotId',
        :ebs_device_name => 'DeviceName',
        :ebs_virtual_name => 'VirtualName'
      }

      def block_device_mappings
        bdms = config[:block_device_mappings]

        # If they don't provide one, lets give them a default one
        if bdms.nil? || bdms.empty?
          bdms = [{
            :ebs_volume_type => 'standard',
            :ebs_volume_size => config[:ebs_volume_size],
            :ebs_delete_on_termination => config[:ebs_delete_on_termination],
            :ebs_snapshot_id => nil,
            :ebs_device_name => config[:ebs_device_name],
            :ebs_virtual_name => nil
          }]
        end

        # This could be helpful for users debugging
        image_id = config[:image_id]
        image = connection.images.get(image_id)
        if image.nil?
          raise "Could not find image [#{image_id}]"
        end
        root_device_name = image.root_device_name
        bdms.find { |bdm|
          if bdm[:ebs_device_name] == root_device_name
            info("Overriding root device [#{root_device_name}] from image [#{image_id}]")
          end
        }

        # Convert the provided keys to what Fog expects
        bdms = bdms.map do |bdm|
          Hash[bdm.map { |k, v| [CONFIG_TO_AWS[k], v] }]
        end

        bdms
      end
    end
  end
end
