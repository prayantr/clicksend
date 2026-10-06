# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

RSpec.describe Clicksend::OpenTelemetry::Instrumenter do
  let(:phone) { "+61411111111" }
  let(:text) { "Your code is 481516" }
  let(:fake) { Clicksend::Testing::FakeAPI.new }
  let(:instrumenter) { Clicksend::OpenTelemetry::Instrumenter.new }

  def traced_client(**options)
    fake.client(instrumenter: instrumenter, **options)
  end

  describe "a successful call" do
    it "is one CLIENT span named after the operation, with HTTP and clicksend attributes" do
      traced_client.sms.deliver(to: phone, body: text)

      span = clicksend_span
      expect(span.name).to eq("clicksend sms.deliver")
      expect(span.kind).to eq(:client)
      expect(span.attributes).to eq(
        "http.request.method" => "POST",
        "server.address" => "rest.clicksend.com",
        "server.port" => 443,
        "url.path" => "/v3/sms/send",
        "clicksend.operation" => "sms.deliver",
        "clicksend.idempotent" => false,
        "http.response.status_code" => 200,
        "clicksend.response_code" => "SUCCESS",
        "clicksend.attempts" => 1,
        "clicksend.ambiguous" => false
      )
      expect(span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)
      expect(span.events).to be_nil
    end

    it "names a call without an operation after its method only (paths may hold IDs)" do
      fake.stub(:get, "/v3/sms/templates") { |_| {"data" => []} }
      traced_client.request(:get, "/v3/sms/templates")
      expect(clicksend_span.name).to eq("clicksend GET")
      expect(clicksend_span.attributes).not_to have_key("clicksend.operation")
    end

    it "takes server.address and server.port from base_url, and can leave out url.path" do
      instrumenter = described_class.new(base_url: "http://localhost:8080", record_path: false)
      fake.client(instrumenter: instrumenter).account.fetch
      expect(clicksend_span.attributes).to include("server.address" => "localhost", "server.port" => 8080)
      expect(clicksend_span.attributes).not_to have_key("url.path")
    end

    it "is a child of the application's current span, and restores the context afterwards" do
      tracer = OpenTelemetry.tracer_provider.tracer("app")
      tracer.in_span("job") do |job|
        traced_client.account.fetch
        expect(OpenTelemetry::Trace.current_span).to equal(job)
      end
      job = spans.find { |s| s.name == "job" }
      expect(clicksend_span.parent_span_id).to eq(job.span_id)
      expect(clicksend_span.trace_id).to eq(job.trace_id)
    end
  end

  describe "retries" do
    it "adds a clicksend.retry event per retry, and the attempt count, to the one span" do
      fake.fail_next(status: 503, processed: false, times: 2)
      traced_client.account.fetch

      span = clicksend_span
      expect(span.attributes).to include("clicksend.attempts" => 3, "http.response.status_code" => 200, "clicksend.ambiguous" => false)
      expect(span.events.map(&:name)).to eq(%w[clicksend.retry clicksend.retry])
      expect(span.events.map(&:attributes)).to match([
        {"clicksend.retry.attempt" => 1, "clicksend.retry.delay" => kind_of(Float), "error.type" => "Clicksend::ServerError", "http.response.status_code" => 503},
        hash_including("clicksend.retry.attempt" => 2)
      ])
      expect(fake.requests.size).to eq(3)
    end

    it "ignores a retry.clicksend outside a span instead of failing" do
      expect { |block| instrumenter.instrument("retry.clicksend", {attempt: 1}, &block) }.to yield_control.once
      expect(OTEL_LOG.string).to be_empty
    end
  end

  describe "failures" do
    it "marks the span as an error, without the error message, and keeps the request single-attempt and ambiguous" do
      fake.fail_next(status: 500, processed: true)
      expect { traced_client.sms.deliver(to: phone, body: text) }.to raise_error(Clicksend::ServerError) { |e| expect(e).to be_ambiguous }

      span = clicksend_span
      expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(span.status.description).to eq("Clicksend::ServerError")
      expect(span.attributes).to include("error.type" => "Clicksend::ServerError", "clicksend.ambiguous" => true,
        "clicksend.attempts" => 1, "http.response.status_code" => 500)
      exception = span.events.find { |e| e.name == "exception" }
      expect(exception.attributes["exception.type"]).to eq("Clicksend::ServerError")
      expect(exception.attributes["exception.message"]).to eq("Clicksend::ServerError HTTP 500 INTERNAL_SERVER_ERROR (POST /v3/sms/send)")
      expect(exception.attributes["exception.stacktrace"]).not_to include("HTTP 500:")
      expect(fake.requests.size).to eq(1)
    end

    it "leaves the path out of the exception message too with record_path: false",
      clicksend: ">= 1.2", clicksend_reason: "it cancels a message, and sms.cancel was added in 1.2.0" do
      fake.fail_next(status: 500, processed: false)
      client = fake.client(instrumenter: described_class.new(record_path: false))
      expect { client.sms.cancel("ABC-123") }.to raise_error(Clicksend::ServerError)
      exception = clicksend_span.events.find { |e| e.name == "exception" }
      expect(exception.attributes["exception.message"]).to eq("Clicksend::ServerError HTTP 500 INTERNAL_SERVER_ERROR (PUT)")
      expect(clicksend_span.to_h.to_s).not_to include("ABC-123")
    end

    it "keeps a send timeout ambiguous and single-attempt, with no HTTP status" do
      fake.fail_next(:timeout, processed: true)
      expect { traced_client.sms.deliver(to: phone, body: text) }.to raise_error(Clicksend::TimeoutError) { |e|
        expect(e).to be_a(Clicksend::AmbiguousRequestError)
        expect(e.request.attempts).to eq(1)
      }
      expect(clicksend_span.attributes).to include("clicksend.ambiguous" => true, "clicksend.attempts" => 1, "error.type" => "Clicksend::TimeoutError")
      expect(clicksend_span.attributes).not_to have_key("http.response.status_code")
      expect(fake.requests.size).to eq(1)
      expect(fake.sent_messages.size).to eq(1) # ClickSend did process it: exactly why it must not be retried
    end

    it "does not mark a per-message rejection as an error: the HTTP call itself succeeded" do
      fake.reject(to: "+61400000000", status: "INVALID_RECIPIENT")
      expect { traced_client.sms.deliver(to: "+61400000000", body: text) }.to raise_error(Clicksend::MessageRejected)

      expect(clicksend_span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)
      expect(clicksend_span.attributes).to include("http.response.status_code" => 200, "clicksend.ambiguous" => false)
      expect(clicksend_span.attributes).not_to have_key("error.type")
    end
  end

  describe "when the tracer itself fails" do
    let(:broken_provider) do
      tracer = Object.new
      tracer.define_singleton_method(:start_span) { |*, **| raise IOError, "exporter down" }
      provider = Object.new
      provider.define_singleton_method(:tracer) { |*| tracer }
      provider
    end

    it "still runs the request exactly once and returns its result" do
      client = traced_client(instrumenter: described_class.new(tracer_provider: broken_provider))
      expect(client.sms.deliver(to: phone, body: text).status).to eq("SUCCESS")
      expect(fake.requests.size).to eq(1)
      expect(OTEL_LOG.string).to include("clicksend-opentelemetry", "exporter down")
    end

    it "keeps a send timeout ambiguous and single-attempt" do
      fake.fail_next(:timeout, processed: false)
      client = traced_client(instrumenter: described_class.new(tracer_provider: broken_provider))
      expect { client.sms.deliver(to: phone, body: text) }.to raise_error(Clicksend::TimeoutError) { |e|
        expect(e).to be_ambiguous
        expect(e.request.attempts).to eq(1)
      }
      expect(fake.requests.size).to eq(1)
    end

    it "does not change the outcome when recording the outcome fails" do
      span = OpenTelemetry::Trace::Span::INVALID.dup
      span.define_singleton_method(:add_attributes) { |*| raise "boom" }
      span.define_singleton_method(:add_event) { |*, **| raise "boom" }
      tracer = Object.new
      tracer.define_singleton_method(:start_span) { |*, **| span }
      provider = Object.new
      provider.define_singleton_method(:tracer) { |*| tracer }
      fake.fail_next(:timeout, processed: true)
      client = traced_client(instrumenter: described_class.new(tracer_provider: provider))

      expect { client.sms.deliver(to: phone, body: text) }.to raise_error(Clicksend::TimeoutError) { |e| expect(e).to be_ambiguous }
      expect(client.account.fetch.balance).to be_a(String) # and the next call works
      expect(fake.requests.size).to eq(2)
      expect(OpenTelemetry::Trace.current_span).to eq(OpenTelemetry::Trace::Span::INVALID)
    end
  end

  it "never records credentials, headers, query strings, bodies, phone numbers or message text" do
    fake.stub(:get, "/v3/sms/history") { |_| {"data" => {"total" => 0, "per_page" => 15, "current_page" => 1, "last_page" => 0, "data" => []}} }
    fake.fail_next(status: 429)
    client = traced_client(username: "cs-user-1234", api_key: "cs-key-5678")
    client.sms.deliver(to: phone, body: text, custom_string: "otp:42")
    client.sms.history(to: phone)
    fake.fail_next(status: 400)
    expect { client.sms.deliver(to: phone, body: text) }.to raise_error(Clicksend::BadRequestError)

    events = clicksend_spans.flat_map { |s| s.events.to_a }
    stacktraces = events.filter_map { |e| e.attributes["exception.stacktrace"] }.join("\n")
    dumped = clicksend_spans.map { |s| [s.name, s.attributes, s.status.description].inspect }.join("\n") +
      events.map { |e| [e.name, e.attributes.except("exception.stacktrace")].inspect }.join("\n")
    [phone, phone.delete("+"), text, "otp:42", "cs-user-1234", "cs-key-5678", "Basic", "q=", "to:"].each do |secret|
      expect(dumped).not_to include(secret)
    end
    expect(stacktraces).not_to be_empty
    [phone, text, "otp:42", "cs-key-5678"].each { |secret| expect(stacktraces).not_to include(secret) }
    expect(clicksend_spans.map(&:name)).to eq(["clicksend sms.deliver", "clicksend sms.history", "clicksend sms.deliver"])
  end

  describe Clicksend::OpenTelemetry::FanOut do
    let(:events) { [] }

    around do |example|
      subscriber = ActiveSupport::Notifications.subscribe(/\.clicksend\z/) { |event| events << event }
      example.run
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "publishes the same ActiveSupport events as before, and one span, for one request" do
      fake.fail_next(status: 503, processed: false)
      fake.client(instrumenter: ActiveSupport::Notifications).account.fetch
      alone = events.map { |e| [e.name, e.payload] }
      events.clear
      fake.reset!

      fake.fail_next(status: 503, processed: false)
      fake.client(instrumenter: described_class.new(ActiveSupport::Notifications, instrumenter)).account.fetch

      expect(events.map { |e| [e.name, e.payload] }).to eq(alone)
      expect(clicksend_span.events.map(&:name)).to eq(["clicksend.retry"])
      expect(fake.requests.size).to eq(2)
    end

    it "does not record an outer subscriber's failure as the request's error" do
      ActiveSupport::Notifications.subscribe("request.clicksend") { |*| raise "metrics down" }
      client = fake.client(instrumenter: described_class.new(ActiveSupport::Notifications, instrumenter))
      expect(client.sms.deliver(to: phone, body: text).status).to eq("SUCCESS")
      expect(clicksend_span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)
      expect(fake.requests.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe("request.clicksend")
    end

    it "runs the block once even with no instrumenters, and rejects non-instrumenters" do
      expect { |block| described_class.new.instrument("request.clicksend", {}, &block) }.to yield_control.once
      expect { described_class.new(Object.new) }.to raise_error(ArgumentError)
    end
  end
end
