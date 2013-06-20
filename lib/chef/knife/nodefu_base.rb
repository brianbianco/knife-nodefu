module NodefuBase
  class ServerRangeError < StandardError; end 
  class NameFormatError < StandardError; end

  def pretty_print_hash(hash,color=:magenta)
    hash.each_pair do |k,v|
      ui.msg("#{ui.color(k,color)}: #{v}")
    end
  end

  def generate_security_groups(name,env,domain)
    if config[:hostname_style_groups]
      ["#{name}.#{env}.#{domain}","default_#{env}","default"]
    else
      ["node_#{env}_#{name}","default_#{env}","default"]
    end
  end

  def check_args(size)
    if name_args.size < 1
      ui.fatal "Not enough arguments, expecting at least #{size}"
      exit 1
    end
  end

  def parse_servers(servers_string)
    raise ArgumentError if servers_string.nil? 
    results = /([a-zA-z\-\.^\s]*)\[(\d+)-(\d+)\]/.match(servers_string) || results = /([a-zA-z\-\.^\s]*)(\d+)/.match(servers_string) 
    raise NameFormatError if results.nil? 
    base_name = results[1]
    start_range = results[2].to_i
    end_range = results[3].nil? ? start_range.to_i : results[3].to_i 
    raise ServerRangeError if end_range.to_i < start_range.to_i
    return [base_name,start_range,end_range]
  end

  def failed_nodes(servers)
    servers.select {|k,v| v['chef_node'].nil? || !v['failure'].nil? }    
  end

  def successful_nodes(servers)
    servers.select {|k,v| !v['chef_node'].nil? && v['failure'].nil? }
  end

  def is_vpc?(node_spec)
    node_spec['subnet_id'] || node_spec['private_ip_address'] ? true : false
  end
end
