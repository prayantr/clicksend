# frozen_string_literal: true

RSpec.describe Clicksend::Connection do
  def connection(*outcomes, logger: nil)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: NO_RETRY, logger: logger)
  end

  let(:envelope) { {"http_code" => 200, "response_code" => "SUCCESS", "response_msg" => "OK", "data" => {"a" => 1}} }

  describe "request encoding" do
    it "JSON-encodes the body and sets Content-Type explicitly" do
      connection(FakeTransport.json(200, envelope)).request(:post, "/v3/x", body: {messages: [{body: "hi"}]})
      call = @transport.calls.first
      expect(call.body).to eq('{"messages":[{"body":"hi"}]}')
      expect(call.headers).to eq("Content-Type" => "application/json")
    end

    it "sends no body or Content-Type when there is no body" do
      connection(FakeTransport.json(200, envelope)).request(:get, "/v3/x", query: {page: 1})
      call = @transport.calls.first
      expect([call.body, call.headers, call.query]).to eq([nil, {}, {page: 1}])
    end
  end

  describe "successful responses" do
    it "returns a Response exposing the envelope" do
      response = connection(FakeTransport.json(200, envelope)).request(:get, "/v3/x")
      expect(response.http_status).to eq(200)
      expect(response.data).to eq("a" => 1)
      expect(response.response_code).to eq("SUCCESS")
      expect(response.response_msg).to eq("OK")
    end

    it "deep-freezes the parsed body" do
      response = connection(FakeTransport.json(200, envelope)).request(:get, "/v3/x")
      expect(response.body).to be_frozen
      expect(response.data).to be_frozen
    end

    it "returns a nil body for an empty response" do
      response = connection(FakeTransport.json(204, "")).request(:delete, "/v3/x")
      expect(response.body).to be_nil
      expect(response.data).to be_nil
    end

    it "tolerates JSON that is not an envelope" do
      response = connection(FakeTransport.json(200, [1, 2])).request(:get, "/v3/x")
      expect(response.body).to eq([1, 2])
      expect(response.data).to be_nil
    end

    it "raises MalformedResponseError for a 2xx body that is not JSON" do
      expect { connection(FakeTransport.json(200, "<html>ok</html>")).request(:get, "/v3/x") }
        .to raise_error(Clicksend::MalformedResponseError, /non-JSON body with HTTP 200/) { |e|
          expect(e.http_status).to eq(200)
          expect(e.body).to eq("<html>ok</html>")
        }
    end
  end

  describe "error responses" do
    {
      400 => Clicksend::BadRequestError,
      401 => Clicksend::AuthenticationError,
      403 => Clicksend::ForbiddenError,
      404 => Clicksend::NotFoundError,
      405 => Clicksend::ClientError,
      429 => Clicksend::RateLimitError,
      500 => Clicksend::ServerError,
      503 => Clicksend::ServerError
    }.each do |status, error_class|
      it "maps HTTP #{status} to #{error_class}" do
        expect { connection(FakeTransport.json(status, {})).request(:get, "/v3/x") }.to raise_error(error_class)
      end
    end

    it "exposes ClickSend's envelope on the error" do
      body = {"http_code" => 401, "response_code" => "UNAUTHORIZED", "response_msg" => "Authorization failed.", "data" => nil}
      expect { connection(FakeTransport.json(401, body, headers: {"x-ratelimit-limit" => "20"})).request(:get, "/v3/account") }
        .to raise_error(Clicksend::AuthenticationError, "HTTP 401: UNAUTHORIZED - Authorization failed. (GET /v3/account)") { |e|
          expect(e.http_status).to eq(401)
          expect(e.response_code).to eq("UNAUTHORIZED")
          expect(e.response_msg).to eq("Authorization failed.")
          expect(e.headers).to eq("x-ratelimit-limit" => "20")
          expect(e.body).to eq(body)
        }
    end

    it "keeps a non-JSON error body (e.g. a proxy's HTML page) as a String" do
      expect { connection(FakeTransport.json(502, "<html>Bad Gateway</html>")).request(:get, "/v3/x") }
        .to raise_error(Clicksend::ServerError, "HTTP 502 (GET /v3/x)") { |e| expect(e.body).to eq("<html>Bad Gateway</html>") }
    end

    it "handles an empty error body" do
      expect { connection(FakeTransport.json(500, "")).request(:get, "/v3/x") }
        .to raise_error(Clicksend::ServerError) { |e| expect(e.body).to be_nil }
    end

    it "ignores envelope fields with unexpected types" do
      expect { connection(FakeTransport.json(400, {"response_code" => 42})).request(:get, "/v3/x") }
        .to raise_error(Clicksend::BadRequestError, "HTTP 400 (GET /v3/x)") { |e| expect(e.response_code).to be_nil }
    end

    it "treats a 2xx response whose envelope reports an error http_code as that error" do
      body = {"http_code" => 401, "response_code" => "UNAUTHORIZED", "response_msg" => "Authorization failed.", "data" => nil}
      expect { connection(FakeTransport.json(200, body)).request(:post, "/v3/x") }
        .to raise_error(Clicksend::AuthenticationError) { |e| expect(e.http_status).to eq(401) }
    end

    it "parses Retry-After seconds and HTTP dates on rate-limit errors" do
      expect { connection(FakeTransport.json(429, {}, headers: {"retry-after" => "7"})).request(:get, "/v3/x") }
        .to raise_error(Clicksend::RateLimitError) { |e| expect(e.retry_after).to eq(7) }

      date = (Time.now + 30).httpdate
      expect { connection(FakeTransport.json(429, {}, headers: {"retry-after" => date})).request(:get, "/v3/x") }
        .to raise_error(Clicksend::RateLimitError) { |e| expect(e.retry_after).to be_within(2).of(30) }

      expect { connection(FakeTransport.json(429, {}, headers: {"retry-after" => "soon"})).request(:get, "/v3/x") }
        .to raise_error(Clicksend::RateLimitError) { |e| expect(e.retry_after).to be_nil }
    end

    it "propagates transport failures" do
      expect { connection(Clicksend::TimeoutError.new("slow")).request(:get, "/v3/x") }.to raise_error(Clicksend::TimeoutError)
    end
  end

  describe "logging" do
    it "logs one line per attempt with method, path (no query) and status" do
      logger = instance_double(Logger, info: nil)
      connection(FakeTransport.json(200, envelope), logger: logger).request(:get, "/v3/sms/history", query: {q: "to:+61411111111"})
      expect(logger).to have_received(:info).with(%r{\A\[clicksend\] GET /v3/sms/history -> 200 \(\d+ms\)\z})
    end
  end
end

RSpec.describe Clicksend::Connection, "retries" do
  let(:ok) { FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {}}) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }

  before { allow(Kernel).to receive(:sleep) }

  def connection(*outcomes)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: Clicksend::RetryPolicy.new(max_retries: 2), logger: logger)
  end

  it "retries an idempotent GET after a 5xx and returns the eventual success" do
    response = connection(FakeTransport.json(503, ""), ok).request(:get, "/v3/x", idempotent: true)
    expect(response.http_status).to eq(200)
    expect(@transport.calls.size).to eq(2)
    expect(Kernel).to have_received(:sleep).once
    expect(logger).to have_received(:warn).with(%r{GET /v3/x failed \(Clicksend::ServerError\), retrying in \d\.\d\ds \(retry 1 of 2\)})
  end

  it "attempts a non-idempotent POST exactly once when it times out" do
    conn = connection(Clicksend::TimeoutError.new("read timeout"), ok)
    expect { conn.request(:post, "/v3/sms/send", body: {}) }.to raise_error(Clicksend::TimeoutError)
    expect(@transport.calls.size).to eq(1)
    expect(Kernel).not_to have_received(:sleep)
  end

  it "attempts a non-idempotent POST exactly once on a 5xx" do
    expect { connection(FakeTransport.json(500, ""), ok).request(:post, "/v3/sms/send", body: {}) }
      .to raise_error(Clicksend::ServerError)
    expect(@transport.calls.size).to eq(1)
  end

  it "retries a POST that was rate limited, waiting for Retry-After" do
    limited = FakeTransport.json(429, {"response_code" => "HTTP_TOO_MANY_REQUESTS"}, headers: {"retry-after" => "1"})
    connection(limited, ok).request(:post, "/v3/sms/send", body: {})
    expect(@transport.calls.size).to eq(2)
    expect(Kernel).to have_received(:sleep).with(1)
  end

  it "retries a POST whose connection was refused (never sent)" do
    connection(Clicksend::ConnectionError.new("refused", request_sent: false), ok).request(:post, "/v3/sms/send", body: {})
    expect(@transport.calls.size).to eq(2)
  end

  it "retries a POST marked idempotent after a timeout" do
    connection(Clicksend::TimeoutError.new("read"), ok).request(:post, "/v3/sms/price", body: {}, idempotent: true)
    expect(@transport.calls.size).to eq(2)
  end

  it "raises the last error once retries are exhausted" do
    conn = connection(FakeTransport.json(503, ""), FakeTransport.json(502, ""), FakeTransport.json(504, ""), ok)
    expect { conn.request(:get, "/v3/x", idempotent: true) }.to raise_error(Clicksend::ServerError) { |e| expect(e.http_status).to eq(504) }
    expect(@transport.calls.size).to eq(3)
  end

  it "never retries an error reported only inside a 2xx body, even a 429, even for GET" do
    body = {"http_code" => 429, "response_code" => "HTTP_TOO_MANY_REQUESTS", "data" => nil}
    expect { connection(FakeTransport.json(200, body), ok).request(:post, "/v3/sms/send", body: {}) }
      .to raise_error(Clicksend::RateLimitError)
    expect(@transport.calls.size).to eq(1)

    expect { connection(FakeTransport.json(200, body.merge("http_code" => 503)), ok).request(:get, "/v3/x", idempotent: true) }
      .to raise_error(Clicksend::ServerError)
    expect(@transport.calls.size).to eq(1)
  end

  it "re-sends the identical request on retry" do
    connection(FakeTransport.json(429, ""), ok).request(:post, "/v3/sms/send", query: {a: 1}, body: {b: 2})
    expect(@transport.calls.map(&:to_h).uniq.size).to eq(1)
  end
end
