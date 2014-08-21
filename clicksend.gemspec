# -*- encoding: utf-8 -*-
require './lib/click_send/version'

Gem::Specification.new do |s|
  s.name = "clicksend"
  s.version = ClickSend::VERSION

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib"]
  s.authors = ["Amit Solanki", "Braj Pratap Singh"]
  s.date = "2014-06-30"
  s.description = "Rubygem to interact with ClickSend api"
  s.email = ["amit@prayantr.com", "braj@prayantr.com"]
  # s.executables = ["clicksend"]
  s.extra_rdoc_files = ["History.txt", "Manifest.txt", "README.md"]
  s.files = [ 
    "History.txt", 
    "Manifest.txt", 
    "README.md", 
    "Rakefile", 
    "bin/clicksend", 
    "lib/clicksend.rb", 
    "lib/click_send.rb",
    "lib/click_send/version.rb",    
    "lib/click_send/rest/account_balance.rb",
    "lib/click_send/rest/client.rb",
    "lib/click_send/rest/delivery_report.rb",
    "lib/click_send/rest/resource.rb",
    "lib/click_send/rest/sms.rb",     
  ]
  s.homepage = "http://github.com/prayantr/clicksend"
  s.licenses = ["MIT"]
  s.rdoc_options = ["--main", "README.md"]
  s.rubygems_version = "2.4.1"
  s.summary = "Rubygem to interact with ClickSend RESTful api to send sms via clicksend.com"
  s.test_files = Dir['spec/**/*.rb']

  s.add_dependency(%q<faraday>, ["~> 0.9"])
  s.add_dependency(%q<multi_json>, ["~> 1.10"])
  
  s.add_development_dependency(%q<rdoc>, ["~> 4.0"])
  s.add_development_dependency(%q<rspec>, ["~> 3.0"])
  s.add_development_dependency(%q<webmock>, ["~> 1.18"])
  s.add_development_dependency(%q<simplecov>, ["~> 0.8"])
  s.add_development_dependency(%q<hoe>, ["~> 3.12"])
end
