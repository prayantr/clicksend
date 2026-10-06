# frozen_string_literal: true

# Prints the span tree for one retried call with the clicksend span alone and
# combined with opentelemetry-instrumentation-faraday and/or -net_http, each
# in a fresh process (the SDK can be configured only once).
#
#   BUNDLE_GEMFILE=companions/clicksend-opentelemetry/Gemfile bundle exec ruby bench/otel_nesting.rb

require "clicksend"
require "clicksend/opentelemetry"
require "opentelemetry/sdk"
require "opentelemetry-instrumentation-faraday"
require "opentelemetry-instrumentation-net_http"
require_relative "../spec/support/local_server"

MODES = {
  "clicksend only" => [],
  "+ faraday" => ["OpenTelemetry::Instrumentation::Faraday"],
  "+ net_http" => ["OpenTelemetry::Instrumentation::Net::HTTP"],
  "+ faraday + net_http" => ["OpenTelemetry::Instrumentation::Faraday", "OpenTelemetry::Instrumentation::Net::HTTP"]
}.freeze

def tree(spans)
  by_parent = spans.group_by(&:parent_span_id)
  roots = spans.reject { |s| spans.any? { |p| p.span_id == s.parent_span_id } }
  lines = []
  walk = lambda do |span, depth|
    attrs = span.attributes.slice("http.response.status_code", "url.full", "url.path", "url.query", "clicksend.attempts")
    lines << "#{"  " * depth}- #{span.name} [#{span.kind}, #{span.instrumentation_scope.name}] #{attrs}" \
      "#{" events=#{span.events.map(&:name)}" if span.events}"
    by_parent.fetch(span.span_id, []).sort_by(&:start_timestamp).each { |child| walk.call(child, depth + 1) }
  end
  roots.sort_by(&:start_timestamp).each { |root| walk.call(root, 0) }
  lines
end

MODES.each do |mode, instrumentations|
  pid = fork do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    OpenTelemetry::SDK.configure do |c|
      c.logger = Logger.new(File::NULL)
      c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
      instrumentations.each { |name| c.use(name) }
    end
    server = LocalServer.new(:unavailable, :ok)
    base_url = "http://127.0.0.1:#{server.port}"
    client = Clicksend::Client.new(username: "u", api_key: "k", base_url: base_url,
      retry_policy: Clicksend::RetryPolicy.new(base_delay: 0, max_delay: 0),
      instrumenter: Clicksend::OpenTelemetry::Instrumenter.new(base_url: base_url))
    client.request(:get, "/v3/sms/history", query: {q: "to:+61411111111"}, operation: "sms.history")
    puts "### #{mode}", tree(exporter.finished_spans), ""
    server.stop
    $stdout.flush
    exit!(0)
  end
  Process.wait(pid)
end
