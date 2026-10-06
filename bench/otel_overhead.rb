# frozen_string_literal: true

# Per-call cost of instrumentation, over an in-memory transport (no network,
# no Faraday), so only the gem's request path and the instrumenter remain.
#
#   BUNDLE_GEMFILE=companions/clicksend-opentelemetry/Gemfile bundle exec ruby bench/otel_overhead.rb
#
# The SDK cases use a BatchSpanProcessor with an exporter that drops spans:
# what an application pays on the request thread with a real exporter.

require "clicksend"
require "clicksend/opentelemetry"
require "opentelemetry/sdk"
require "active_support"
require "active_support/notifications"
require "json"

ITERATIONS = Integer(ENV.fetch("ITERATIONS", "20000"))
SEND_BODY = File.read(File.expand_path("../spec/fixtures/sms_send.json", __dir__))

# Answers every call with ClickSend's send response.
class CannedTransport
  RESPONSE = Clicksend::Transport::Response.new(status: 200, headers: {"content-type" => "application/json"}.freeze, body: SEND_BODY)

  def call(_method, _path, query: nil, body: nil, headers: {})
    RESPONSE
  end
end

class DroppingExporter
  def export(_spans, timeout: nil) = OpenTelemetry::SDK::Trace::Export::SUCCESS
  def force_flush(timeout: nil) = OpenTelemetry::SDK::Trace::Export::SUCCESS
  def shutdown(timeout: nil) = OpenTelemetry::SDK::Trace::Export::SUCCESS
end

def client(instrumenter)
  Clicksend::Client.new(username: "u", api_key: "k", transport: CannedTransport.new, instrumenter: instrumenter)
end

def measure(label, instrumenter)
  c = client(instrumenter)
  500.times { c.sms.deliver(to: "+61411111111", body: "hello") } # warm-up
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ITERATIONS.times { c.sms.deliver(to: "+61411111111", body: "hello") }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  {label: label, us_per_call: (elapsed / ITERATIONS * 1_000_000).round(1),
   allocs_per_call: ((GC.stat(:total_allocated_objects) - allocated) / ITERATIONS.to_f).round}
end

ActiveSupport::Notifications.subscribe("request.clicksend") { |event| event.duration }
results = []
results << measure("no instrumenter (Instrumentation::Null)", nil)
results << measure("ActiveSupport::Notifications, 1 subscriber", ActiveSupport::Notifications)
# Before OpenTelemetry::SDK.configure the API's provider is a no-op proxy:
# the cost of the adapter in an app that has not configured tracing.
results << measure("OTel adapter, API only (no SDK configured)", Clicksend::OpenTelemetry::Instrumenter.new)

OpenTelemetry::SDK.configure do |c|
  c.logger = Logger.new(File::NULL)
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(DroppingExporter.new))
end
otel = Clicksend::OpenTelemetry::Instrumenter.new
results << measure("OTel adapter, SDK + batch processor (sampled)", otel)
results << measure("FanOut(ActiveSupport::Notifications, OTel adapter)", Clicksend::OpenTelemetry::FanOut.new(ActiveSupport::Notifications, otel))

baseline = results.first
puts "Ruby #{RUBY_VERSION}, #{ITERATIONS} calls of sms.deliver each"
puts "| instrumenter | us/call | added us/call | allocations/call | added allocations |"
puts "|---|---|---|---|---|"
results.each do |r|
  puts "| #{r[:label]} | #{r[:us_per_call]} | #{(r[:us_per_call] - baseline[:us_per_call]).round(1)} | #{r[:allocs_per_call]} | #{r[:allocs_per_call] - baseline[:allocs_per_call]} |"
end
