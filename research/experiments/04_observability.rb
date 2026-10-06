# frozen_string_literal: true

# Experiment 4: what a Rails app gets from clicksend 1.1's instrumentation
# without any companion gem, and what generic OpenTelemetry auto-instrumentation
# records for the same calls.
#
#   bundle exec ruby 04_observability.rb
#
# No network: FakeAPI for the instrumentation part, Faraday's :test adapter
# (through the gem's real Faraday transport) for the OpenTelemetry part.

require "bundler/setup"
require "logger"
require "json"
require "active_support"
require "active_support/core_ext/class/attribute"
require "active_support/notifications"
require "active_support/subscriber"
require "active_support/structured_event_subscriber"
require "clicksend"
require "clicksend/testing"

fake = Clicksend::Testing::FakeAPI.new
client = fake.client(instrumenter: ActiveSupport::Notifications)

# 1. A ten-line key=value log subscriber (what lograge / semantic_logger users want).
lines = []
ActiveSupport::Notifications.subscribe(/\.clicksend\z/) do |event|
  p = event.payload
  fields = {event: event.name, operation: p[:operation], method: p[:http_method], path: p[:path],
            status: p[:http_status], code: p[:response_code], attempts: p[:attempts], ambiguous: p[:ambiguous],
            attempt: p[:attempt], delay: p[:delay], error: p[:error_class] || p.dig(:exception, 0),
            duration_ms: event.duration&.round(1)}.compact
  lines << fields.map { |k, v| "#{k}=#{v}" }.join(" ")
end

client.sms.deliver(to: "+61411111111", body: "secret text 481516", custom_string: "otp:1")
fake.fail_next(status: 500, processed: false, path: "/v3/account") # idempotent GET: retried
client.account.fetch
fake.fail_next(:timeout, processed: true, path: "/v3/sms/send")
begin
  client.sms.deliver(to: "+61411111111", body: "secret text 481516")
rescue Clicksend::Error
end
puts "== key=value lines from AS::Notifications"
lines.each { |l| puts "  #{l}" }
leaked = lines.grep(/61411111111|481516|secret/)
puts "  lines containing phone/body: #{leaked.size}"

# 2. Rails 8.1 structured events: AS::Subscriber dispatch by method name works
#    for "request.clicksend" and "retry.clicksend" (`retry` is a keyword, but a
#    legal method name).
class ClicksendEvents < ActiveSupport::StructuredEventSubscriber
  def request(event)
    emit_event("clicksend.request", event.payload.slice(:operation, :http_method, :path, :http_status, :response_code, :attempts, :ambiguous)
      .merge(duration_ms: event.duration.round(2), exception_class: event.payload[:exception_object]&.class&.name))
  end

  def retry(event)
    emit_event("clicksend.retry", event.payload.slice(:operation, :attempt, :delay, :error_class, :http_status))
  end
end
ClicksendEvents.attach_to :clicksend
collected = []
ActiveSupport.event_reporter.subscribe(Class.new { define_method(:emit) { |e| collected << e } }.new)
fake.fail_next(status: 429, retry_after: 0, path: "/v3/account")
client.account.fetch
puts "== Rails.event (ActiveSupport::EventReporter) events"
collected.each { |e| puts "  #{e[:name]} #{e[:payload].inspect}" }

# 3. Generic OpenTelemetry Faraday auto-instrumentation, with no clicksend code.
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/faraday"
exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
OpenTelemetry::SDK.configure do |c|
  c.logger = Logger.new(nil)
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
  c.use "OpenTelemetry::Instrumentation::Faraday"
end
stubs = Faraday::Adapter::Test::Stubs.new do |stub|
  stub.get("/v3/sms/history") do
    [200, {"Content-Type" => "application/json"},
      {http_code: 200, response_code: "SUCCESS", response_msg: "ok",
       data: {total: 0, per_page: 15, current_page: 1, last_page: 0, data: []}}.to_json]
  end
end
otel_client = Clicksend::Client.new(username: "u", api_key: "k", adapter: [:test, stubs])
otel_client.sms.history(to: "+61411111111")
puts "== OpenTelemetry Faraday auto-instrumentation span for sms.history(to:)"
exporter.finished_spans.each do |span|
  puts "  name=#{span.name.inspect}"
  span.attributes.each { |k, v| puts "    #{k}=#{v}" }
end
