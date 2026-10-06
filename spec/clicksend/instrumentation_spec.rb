# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

RSpec.describe "Instrumentation" do
  let(:phone) { "+61411111111" }
  let(:body) { "Your code is 481516" }
  let(:events) { [] }

  before { allow(Kernel).to receive(:sleep) }

  around do |example|
    subscriber = ActiveSupport::Notifications.subscribe(/\.clicksend\z/) { |event| events << event }
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def instrumented_client(**options)
    client(instrumenter: ActiveSupport::Notifications, **options)
  end

  describe "with ActiveSupport::Notifications" do
    it "publishes request.clicksend for a wrapped call, with its operation and outcome" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(fixture("sms_send")))
      instrumented_client.sms.deliver(to: phone, body: body)

      event = events.find { |e| e.name == "request.clicksend" }
      expect(event.payload).to eq(http_method: :post, path: "/v3/sms/send", operation: "sms.deliver", idempotent: false,
        attempts: 1, http_status: 200, response_code: "SUCCESS", ambiguous: false)
      expect(event.duration).to be >= 0
    end

    it "publishes retry.clicksend before each retry, and the attempt count on the request event" do
      stub_api(:get, "/v3/account").to_return({status: 503, body: ""}, {status: 503, body: ""}, json_response(fixture("account")))
      instrumented_client.account.fetch

      retries = events.select { |e| e.name == "retry.clicksend" }
      expect(retries.map(&:payload)).to match([
        hash_including(http_method: :get, path: "/v3/account", operation: "account.fetch", attempt: 1, error_class: "Clicksend::ServerError", http_status: 503, delay: kind_of(Numeric)),
        hash_including(attempt: 2)
      ])
      expect(events.find { |e| e.name == "request.clicksend" }.payload).to include(attempts: 3, http_status: 200)
    end

    it "records failures, including ambiguity, and lets ActiveSupport attach the exception" do
      stub_api(:post, "/v3/sms/send").to_return(status: 500, body: "")
      expect { instrumented_client.sms.deliver(to: phone, body: body) }.to raise_error(Clicksend::ServerError)

      payload = events.find { |e| e.name == "request.clicksend" }.payload
      expect(payload).to include(attempts: 1, http_status: 500, response_code: nil, ambiguous: true)
      expect(payload[:exception]).to eq(["Clicksend::ServerError", "HTTP 500 (POST /v3/sms/send)"])
    end

    it "records connection failures with no HTTP status" do
      stub_request(:get, "#{ApiHelpers::BASE}/v3/account").to_raise(Faraday::ConnectionFailed.new("reset"))
      expect { instrumented_client(max_retries: 0).account.fetch }.to raise_error(Clicksend::ConnectionError)
      expect(events.first.payload).to include(http_status: nil, ambiguous: false)
    end

    it "never puts credentials, headers, query strings, bodies, numbers or message text in any payload" do
      stub_api(:post, "/v3/sms/send").to_return({status: 429, body: "", headers: {"Retry-After" => "0"}}, json_response(fixture("sms_send")))
      stub_api(:get, "/v3/sms/history").with(query: hash_including("q" => "to:#{phone}")).to_return(json_response(envelope({"total" => 0, "per_page" => 15, "current_page" => 1, "last_page" => 0, "data" => []})))
      c = instrumented_client
      c.sms.deliver(to: phone, body: body, custom_string: "otp:42")
      c.sms.history(to: phone)

      dumped = events.map { |e| e.payload.inspect }.join("\n")
      [phone, body, "otp:42", ApiHelpers::API_KEY, ApiHelpers::USERNAME, "Basic", "q=", "to:"].each do |secret|
        expect(dumped).not_to include(secret)
      end
      expect(events.map(&:name)).to eq(%w[retry.clicksend request.clicksend request.clicksend])
    end
  end

  describe "with any object that has #instrument" do
    it "works with an instrumenter that does not yield the payload, and publishes nothing else" do
      calls = []
      yielding_nothing = Object.new
      yielding_nothing.define_singleton_method(:instrument) do |name, payload = {}, &block|
        calls << [name, payload.dup]
        block&.call
      end
      stub_api(:get, "/v3/account").to_return(json_response(fixture("account")))
      expect(client(instrumenter: yielding_nothing).account.fetch.username).to be_a(String)
      expect(calls).to eq([["request.clicksend", {http_method: :get, path: "/v3/account", operation: "account.fetch", idempotent: true}]])
    end

    it "is optional: the default publishes nothing" do
      stub_api(:get, "/v3/account").to_return(json_response(fixture("account")))
      expect(client.instrumenter).to eq(Clicksend::Instrumentation::Null)
      client.account.fetch
      expect(events).to be_empty
    end

    it "rejects an instrumenter without #instrument" do
      expect { client(instrumenter: Object.new) }.to raise_error(Clicksend::ConfigurationError, /instrument/)
    end
  end
end
