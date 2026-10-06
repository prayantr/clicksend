# frozen_string_literal: true

require_relative "lib/clicksend/opentelemetry/version"

Gem::Specification.new do |spec|
  spec.name = "clicksend-opentelemetry"
  spec.version = Clicksend::OpenTelemetry::VERSION
  spec.authors = ["Amit Solanki", "Braj Pratap Singh"]
  spec.email = ["amit@prayantr.com"]

  spec.summary = "OpenTelemetry spans for the clicksend gem's instrumentation hook."
  spec.description = "An instrumenter for Clicksend::Client that opens one CLIENT span per ClickSend API call, " \
    "with retries as span events. Never records phone numbers, message text, bodies, query strings or credentials."
  spec.homepage = "https://github.com/prayantr/clicksend"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "source_code_uri" => "#{spec.homepage}/tree/master/companions/clicksend-opentelemetry",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  # The instrumenter contract (event names and payload keys) is clicksend's
  # public API since 1.1; a 2.0 may change it.
  spec.add_dependency "clicksend", ">= 1.1", "< 2"
  # The API only: the application chooses (or omits) the SDK and exporters.
  spec.add_dependency "opentelemetry-api", "~> 1.1"
end
