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

# The rule that decides whether a failure may be retried at all lives in the
# connection, not the policy, so no RetryPolicy (or custom policy) can make a
# request repeat after it may already have been processed.
RSpec.describe Clicksend::Connection, "retry safety" do
  let(:ok) { FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {}}) }

  before { allow(Kernel).to receive(:sleep) }

  # A policy that would retry anything it is asked about, as often as allowed.
  let(:eager_policy) do
    Struct.new(:max_retries, :asked) {
      def delay(error:, attempt:)
        asked << error.class
        0
      end
    }.new(5, [])
  end

  def connection(*outcomes, policy: eager_policy)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: policy)
  end

  def outcome(name)
    {
      rate_limited: FakeTransport.json(429, ""),
      refused: Clicksend::ConnectionError.new("refused", request_sent: false),
      read_timeout: Clicksend::TimeoutError.new("read"),
      reset: Clicksend::ConnectionError.new("reset"),
      server_error: FakeTransport.json(503, ""),
      bad_request: FakeTransport.json(400, ""),
      not_found: FakeTransport.json(404, ""),
      envelope_error: FakeTransport.json(200, {"http_code" => 500, "data" => nil}),
      malformed_2xx: FakeTransport.json(200, "<html>")
    }.fetch(name)
  end

  #                                   idempotent: [retried?, ambiguous?]   non-idempotent: [retried?, ambiguous?]
  {
    rate_limited: [[true, false], [true, false]],
    refused: [[true, false], [true, false]],
    read_timeout: [[true, false], [false, true]],
    reset: [[true, false], [false, true]],
    server_error: [[true, false], [false, true]],
    bad_request: [[false, false], [false, false]],
    not_found: [[false, false], [false, false]],
    envelope_error: [[false, false], [false, true]],
    malformed_2xx: [[false, false], [false, true]]
  }.each do |name, (for_idempotent, for_unsafe)|
    {true => for_idempotent, false => for_unsafe}.each do |idempotent, (retried, ambiguous)|
      kind = idempotent ? "an idempotent request" : "a non-idempotent request"

      it "#{retried ? "retries" : "does not retry"} #{name.to_s.tr("_", " ")} on #{kind}#{" and marks it ambiguous" if ambiguous}" do
        conn = connection(outcome(name), ok)
        if retried
          expect(conn.request(:post, "/v3/x", idempotent: idempotent).request.attempts).to eq(2)
        else
          expect { conn.request(:post, "/v3/x", idempotent: idempotent) }.to raise_error(Clicksend::Error) { |e|
            expect(e.ambiguous?).to be(ambiguous)
            expect(e.is_a?(Clicksend::AmbiguousRequestError)).to be(ambiguous)
            expect(e.request).to have_attributes(http_method: :post, path: "/v3/x", idempotent: idempotent, attempts: 1)
          }
          expect(eager_policy.asked).to be_empty
          expect(@transport.calls.size).to eq(1)
        end
      end
    end
  end

  it "marks an error ambiguous only after the last attempt, when retries were possible" do
    conn = connection(Clicksend::ConnectionError.new("refused", request_sent: false), Clicksend::TimeoutError.new("read"))
    expect { conn.request(:post, "/v3/sms/send") }.to raise_error(Clicksend::TimeoutError) { |e|
      expect(e).to be_ambiguous
      expect(e.request.attempts).to eq(2)
    }
  end

  it "does not retry when the policy returns something other than a non-negative finite number" do
    [nil, false, -1, Float::INFINITY, "1"].each do |answer|
      policy = Struct.new(:max_retries, :answer) { def delay(**) = answer }.new(3, answer)
      expect { connection(FakeTransport.json(503, ""), ok, policy: policy).request(:get, "/v3/x", idempotent: true) }
        .to raise_error(Clicksend::ServerError)
      expect(@transport.calls.size).to eq(1)
    end
  end

  it "waits for whatever the policy decides" do
    connection(FakeTransport.json(503, ""), ok, policy: Struct.new(:max_retries) { def delay(**) = 0.25 }.new(1)).request(:get, "/v3/x", idempotent: true)
    expect(Kernel).to have_received(:sleep).with(0.25)
  end
end

RSpec.describe Clicksend::Connection, "request context" do
  before { allow(Kernel).to receive(:sleep) }

  def connection(*outcomes)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: Clicksend::RetryPolicy.new(max_retries: 2, base_delay: 0))
  end

  it "attaches the request and attempt count to successful responses" do
    ok = FakeTransport.json(200, {"data" => {}})
    response = connection(FakeTransport.json(429, ""), ok).request(:get, "/v3/account", query: {secret: "x"}, idempotent: true, operation: "account.fetch")
    expect(response.request).to eq(Clicksend::RequestInfo.new(http_method: :get, path: "/v3/account", operation: "account.fetch", idempotent: true, attempts: 2))
  end

  it "attaches it to errors, after every attempt was made" do
    conn = connection(FakeTransport.json(503, ""), FakeTransport.json(503, ""), FakeTransport.json(503, ""))
    expect { conn.request(:get, "/v3/account", idempotent: true, operation: "account.fetch") }.to raise_error(Clicksend::ServerError) { |e|
      expect(e.request.attempts).to eq(3)
      expect(e.request.operation).to eq("account.fetch")
      expect(e).to be_retryable
    }
  end
end

# Regressions from the adversarial review of the 1.1 core: nothing outside the
# gem (instrumenters, loggers, custom transports, custom policies) may turn a
# processed send into a non-Clicksend error, or loop.
RSpec.describe Clicksend::Connection, "hardening" do
  let(:ok) { FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {}}) }

  before { allow(Kernel).to receive(:sleep) }

  def connection(*outcomes, instrumenter: Clicksend::Instrumentation::Null, logger: nil, policy: Clicksend::RetryPolicy.new(max_retries: 2))
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: policy, instrumenter: instrumenter, logger: logger)
  end

  def instrumenter(&behaviour)
    Object.new.tap { |o| o.define_singleton_method(:instrument, &behaviour) }
  end

  describe "a failing instrumenter" do
    let(:raises_after) { instrumenter { |_name, payload = {}, &block| block&.call(payload).tap { raise "metrics backend down" } } }

    it "cannot replace the result of a request that was sent" do
      response = connection(ok, instrumenter: raises_after).request(:post, "/v3/sms/send", body: {})
      expect(response.http_status).to eq(200)
      expect(@transport.calls.size).to eq(1)
    end

    it "cannot replace the ambiguous error of a send" do
      conn = connection(Clicksend::TimeoutError.new("read"), instrumenter: raises_after)
      expect { conn.request(:post, "/v3/sms/send", body: {}) }.to raise_error(Clicksend::AmbiguousRequestError)
    end

    it "copes with an instrumenter that yields a frozen payload" do
      frozen = instrumenter { |_name, payload = {}, &block| block.call(payload.dup.freeze) }
      expect(connection(ok, instrumenter: frozen).request(:post, "/v3/sms/send", body: {}).http_status).to eq(200)
    end

    it "raises ConfigurationError, without sending, when the instrumenter never runs the request" do
      lazy = instrumenter { |_name, _payload = {}| nil }
      expect { connection(ok, instrumenter: lazy).request(:post, "/v3/sms/send", body: {}) }.to raise_error(Clicksend::ConfigurationError, /must yield/)
      expect(@transport.calls).to be_empty
    end

    it "lets an instrumenter's failure before the request through, as nothing was sent" do
      broken = instrumenter { |*| raise ArgumentError, "bad subscriber" }
      expect { connection(ok, instrumenter: broken).request(:post, "/v3/sms/send", body: {}) }.to raise_error(ArgumentError, "bad subscriber")
      expect(@transport.calls).to be_empty
    end

    it "passes a block to retry.clicksend and ignores its failures" do
      seen = []
      strict = instrumenter do |name, payload = {}, &block|
        seen << [name, !block.nil?]
        raise "retry failed" if name == "retry.clicksend"
        block.call(payload)
      end
      response = connection(FakeTransport.json(429, ""), ok, instrumenter: strict).request(:get, "/v3/x")
      expect(response.request.attempts).to eq(2)
      expect(seen).to eq([["request.clicksend", true], ["retry.clicksend", true]])
    end
  end

  describe "a failing logger" do
    it "cannot turn a completed request into an error" do
      logger = instance_double(Logger)
      allow(logger).to receive(:info).and_raise(IOError, "disk full")
      expect(connection(ok, logger: logger).request(:post, "/v3/sms/send", body: {}).http_status).to eq(200)
    end
  end

  describe "a custom transport" do
    it "turns an unexpected exception into an ambiguous ConnectionError for a send" do
      expect { connection(Errno::ECONNRESET.new).request(:post, "/v3/sms/send", body: {}) }.to raise_error(Clicksend::ConnectionError) { |e|
        expect(e).to be_ambiguous
        expect(e.request_may_have_been_sent?).to be(true)
        expect(e.cause).to be_a(Errno::ECONNRESET)
      }
    end

    it "retries an unexpected exception only for idempotent requests" do
      expect(connection(Errno::ECONNRESET.new, ok).request(:get, "/v3/x", idempotent: true).request.attempts).to eq(2)
      expect { connection(Errno::ECONNRESET.new, ok).request(:post, "/v3/x") }.to raise_error(Clicksend::ConnectionError)
    end

    it "never modifies a frozen or reused exception instance" do
      frozen = Clicksend::TimeoutError.new("read").freeze
      expect { connection(frozen).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::TimeoutError) { |e| expect(e).to be_ambiguous }
      expect(frozen).not_to be_ambiguous

      shared = Clicksend::ConnectionError.new("reset")
      expect { connection(shared).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::ConnectionError)
      expect(shared).not_to be_ambiguous
      expect(shared.request).to be_nil
    end

    it "treats a response without a valid status as malformed, and ambiguous for a send" do
      [0, nil, 600, "200"].each do |status|
        raw = Clicksend::Transport::Response.new(status: status, headers: {}, body: "")
        expect { connection(raw).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::MalformedResponseError) { |e| expect(e).to be_ambiguous }
      end
    end

    it "treats an unexpected 3xx on a send as ambiguous, not as a rejection" do
      expect { connection(FakeTransport.json(302, "")).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::APIError) { |e| expect(e).to be_ambiguous }
    end
  end

  describe "a custom retry policy" do
    it "cannot exceed its own max_retries" do
      always = Struct.new(:max_retries) { def delay(**) = 0 }.new(3)
      limited = Array.new(10) { FakeTransport.json(429, "") }
      expect { connection(*limited, policy: always).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::RateLimitError)
      expect(@transport.calls.size).to eq(4)
    end

    it "is ignored when its answers are unusable" do
      [Complex(1, 1), 10**400, Rational(10**400, 3), "1", Object.new].each do |answer|
        policy = Struct.new(:max_retries, :answer) { def delay(**) = answer }.new(2, answer)
        verbose, $VERBOSE = $VERBOSE, true
        expect { connection(FakeTransport.json(429, ""), ok, policy: policy).request(:get, "/v3/x") }
          .to raise_error(Clicksend::RateLimitError).and output("").to_stderr
      ensure
        $VERBOSE = verbose
      end
      bad_budget = Struct.new(:max_retries) { def delay(**) = 0 }.new("2")
      expect { connection(FakeTransport.json(429, ""), ok, policy: bad_budget).request(:get, "/v3/x") }.to raise_error(Clicksend::RateLimitError)
    end
  end

  describe "query strings written into the path" do
    it "are never reported in errors, logs or instrumentation" do
      events = []
      recorder = instrumenter do |name, payload = {}, &block|
        events << [name, payload]
        block&.call(payload)
      end
      log = StringIO.new
      conn = connection(FakeTransport.json(500, ""), instrumenter: recorder, logger: Logger.new(log))
      expect { conn.request(:post, "/v3/sms/history?q=to:+61411111111#frag") }.to raise_error(Clicksend::ServerError) { |e|
        expect(e.message).to eq("HTTP 500 (POST /v3/sms/history)")
        expect(e.request.path).to eq("/v3/sms/history")
      }
      expect(events.inspect + log.string).not_to include("61411111111")
      expect(@transport.calls.first.path).to eq("/v3/sms/history?q=to:+61411111111#frag") # still sent as given
    end
  end
end

# Regressions from the hostile pre-release review.
RSpec.describe Clicksend::Connection, "pre-release review" do
  let(:ok) { FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {}}) }

  before { allow(Kernel).to receive(:sleep) }

  def connection(*outcomes, instrumenter: Clicksend::Instrumentation::Null, policy: Clicksend::RetryPolicy.new(max_retries: 2), logger: nil)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: policy, instrumenter: instrumenter, logger: logger)
  end

  it "reports an unreadable 2xx send response as an ambiguous Clicksend error, never nil or a foreign error" do
    raw = Clicksend::Transport::Response.new(status: 200, headers: {}, body: "{\"data\":{}} \xFF".dup.force_encoding("UTF-8"))
    outcome = begin
      connection(raw).request(:post, "/v3/sms/send")
    rescue Clicksend::Error => e
      e
    end
    # Depending on the json version the stray byte is accepted or not; either way the outcome is the gem's.
    expect(outcome).to be_a(Clicksend::Response).or(satisfy { |e| e.is_a?(Clicksend::MalformedResponseError) && e.ambiguous? })

    bad_headers = Clicksend::Transport::Response.new(status: 429, headers: nil, body: "")
    # A 429 is not processed; with nil headers there is no Retry-After, so the policy backs off and retries.
    expect(connection(bad_headers, FakeTransport.json(200, {})).request(:post, "/v3/sms/send").request.attempts).to eq(2)

    no_body = Clicksend::Transport::Response.new(status: 200, headers: {}, body: nil)
    expect { connection(no_body).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::MalformedResponseError) { |e|
      expect(e).to be_ambiguous
      expect(e.cause).to be_a(NoMethodError)
    }
  end

  it "never lets a bug inside the request be mistaken for an instrumenter failure and swallowed" do
    seen = []
    recorder = Object.new
    recorder.define_singleton_method(:instrument) do |_name, payload = {}, &block|
      seen << payload
      block&.call(payload)
    end
    no_body = Clicksend::Transport::Response.new(status: 200, headers: {}, body: nil)
    expect { connection(no_body, instrumenter: recorder).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::MalformedResponseError)
  end

  it "sends once even if the instrumenter calls the block twice" do
    twice = Object.new
    twice.define_singleton_method(:instrument) do |_name, payload = {}, &block|
      block.call(payload)
      block.call(payload)
    end
    expect(connection(ok, ok, instrumenter: twice).request(:post, "/v3/sms/send")).to be_a(Clicksend::Response)
    expect(@transport.calls.size).to eq(1)
  end

  it "classifies any other Clicksend error from a custom transport as unknown: ambiguous for a send, not retried" do
    expect { connection(Clicksend::ServerError.new(http_status: 503), ok).request(:post, "/v3/sms/send") }
      .to raise_error(Clicksend::ServerError) { |e|
        expect(e).to be_ambiguous
        expect(e.request.path).to eq("/v3/sms/send")
      }
    expect(@transport.calls.size).to eq(1)
  end

  it "keeps the request's own error when the retry policy raises, and stops retrying" do
    broken = Struct.new(:max_retries) { def delay(**) = raise(NoMethodError, "bug") }.new(3)
    expect { connection(FakeTransport.json(500, ""), ok, policy: broken).request(:get, "/v3/x", idempotent: true) }.to raise_error(Clicksend::ServerError)
    expect(@transport.calls.size).to eq(1)
  end

  it "never copies a foreign exception's message, which may hold a URL, query string or body" do
    leaky = IOError.new("POST https://u:KEY@rest.clicksend.com/v3/sms/send?to=+61411111111 body=code 481516")
    expect { connection(leaky).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::ConnectionError) { |e|
      expect(e.message).to eq("The transport failed: IOError (POST /v3/sms/send)")
      expect(e.cause).to be(leaky)
    }
  end
end

RSpec.describe Clicksend::Connection, "mutation-testing gaps" do
  def connection(*outcomes)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: Clicksend::RetryPolicy.new(max_retries: 2, base_delay: 0))
  end

  before { allow(Kernel).to receive(:sleep) }

  it "strips a fragment even without a query string" do
    expect { connection(FakeTransport.json(500, "")).request(:post, "/v3/contacts/1#token-123") }
      .to raise_error(Clicksend::ServerError, "HTTP 500 (POST /v3/contacts/1)")
  end

  it "treats a MalformedResponseError raised by a custom transport as unknown: ambiguous for a send, never retried" do
    expect { connection(Clicksend::MalformedResponseError.new("garbled"), FakeTransport.json(200, {})).request(:post, "/v3/sms/send") }
      .to raise_error(Clicksend::MalformedResponseError) { |e| expect(e).to be_ambiguous }
    expect(@transport.calls.size).to eq(1)
  end
end

RSpec.describe Clicksend::Connection, "instrumentation invariants (mutation-tested)" do
  let(:ok) { FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {}}) }

  def connection(*outcomes, instrumenter: Clicksend::Instrumentation::Null)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: Clicksend::RetryPolicy.new(max_retries: 2, base_delay: 0), instrumenter: instrumenter)
  end

  it "propagates an unexpected error raised while the request is running, rather than returning nil" do
    allow(Kernel).to receive(:sleep).and_raise(RuntimeError, "unexpected")
    recorder = Object.new
    recorder.define_singleton_method(:instrument) { |_name, payload = {}, &block| block&.call(payload) }
    expect { connection(FakeTransport.json(503, ""), ok, instrumenter: recorder).request(:get, "/v3/x", idempotent: true) }
      .to raise_error(RuntimeError, "unexpected")
  end

  it "still returns the outcome when a subscriber freezes the payload the gem writes to" do
    freezer = Object.new
    freezer.define_singleton_method(:instrument) do |_name, payload = {}, &block|
      payload.freeze
      block.call(payload)
    end
    expect(connection(ok, instrumenter: freezer).request(:post, "/v3/sms/send")).to be_a(Clicksend::Response)
    expect { connection(Clicksend::TimeoutError.new("read"), instrumenter: freezer).request(:post, "/v3/sms/send") }
      .to raise_error(Clicksend::AmbiguousRequestError)
  end
end

# 1.2 hardening: an instrumenter that keeps the request block, runs it on
# another thread, or swallows what it raises must never send late, send
# twice, or make #request return nil after a send.
RSpec.describe Clicksend::Connection, "instrumenter lifecycle" do
  let(:ok) { FakeTransport.json(200, {"http_code" => 200, "response_code" => "SUCCESS", "data" => {}}) }

  before { allow(Kernel).to receive(:sleep) }

  def connection(transport, instrumenter)
    described_class.new(transport: transport, retry_policy: Clicksend::RetryPolicy.new(max_retries: 2), instrumenter: instrumenter)
  end

  def instrumenter(&behaviour)
    Object.new.tap { |o| o.define_singleton_method(:instrument, &behaviour) }
  end

  # A transport that signals when it is entered and answers only when released.
  def gated_transport(response)
    entered = Queue.new
    release = Queue.new
    calls = []
    transport = Object.new
    transport.define_singleton_method(:call) do |method, path, **|
      calls << [method, path]
      entered << true
      release.pop
      response
    end
    [transport, entered, release, calls]
  end

  it "never sends from a block kept and called after #instrument returned" do
    kept = nil
    deferring = instrumenter { |_name, payload = {}, &block| kept = [block, payload] }
    transport = FakeTransport.new(ok)
    expect { connection(transport, deferring).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::ConfigurationError, /must yield/) { |e|
      expect(e).not_to be_ambiguous
    }
    block, payload = kept
    expect { block.call(payload) }.to raise_error(Clicksend::ConfigurationError, /after #instrument returned/)
    expect(transport.calls).to be_empty
  end

  it "never sends from a block that another thread runs only after #instrument returned" do
    go = Queue.new
    thread = nil
    late = instrumenter do |_name, payload = {}, &block|
      thread = Thread.new do
        go.pop
        block.call(payload)
      rescue Clicksend::ConfigurationError => e
        e
      end
      nil
    end
    transport = FakeTransport.new(ok)
    expect { connection(transport, late).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::ConfigurationError, /must yield/)
    go << true
    expect(thread.value).to be_a(Clicksend::ConfigurationError)
    expect(transport.calls).to be_empty
  end

  {post: true, get: false}.each do |method, ambiguous|
    it "raises a ConfigurationError (ambiguous: #{ambiguous}) rather than nil when a #{method.upcase} is still running on another thread" do
      transport, entered, release, calls = gated_transport(ok)
      runner = nil
      elsewhere = instrumenter do |_name, payload = {}, &block|
        runner = Thread.new { block.call(payload) }
        entered.pop # the request is being sent on the other thread
        nil
      end
      expect { connection(transport, elsewhere).request(method, "/v3/x", idempotent: method == :get) }.to raise_error(Clicksend::ConfigurationError, /returned before the request finished/) { |e|
        expect(e.ambiguous?).to be(ambiguous)
        expect(e.cause).to be_nil
      }
      release << true
      expect(runner.value).to be_a(Clicksend::Response)
      expect(calls.size).to eq(1)
    end
  end

  it "does not let an instrumenter's own exception escape while the request runs on another thread" do
    transport, entered, release, calls = gated_transport(ok)
    runner = nil
    failing = instrumenter do |_name, payload = {}, &block|
      runner = Thread.new { block.call(payload) }
      entered.pop
      raise IOError, "subscriber failed"
    end
    expect { connection(transport, failing).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::ConfigurationError) { |e|
      expect(e).to be_ambiguous
      expect(e.cause).to be_a(IOError)
    }
    release << true
    runner.join
    expect(calls.size).to eq(1)
  end

  it "returns the result when the block runs to completion on another thread before #instrument returns" do
    joining = instrumenter { |_name, payload = {}, &block| Thread.new { block.call(payload) }.value }
    transport = FakeTransport.new(ok)
    expect(connection(transport, joining).request(:post, "/v3/sms/send")).to be_a(Clicksend::Response)
    expect { connection(FakeTransport.new(Clicksend::TimeoutError.new("read")), joining).request(:post, "/v3/sms/send") }
      .to raise_error(Clicksend::TimeoutError) { |e| expect(e).to be_ambiguous }
  end

  it "raises an ambiguous ConfigurationError, not nil, when the instrumenter swallows an exception that escaped a send" do
    escaping = Class.new(Exception) # rubocop:disable Lint/InheritException
    swallowing = instrumenter do |_name, payload = {}, &block|
      block.call(payload)
    rescue Exception # rubocop:disable Lint/RescueException
      nil
    end
    transport = FakeTransport.new(escaping.new("from the transport"))
    expect { connection(transport, swallowing).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::ConfigurationError) { |e|
      expect(e).to be_ambiguous
    }
    expect(transport.calls.size).to eq(1)
  end

  it "never swallows an exception that is not a StandardError (e.g. Interrupt) raised after the request" do
    interrupting = instrumenter do |_name, payload = {}, &block|
      block.call(payload)
      raise Interrupt
    end
    expect { connection(FakeTransport.new(ok), interrupting).request(:post, "/v3/sms/send") }.to raise_error(Interrupt)
  end

  it "sends once and keeps the result when the block is called twice, even from two threads" do
    transport = FakeTransport.new(ok, ok)
    twice = instrumenter do |_name, payload = {}, &block|
      block.call(payload)
      Thread.new { block.call(payload) }.join
    end
    expect(connection(transport, twice).request(:post, "/v3/sms/send")).to be_a(Clicksend::Response)
    expect(transport.calls.size).to eq(1)
  end
end

RSpec.describe Clicksend::Connection, "delays that can't be slept" do
  def connection(*outcomes, policy:)
    @transport = FakeTransport.new(*outcomes)
    described_class.new(transport: @transport, retry_policy: policy)
  end

  let(:ok) { FakeTransport.json(200, {"data" => {}}) }

  it "raises the 429 instead of Kernel.sleep's RangeError when an unlimited policy meets a huge Retry-After" do
    allow(Kernel).to receive(:sleep).and_call_original
    huge = FakeTransport.json(429, "", headers: {"retry-after" => "99999999999999999999"})
    policy = Clicksend::RetryPolicy.new(max_retry_after: Float::INFINITY)
    expect { connection(huge, ok, policy: policy).request(:post, "/v3/sms/send") }.to raise_error(Clicksend::RateLimitError) { |e|
      expect(e.request.attempts).to eq(1)
      expect(e).not_to be_ambiguous
    }
    expect(Kernel).not_to have_received(:sleep)
  end

  it "gives up on a custom policy's delay beyond what Kernel.sleep accepts, and still sleeps up to that limit" do
    allow(Kernel).to receive(:sleep)
    policy = Struct.new(:max_retries, :answer) { def delay(**) = answer }
    [Clicksend::Connection::MAX_SLEEP + 1, 1e20].each do |answer|
      expect { connection(FakeTransport.json(503, ""), ok, policy: policy.new(1, answer)).request(:get, "/v3/x", idempotent: true) }
        .to raise_error(Clicksend::ServerError)
    end
    expect(Kernel).not_to have_received(:sleep)

    expect(connection(FakeTransport.json(503, ""), ok, policy: policy.new(1, Clicksend::Connection::MAX_SLEEP)).request(:get, "/v3/x", idempotent: true).http_status).to eq(200)
    expect(Kernel).to have_received(:sleep).with(2_147_483_647.0)
  end
end
