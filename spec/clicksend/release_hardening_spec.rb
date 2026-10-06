# frozen_string_literal: true

# Behaviour pinned by the 1.1.0 release-hardening pass (track A). Each example
# guards a line that a mutation could change without any other spec failing.
RSpec.describe "1.1.0 release hardening" do
  let(:ok) { FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {}}) }

  before { allow(Kernel).to receive(:sleep) }

  def connection(*outcomes, instrumenter: Clicksend::Instrumentation::Null)
    @transport = FakeTransport.new(*outcomes)
    Clicksend::Connection.new(transport: @transport, retry_policy: Clicksend::RetryPolicy.new(max_retries: 2), instrumenter: instrumenter)
  end

  def fake_client(*outcomes)
    @transport = FakeTransport.new(*outcomes)
    Clicksend::Client.new(username: "u", api_key: "k", transport: @transport, retry_policy: Clicksend::RetryPolicy.new(max_retries: 2))
  end

  def send_result(*statuses)
    messages = statuses.each_with_index.map { |status, i| {"message_id" => "ID-#{i}", "to" => "+61411111111", "status" => status} }
    FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {"messages" => messages}})
  end

  describe "an instrumenter that swallows the request's error" do
    let(:swallowing) do
      Object.new.tap do |o|
        o.define_singleton_method(:instrument) do |_name, payload = {}, &block|
          block.call(payload)
        rescue Exception # rubocop:disable Lint/RescueException
          nil
        end
      end
    end

    it "still raises the ambiguous error of a send, rather than returning it or nil" do
      conn = connection(Clicksend::TimeoutError.new("read"), instrumenter: swallowing)
      expect { conn.request(:post, "/v3/sms/send", body: {}) }.to raise_error(Clicksend::TimeoutError) { |e| expect(e).to be_ambiguous }
      expect(@transport.calls.size).to eq(1)
    end
  end

  describe "send results" do
    it "treats two results for one #deliver as ambiguous, not as the first message's outcome" do
      client = fake_client(send_result("SUCCESS", "SUCCESS"))
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }
        .to raise_error(Clicksend::MalformedResponseError, /Expected one message result, got 2/) { |e| expect(e).to be_ambiguous }
    end
  end

  describe "status boundaries" do
    it "treats an envelope http_code of exactly 400 inside a 2xx as an (ambiguous) error" do
      body = {"http_code" => 400, "response_code" => "BAD_REQUEST", "data" => nil}
      expect { connection(FakeTransport.json(200, body)).request(:post, "/v3/sms/send", body: {}) }
        .to raise_error(Clicksend::BadRequestError) { |e| expect(e).to be_ambiguous }
      expect(@transport.calls.size).to eq(1)
    end

    it "treats HTTP 300 as an unexpected status, not a success" do
      expect { connection(FakeTransport.json(300, {"data" => {}})).request(:post, "/v3/sms/send", body: {}) }
        .to raise_error(Clicksend::APIError) { |e|
          expect(e.http_status).to eq(300)
          expect(e).to be_ambiguous
        }
    end
  end

  describe "Retry-After values that are already in the past" do
    [["an HTTP-date in the past", "Wed, 21 Oct 2015 07:28:00 GMT"]].each do |label, value|
      it "treats #{label} as 0 seconds and retries a 429 at once" do
        limited = FakeTransport.json(429, "", headers: {"retry-after" => value})
        error = Clicksend::RateLimitError.new(http_status: 429, headers: {"retry-after" => value})
        expect(error.retry_after).to eq(0)
        expect(Kernel).to receive(:sleep).with(0.0)
        expect(connection(limited, ok).request(:post, "/v3/sms/send", body: {}).request.attempts).to eq(2)
      end
    end
  end

  [1, "true", "false", :yes].each do |value|
    it "treats idempotent: #{value.inspect} as not idempotent (only true counts)" do
      client = fake_client(FakeTransport.json(503, ""), ok)
      expect { client.request(:post, "/v3/sms/send", body: {}, idempotent: value) }
        .to raise_error(Clicksend::ServerError) { |e| expect(e).to be_ambiguous }
      expect(@transport.calls.size).to eq(1)
    end
  end

  it "retries marking one reply read after a 5xx (it is idempotent)" do
    client = fake_client(FakeTransport.json(500, ""), ok)
    expect(client.sms.mark_inbound_message_read("ABC-123")).to be_nil
    expect(@transport.calls.size).to eq(2)
  end
end
