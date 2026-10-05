# frozen_string_literal: true

require_relative "lib/clicksend/version"

Gem::Specification.new do |spec|
  spec.name = "clicksend"
  spec.version = Clicksend::VERSION
  spec.authors = ["Amit Solanki", "Braj Pratap Singh"]
  spec.email = ["amit@prayantr.com"]

  spec.summary = "Unofficial, focused Ruby client for the ClickSend SMS API (v3)."
  spec.description = <<~DESC.tr("\n", " ").strip
    A small, hand-written Ruby client for ClickSend messaging: send single and batch SMS,
    poll delivery receipts and replies, check your balance, and call any other ClickSend
    v3 endpoint through the same authenticated, retrying, error-mapping request path.
    Not affiliated with ClickSend.
  DESC
  spec.homepage = "https://github.com/prayantr/clicksend"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "https://rubydoc.info/gems/clicksend",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "MIGRATING.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", ">= 2.0.1", "< 3"
end
