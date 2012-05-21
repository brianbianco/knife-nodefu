require_relative 'nodefu_base'

class NodefuCreate < Chef::Knife

  deps do
    require 'fileutils'
    require 'yaml'
    require 'thread'
    Chef::Knife::Ec2ServerCreate.load_deps
  end

  include NodefuBase

  banner "knife nodefu create <server><range> (OPTIONS)"

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

  def run
    check_args(1)
    env = Chef::Config[:environment]  
    definitions_file = config[:definitions_file].nil? ? Chef::Config[:nodefu_definitions_file] : config[:definitions_file] 
    @yml_config = YAML.load_file definitions_file

    servers = name_args[0]
    base_name, start_range, end_range = parse_servers(servers)  

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
      threads << Thread.new(node_name,ec2_server_request) do |node_name,request|
        e = nil
        begin 
          request.run
        rescue => e
          puts e.message
        end 
        {node_name => request.server, 'exception' => e}
      end        
    end
    threads.each(&:join)
    servers = threads.map(&:value) 
  end 
end
