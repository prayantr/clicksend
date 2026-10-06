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
  # An example that needs a newer clicksend than the oldest this gem supports
  # declares it (clicksend: ">= 1.2", clicksend_reason: "..."). Against the
  # clicksend in this checkout it always runs; CI's oldest-core job runs against
  # clicksend 1.1.0 from RubyGems, where it is skipped with this message.
  config.before do |example|
    requirement = example.metadata[:clicksend]
    next if requirement.nil? || Gem::Requirement.new(requirement).satisfied_by?(Gem::Version.new(Clicksend::VERSION))

    skip "needs clicksend #{requirement}: #{example.metadata.fetch(:clicksend_reason)}; this run uses #{Clicksend::VERSION}"
  end
  config.before do
    SPANS.reset
    OTEL_LOG.truncate(0)
    OTEL_LOG.rewind
  end
end
