# -*- encoding: utf-8 -*-
# stub: clicksend 1.0.0.20140630194833 ruby lib

Gem::Specification.new do |s|
  s.name = "clicksend"
  s.version = "1.0.0.20140630194833"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib"]
  s.authors = ["Braj Pratap Singh"]
  s.date = "2014-06-30"
  s.description = "FIX (describe your package)"
  s.email = ["braj@prayantr.com"]
  s.executables = ["clicksend"]
  s.extra_rdoc_files = ["History.txt", "Manifest.txt", "README.txt"]
  s.files = [".autotest", ".gemtest", "History.txt", "Manifest.txt", "README.txt", "Rakefile", "bin/clicksend", "lib/clicksend.rb", "test/test_clicksend.rb"]
  s.homepage = "FIX (url)"
  s.licenses = ["MIT"]
  s.rdoc_options = ["--main", "README.txt"]
  s.rubygems_version = "2.2.2"
  s.summary = "FIX (describe your package)"
  s.test_files = ["test/test_clicksend.rb"]

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<rdoc>, ["~> 4.0"])
      s.add_development_dependency(%q<hoe>, ["~> 3.12"])
    else
      s.add_dependency(%q<rdoc>, ["~> 4.0"])
      s.add_dependency(%q<hoe>, ["~> 3.12"])
    end
  else
    s.add_dependency(%q<rdoc>, ["~> 4.0"])
    s.add_dependency(%q<hoe>, ["~> 3.12"])
  end
end
