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
         :boolean => true,
         :description => "ignores prompts, just say YES!",
         :default => false

  option :disable_default_groups,
         :short => "-g",
         :long => "--disable-default-groups",
         :boolean => true,
         :description => "Disable auto generated default security groups (ignored in VPC mode)",
         :default => false

  option :hostname_style_groups,
         :short => "-h",
         :long => "--hostname-style-groups",
         :boolean => true,
         :description => "Use hostname style names for auto generated node security groups (ignored in VPC mode)",
         :default => false

  option :definitions_file,
         :short => "-d <definitions_directory>",
         :long => "--definitions_dir <definitions_directory>",
         :description => "yml definitions directory",
         :default => nil

  def definitions_from_directory(dir)
    definitions = Hash.new
    Dir.entries(dir).each do |f|
      if File.extname(f) == ".yml"
        puts "loading #{f}"
        loaded_defs = YAML.load_file(::File.join(dir,f))
        definitions = Chef::Mixin::DeepMerge.merge(definitions,loaded_defs)
      end
    end
    definitions
  end

  def run
    check_args(1)
    
    base_name, start_range, end_range = parse_servers(name_args[0])  

    env                = Chef::Config[:environment]  
    defs_dir           = Chef::Config[:nodefu_definitions] || config[:definitions] 
    yml_config         = definitions_from_directory defs_dir
    merged_config      = Chef::Mixin::DeepMerge.merge(yml_config['default'], yml_config['env'][env])
    node_spec_name     = config[:node_spec] || base_name 
    abort("I'm sorry I couldn't find any node_spec matches :(") unless (node_spec = merged_config['node_spec'][node_spec_name])

    domain             = merged_config['domain'] 
    vm_spec_name       = node_spec['vm_spec']
    vm_spec            = merged_config['vm_spec'][vm_spec_name]
    group_ids          = node_spec['group_ids'] ||= []
    aux_groups         = node_spec['aux_groups'] ||= []    

    elastic_ip_address = node_spec['elastic_ip_address']
    private_ip_address = node_spec['private_ip_address']

    unless elastic_ip_address.nil? && private_ip_address.nil?
      abort("Range isn't supported when a private_ip_address or an elastic_ip_address is set, please only create one instance") unless start_range == end_range
    end
    abort('private_ip_address option uses VPC mode, which requires a subnet_id in the definitions file for the node_spec]') if private_ip_address && node_spec['subnet_id'].nil?

    # Present the user with some totally rad visuals!!!
    ui.msg("#{ui.color('SHAZAM!',:red)} It looks like you want to launch #{ui.color((end_range - start_range + 1).to_s,:yellow)} of these:")
    ui.msg("#{ui.color('Base Name',:cyan)}: #{base_name}")
    ui.msg("#{ui.color('Node Spec',:cyan)}: #{node_spec_name}")
    ui.msg("#{ui.color('VPC Mode',:cyan)}: #{is_vpc?(node_spec)}")
    pretty_print_hash(node_spec)
    pretty_print_hash(vm_spec)
 
    unless config[:disable_default_groups] || is_vpc?(node_spec)
      ui.msg("#{ui.color('Auto generated security groups',:cyan)}: #{generate_security_groups("#{base_name}#{start_range}-#{end_range}",env,domain)}")
    end

    config[:yes] ? user_response = 'yes' : user_response = ui.ask_question("Does this seem right to you? [y/n]").downcase
    abort("See ya!") unless (['yes','y',].include?(user_response))

    threads = []   
    sema = Mutex.new
    for i in (start_range..end_range)
      ec2_server_request = Ec2ServerCreate.new
      node_name = "#{base_name}#{i}"
      full_node_name  = "#{node_name}.#{env}.#{domain}"  
      security_groups = if config[:disable_default_groups]
                          aux_groups
                        else
                          generate_security_groups(node_name,env,domain) + aux_groups 
                        end unless is_vpc?(node_spec)
      security_group_ids = group_ids

      # A handfull of the Ec2ServerCreate command line options use a :proc field so I have to
      # populate those by hand instead of simply passing a value to its config entry 
      Chef::Config[:knife][:aws_ssh_key_id]                 = vm_spec['ssh_key']
      Chef::Config[:knife][:image]                          = vm_spec['ami']
      Chef::Config[:knife][:region]                         = vm_spec['region']
      ec2_server_request.config[:image]                     = vm_spec['ami']
      ec2_server_request.config[:region]                    = vm_spec['region']
      ec2_server_request.config[:chef_node_name]            = full_node_name
      ec2_server_request.config[:run_list]                  = node_spec['run_list']      
      ec2_server_request.config[:flavor]                    = vm_spec['type']
      ec2_server_request.config[:security_groups]           = security_groups if security_groups
      ec2_server_request.config[:security_group_ids]        = security_group_ids if security_group_ids
      ec2_server_request.config[:associate_eip]             = elastic_ip_address if elastic_ip_address
      ec2_server_request.config[:subnet_id]                 = node_spec['subnet_id'] if node_spec['subnet_id']
      ec2_server_request.config[:private_ip_address]        = private_ip_address if private_ip_address
      ec2_server_request.config[:ssh_user]                  = vm_spec['user']
      ec2_server_request.config[:availability_zone]         = vm_spec['az']
      ec2_server_request.config[:distro]                    = vm_spec['bootstrap']
      ec2_server_request.config[:server_connect_attribute]  = node_spec['server_connect_attribute'] if node_spec['server_connect_attribute']
      ec2_server_request.config[:environment]               = Chef::Config[:environment]
      threads << Thread.new(full_node_name,ec2_server_request) do |full_node_name,request|
        e = nil
        begin 
            request.run
        rescue => e 
          config[:exit_on_fail] ? raise(e) : puts("#{full_node_name}: #{e.message}")
        end 
        sema.synchronize {
          [full_node_name, { 'server' => request.server, 'failure' => e, 'chef_node' => nil} ]
        }
        end        
    end
    threads.each(&:join)

    # Build a servers hash with the node names as the key from the object returned by the threads
    @servers = threads.inject({}) {|hash,t| hash[t.value[0]] = t.value[1]; hash}

    query = Chef::Search::Query.new
    query.search('node',"name:#{base_name}*#{env}*") { |n| @servers[n.name]['chef_node'] = n unless @servers[n.name].nil? } 

    ui.msg('') 

    failed = failed_nodes(@servers)
    unless failed.nil?
      failed.each_pair do |k,v| 
        if v['server'].nil?
          ui.msg("#{k}: #{v['failure']}")
        else
          ui.msg("#{k}: #{v['failure']}, #{v['server'].dns_name}, #{v['server'].id}") 
        end
      end
    end

    successful = successful_nodes(@servers)
    unless successful.nil?
      ui.msg(ui.color('Successful Nodes:',:green))
      successful.each_pair { |k,v| ui.msg("#{k}: #{v['id']}, #{v['server'].dns_name}, #{v['server'].id}") }
    end
  end 
end
