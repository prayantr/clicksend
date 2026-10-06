# frozen_string_literal: true

# Fail on any warning from this gem's lib/ or clicksend's, as the core suite does.
LIB_DIRS = [File.expand_path("../lib", __dir__), File.expand_path("../../../lib", __dir__)].freeze
$VERBOSE = true
Warning[:deprecated] = true
module FailOnLibWarnings
  def warn(message, category: nil, **)
    raise "Warning emitted from lib/: #{message}" if LIB_DIRS.any? { |dir| message.include?(dir) }

    super
  end
end
Warning.singleton_class.prepend(FailOnLibWarnings)

require "logger"
require "stringio"
require "opentelemetry/sdk"
require "opentelemetry-instrumentation-faraday"
require "opentelemetry-instrumentation-net_http"
require "clicksend/opentelemetry"
require "clicksend/testing"
# The core gem's real-socket test server (this companion lives in the same repository).
require_relative "../../../spec/support/local_server"

SPANS = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OTEL_LOG = StringIO.new
OpenTelemetry::SDK.configure do |c|
  c.logger = Logger.new(OTEL_LOG)
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(SPANS))
  # As in an application using opentelemetry-instrumentation-all: HTTP-level
  # spans for each attempt, nested under this gem's span.
  c.use "OpenTelemetry::Instrumentation::Faraday"
  c.use "OpenTelemetry::Instrumentation::Net::HTTP"
end

module SpanHelpers
  SCOPE = "clicksend-opentelemetry"

  def spans
    SPANS.finished_spans
  end

  def clicksend_spans
    spans.select { |span| span.instrumentation_scope.name == SCOPE }
  end

  def clicksend_span
    found = clicksend_spans
    raise "expected one clicksend span, got #{found.size}" unless found.size == 1

    found.first
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.include SpanHelpers
  config.before do
    SPANS.reset
    OTEL_LOG.truncate(0)
    OTEL_LOG.rewind
  end
end
