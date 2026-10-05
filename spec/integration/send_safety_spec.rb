# frozen_string_literal: true

# End-to-end checks of the most important invariant in this gem:
#
#   An SMS send is never automatically retried when the original request may
#   have reached ClickSend.
#
# These run the real HTTP stack (Net::HTTP, the Faraday adapter, the
# transport, Connection and RetryPolicy) against a local server that counts
# how many times the request actually arrived. They also prove there is no
# hidden retry underneath the gem (Net::HTTP retries GET/PUT/DELETE by itself
# unless max_retries is 0).
RSpec.describe "SMS send safety (real HTTP stack)" do
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
    @server&.stop
  end

  before { allow(Kernel).to receive(:sleep) }

  def serve(*script)
    @server = LocalServer.new(*script)
  end

  def local_client(scheme: "http", **options)
    Clicksend::Client.new(username: "u", api_key: "k", base_url: "#{scheme}://127.0.0.1:#{@server.port}", max_retries: 2, timeout: 0.5, open_timeout: 0.5, **options)
  end

  def deliver(client)
    client.sms.deliver(to: "+61411111111", body: "hi")
  end

  {
    close: [Clicksend::ConnectionError, "the connection closes after the request was received"],
    reset: [Clicksend::ConnectionError, "the connection is reset after the request was received"],
    hang: [Clicksend::TimeoutError, "no response arrives before the read timeout"],
    unavailable: [Clicksend::ServerError, "ClickSend answers 503"]
  }.each do |behaviour, (error_class, description)|
    it "sends exactly once when #{description}" do
      serve(behaviour, :ok)
      expect { deliver(local_client) }.to raise_error(error_class) { |error|
        expect(error.request_may_have_been_sent?).to be(true) if error.is_a?(Clicksend::ConnectionError)
      }
      expect(@server.requests).to eq(["POST /v3/sms/send HTTP/1.1"])
    end

    it "sends a non-idempotent escape-hatch PUT exactly once when #{description}" do
      serve(behaviour, :ok)
      expect { local_client.request(:put, "/v3/recharge/purchase/1") }.to raise_error(error_class)
      expect(@server.requests.size).to eq(1)
    end
  end

  it "sends exactly once when the TLS handshake fails (TLS errors count as possibly sent)" do
    serve(:not_tls, :ok)
    expect { deliver(local_client(scheme: "https")) }
      .to raise_error(Clicksend::ConnectionError) { |error| expect(error.request_may_have_been_sent?).to be(true) }
    expect(@server.connections).to eq(1)
  end

  it "retries a send that was rate limited (429: ClickSend did not process it)" do
    serve(:rate_limited, :ok)
    expect { deliver(local_client) }.to raise_error(Clicksend::MalformedResponseError) # the canned 200 isn't a send result
    expect(@server.requests.size).to eq(2)
  end

  it "retries a send whose connection was refused (it never left the machine)" do
    port = TCPServer.open("127.0.0.1", 0) { |probe| probe.addr[1] } # now closed: nothing listens there
    log = StringIO.new
    client = Clicksend::Client.new(username: "u", api_key: "k", base_url: "http://127.0.0.1:#{port}", max_retries: 2, logger: Logger.new(log))
    expect { deliver(client) }.to raise_error(Clicksend::ConnectionError) { |e| expect(e.request_may_have_been_sent?).to be(false) }
    expect(log.string.scan("retrying").size).to eq(2)
  end

  it "does retry an idempotent GET through the same path (so the policy is active, not just absent)" do
    serve(:unavailable, :unavailable, :ok)
    expect(local_client.request(:get, "/v3/account").http_status).to eq(200)
    expect(@server.requests.size).to eq(3)
  end

  it "applies the client's read timeout to escape-hatch requests" do
    serve(:hang)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { local_client(max_retries: 0, timeout: 0.3).request(:get, "/v3/account") }.to raise_error(Clicksend::TimeoutError)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
  end
end
