require_relative 'nodefu_base'

class NodefuCreate < Chef::Knife

  deps do
    require 'fileutils'
    require 'yaml'
    require 'thread'
    require 'fog'
    Chef::Knife::Ec2ServerCreate.load_deps
    Chef::Knife::Ec2ServerDelete.load_deps
  end

  include NodefuBase

  banner "knife nodefu create <server><range> (OPTIONS)"

  attr_reader :servers

  option :node_spec,
         :short => "-n <node_spec>",
         :long => "--node_spec <node_spec>",
         :description => "The node spec to use",
         :default => nil

  option :yes,
         :short => "-y",
         :long => "--yes",
         :description => "ignores prompts, just say YES!",
         :default => nil
  
  option :definitions_file,
         :short => "-d <definitions_file_path>",
         :long => "--definitions_file <definitions_file_path>",
         :description => "yml definitions file",
         :default => nil 

  option :exit_on_fail,
         :short => "-e",
         :long => "--exit-on-fail",
         :description => "Exit if one of the servers fails to come up",
         :default => nil

  option :destroy_on_fail,
         :short => "-f",
         :long => "--destroy-on-fail",
         :description => "Terminate the ec2 instance on error",
         :default => nil

  def destroy_instances(servers)
    ec2_delete = Ec2ServerDelete.new 
    servers.each_pair.with_index do |(k,v),i| 
      if v['server'].nil?
        ui.msg("No server to delete for #{k}")
      else
        ec2_delete.name_args[i] = v['server'].id
      end
    end
    ec2_delete.config[:yes] = true
    ec2_delete.run 
  end

  def run
    check_args(1)
    env = Chef::Config[:environment]  
    definitions_file = config[:definitions_file].nil? ? Chef::Config[:nodefu_definitions_file] : config[:definitions_file] 
    @yml_config = YAML.load_file definitions_file

    base_name, start_range, end_range = parse_servers(name_args[0])  

    #merge the current environment hash with the defaults
    merged_configuration = Chef::Mixin::DeepMerge.merge(@yml_config['default'],@yml_config['env'][env])

    if (! config[:node_spec].nil?)
      node_spec_name = config[:node_spec]
    else 
      node_spec_name = base_name 
    end

    domain       = merged_configuration['domain'] 
    node_spec    = merged_configuration['node_spec'][node_spec_name]
    vm_spec_name = node_spec['vm_spec']
    vm_spec      = merged_configuration['vm_spec'][vm_spec_name]
    aux_groups   = node_spec['aux_groups'].nil? ? '' : ",#{node_spec['aux_groups'].join(',')}"

    #Present the user with some totally rad visuals!!!
    ui.msg "#{ui.color('SHAZAM!',:red)} It looks like you want to launch #{ui.color((end_range - start_range + 1).to_s,:yellow)} of these:"
    ui.msg("#{ui.color('Base Name',:cyan)}: #{base_name}")
    ui.msg("#{ui.color('Node Spec',:cyan)}: #{node_spec_name}")
    pretty_print_hash(node_spec)
    pretty_print_hash(vm_spec)
    ui.msg("#{ui.color('Auto generated security groups',:cyan)}: #{generate_security_groups("#{base_name}#{start_range}-#{end_range}",env)}")
 
    config[:yes] ? user_response = 'yes' : user_response = ui.ask_question("Does this seem right to you? [y/n]").downcase
    abort("See ya!") unless (['yes','y',].include?(user_response))

    threads = []   
    for i in (start_range..end_range)
      ec2_server_request = Ec2ServerCreate.new
      node_name = "#{base_name}#{i}"
      full_node_name = "#{base_name}#{i}.#{env}.#{domain}"  
      #A handfull of the Ec2ServerCreate command line options use a :proc field so I have to
      #populate those by hand instead of simply passing a value to its config entry 
      Chef::Config[:knife][:aws_ssh_key_id] = vm_spec['ssh_key']
      Chef::Config[:knife][:image]          = vm_spec['ami']
      Chef::Config[:knife][:region]         = vm_spec['region']
      ec2_server_request.config[:chef_node_name]    = full_node_name
      ec2_server_request.config[:run_list]          = node_spec['run_list']      
      ec2_server_request.config[:flavor]            = vm_spec['type']
      ec2_server_request.config[:security_groups]   = (generate_security_groups(node_name,env) + aux_groups).split(',') 
      ec2_server_request.config[:ssh_user]          = vm_spec['user']
      ec2_server_request.config[:availability_zone] = vm_spec['az']
      ec2_server_request.config[:distro]            = vm_spec['bootstrap'] 
      threads << Thread.new(full_node_name,ec2_server_request) do |full_node_name,request|
        e = nil
        begin 
          request.run
        rescue => e 
          config[:exit_on_fail] ? raise(e) : puts("#{full_node_name}: #{e.message}")
        end 
        [full_node_name, { 'server' => request.server, 'failure' => e, 'chef_node' => nil} ]
      end        
    end
    threads.each(&:join)

    #Build a servers hash with the node names as they key from the object returned by the threads
    @servers = threads.inject({}) {|hash,t| hash[t.value[0]] = t.value[1]; hash}

    query = Chef::Search::Query.new
    query.search('node',"name:#{base_name}*#{env}*") do |n|
      n.inspect
      @servers[n.name]['chef_node'] = n unless @servers[n.name].nil?
    end
  
    ui.msg('') 
    ui.msg(ui.color('Failed Nodes:',:red))
    failed = failed_nodes(@servers).each_pair { |k,v| ui.msg("#{k}: #{v['failure']}") }

    ui.msg(ui.color('Successful Nodes:',:green))
    successful = successful_nodes(@servers).each_pair { |k,v| ui.msg("#{k}: #{v['id']}, #{v['server'].dns_name}, #{v['server'].id}") }

    if config[:destroy_on_fail]
      ui.msg(ui.color("Destroying failed nodes:",:red))
      destroy_instances(failed)       
    end
  end 
end
