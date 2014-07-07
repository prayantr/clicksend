# -*- encoding: utf-8 -*-
# stub: clicksend 1.0.0.20140630194833 ruby lib
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
  s.executables = ["clicksend"]
  s.extra_rdoc_files = ["History.txt", "Manifest.txt", "README.txt"]
  s.files = [
    ".autotest", 
    "History.txt", 
    "Manifest.txt", 
    "README.txt", 
    "Rakefile", 
    "bin/clicksend", 
    "lib/clicksend.rb", 
    "lib/click_send.rb",
    "lib/click_send/version.rb",    
    "lib/click_send/REST/account_balance.rb",
    "lib/click_send/REST/client.rb",
    "lib/click_send/REST/delivery_report.rb",
    "lib/click_send/REST/resource.rb",
    "lib/click_send/REST/sms.rb",    
    "test/test_clicksend.rb", 
  ]
  s.homepage = "http://github.com/prayantr/clicksend"
  s.licenses = ["MIT"]
  s.rdoc_options = ["--main", "README.txt"]
  s.rubygems_version = "2.2.2"
  s.summary = "Rubygem to interact with ClickSend RESTful api to send sms via clicksend.com"
  s.test_files = ["test/test_clicksend.rb"]

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<rdoc>, ["~> 4.0"])
      s.add_development_dependency(%q<hoe>, ["~> 3.12"])
      s.add_development_dependency(%q<muti_json>, ["~> 1.10"])
      s.add_development_dependency(%q<faraday>, ["~> 0.9"])
      s.add_development_dependency(%q<rspec>, ["~> 3.0"])
      s.add_development_dependency(%q<webmock>, ["~> 1.18"])
    else
      s.add_dependency(%q<rdoc>, ["~> 4.0"])
      s.add_dependency(%q<hoe>, ["~> 3.12"])
      s.add_development_dependency(%q<muti_json>, ["~> 1.10"])
      s.add_development_dependency(%q<faraday>, ["~> 0.9"])
      s.add_development_dependency(%q<rspec>, ["~> 3.0"])
      s.add_development_dependency(%q<webmock>, ["~> 1.18"])
    end
  else
    s.add_dependency(%q<rdoc>, ["~> 4.0"])
    s.add_dependency(%q<hoe>, ["~> 3.12"])
    s.add_dependency(%q<muti_json>, ["~> 1.10"])
    s.add_dependency(%q<faraday>, ["~> 0.9"])
    s.add_development_dependency(%q<rspec>, ["~> 3.0"])
    s.add_development_dependency(%q<webmock>, ["~> 1.18"])
  end

end
