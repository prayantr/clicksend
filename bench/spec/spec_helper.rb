# frozen_string_literal: true

# Real-socket specs for Client.new(adapter: :net_http_persistent). Run with
#   BUNDLE_GEMFILE=bench/Gemfile bundle exec rspec bench/spec
# (kept out of the core suite so faraday-net_http_persistent is not a
# development dependency of the gem; see research/1.2-observability-and-http.md).

LIB_DIR = File.expand_path("../../lib", __dir__)
$VERBOSE = true
module FailOnLibWarnings
  def warn(message, category: nil, **)
    raise "Warning emitted from lib/: #{message}" if message.include?(LIB_DIR)

    super
  end
end
Warning.singleton_class.prepend(FailOnLibWarnings)

require "tmpdir"
require "clicksend"
require "faraday/net_http_persistent"
require_relative "../support/keep_alive_server"

CERT_DIR = Dir.mktmpdir("clicksend-spike-certs")
at_exit { FileUtils.remove_entry(CERT_DIR) }
TestCertificates.trust_ca!(CERT_DIR)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
