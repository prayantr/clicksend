# frozen_string_literal: true

if ENV.fetch("COVERAGE", "1") == "1"
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    skip "/spec/"
    skip "/script/"
  end
end

LIB_DIR = File.expand_path("../lib", __dir__)

# Surface every warning raised from lib/ (including Ruby deprecations) as a failure,
# so new Ruby releases can't silently start warning about this gem's code.
$VERBOSE = true
Warning[:deprecated] = true
module FailOnLibWarnings
  def warn(message, category: nil, **)
    raise "Warning emitted from lib/: #{message}" if message.include?(LIB_DIR)

    super
  end
end
Warning.singleton_class.prepend(FailOnLibWarnings)

require "clicksend"
require "webmock/rspec"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.filter_run_excluding :contract unless ENV["CLICKSEND_CONTRACT"] == "1"
  config.filter_run_excluding :live unless ENV["CLICKSEND_LIVE"] == "1"

  # Credentials must never leak in from the developer's shell (live specs opt out).
  config.around do |example|
    if example.metadata[:live]
      example.run
    else
      begin
        saved = ENV.to_h.slice("CLICKSEND_USERNAME", "CLICKSEND_API_KEY")
        ENV.delete("CLICKSEND_USERNAME")
        ENV.delete("CLICKSEND_API_KEY")
        example.run
      ensure
        saved.each { |k, v| ENV[k] = v }
      end
    end
  end
end
