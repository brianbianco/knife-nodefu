# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "knife-nodefu/version"

Gem::Specification.new do |s|
  s.name        = 'knife-nodefu'
  s.version     = Knife::Nodefu::VERSION
  s.has_rdoc    = true
  s.authors     = ['Brian Bianco']
  s.email       = ['brian.bianco@gmail.com']
  s.homepage    = 'https://github.com/brianbianco/knife-nodefu'
  s.summary     = 'A knife plugin for simple node creation automation'
  s.description = s.summary
  s.extra_rdoc_files = ['README.rdoc', 'LICENSE' ]

  s.add_dependency 'knife-ec2'
  s.add_dependency 'chef', '>= 0.10'

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ['lib']
end
