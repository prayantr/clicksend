# frozen_string_literal: true

require "tmpdir"
require "faraday/net_http_persistent"

# Send safety with Client.new(adapter: [:net_http_persistent, ...]) on real
# sockets (trimmed from the 1.2 persistent-connection spike; see
# research/1.2-observability-and-http.md, B2). WebMock is disabled, so the
# real Net::HTTP, net-http-persistent and connection_pool run.
#
# * A reused connection that fails after the request was written never hides
#   a retry: POST and PUT reach the server once and are ambiguous. This rests
#   on faraday-net_http_persistent setting Net::HTTP's max_retries to 0; the
#   control spec shows what happens without it.
# * Timeouts are honoured.
# * Failures that happen before anything is written (refused, connect or TLS
#   handshake timeout, waiting for a pooled connection) are not sent, so they
#   are retried and the request reaches the server once.
RSpec.describe "Persistent connections (adapter: :net_http_persistent)" do
  around do |example|
    WebMock.disable!
    saved = ENV.fetch("SSL_CERT_FILE", nil)
    Dir.mktmpdir("clicksend-certs") do |dir|
      ENV["SSL_CERT_FILE"] = TestCertificates.ca_file(dir)
      example.run
    end
  ensure
    saved ? ENV["SSL_CERT_FILE"] = saved : ENV.delete("SSL_CERT_FILE")
    WebMock.enable!
    @servers&.each(&:stop)
  end

  def serve(**options)
    (@servers ||= []) << KeepAliveServer.new(**options)
    @server = @servers.last
  end

  def persistent_client(scheme: "http", pool_size: 2, max_retries: 2, retry_policy: nil, **options)
    retry_policy ||= Clicksend::RetryPolicy.new(max_retries: max_retries, base_delay: 0, max_delay: 0)
    Clicksend::Client.new(username: "u", api_key: "k", base_url: "#{scheme}://127.0.0.1:#{@server.port}",
      adapter: [:net_http_persistent, {pool_size: pool_size}], timeout: 0.5, open_timeout: 0.3, retry_policy: retry_policy, **options)
  end

  def deliver(client) = client.sms.deliver(to: "+61411111111", body: "hi")

  def requests_to(path, server = @server) = server.requests.count { |r| r.path == path }

  # The second request on a connection misbehaves; the first warms it up.
  def on_reuse(action) = ->(request) { (request.index == 1) ? action : :ok }

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  it "reuses one connection for sequential requests (so the specs below exercise reuse)" do
    serve
    client = persistent_client
    3.times { client.account.fetch }
    deliver(client)
    expect(@server.accepts).to eq(1)
    expect(@server.requests.map(&:index)).to eq([0, 1, 2, 3])
  end

  describe "a reused connection that fails after the request was written" do
    {close: "closed without a response", reset: "reset"}.each do |action, description|
      it "sends a POST (sms.deliver) exactly once when the connection is #{description}, and reports it as ambiguous" do
        serve(behaviour: on_reuse(action))
        client = persistent_client
        client.account.fetch
        expect { deliver(client) }.to raise_error(Clicksend::ConnectionError) { |e|
          expect(e).to be_ambiguous
          expect(e.request_may_have_been_sent?).to be(true)
          expect(e.request.attempts).to eq(1)
        }
        expect(requests_to("/v3/sms/send")).to eq(1)
      end

      # Net::HTTP itself repeats GET/PUT/DELETE unless max_retries is 0, and
      # PUT is how ClickSend marks everything read or buys credit.
      it "sends a non-idempotent PUT exactly once when the connection is #{description}" do
        serve(behaviour: on_reuse(action))
        client = persistent_client
        client.account.fetch
        expect { client.request(:put, "/v3/sms/receipts-read") }.to raise_error(Clicksend::ConnectionError) { |e| expect(e).to be_ambiguous }
        expect(requests_to("/v3/sms/receipts-read")).to eq(1)
      end

      it "retries an idempotent GET only through the gem's own, visible retry when the connection is #{description}" do
        serve(behaviour: on_reuse(action))
        client = persistent_client
        client.account.fetch
        expect(client.request(:get, "/v3/echo").request.attempts).to eq(2)
        expect(requests_to("/v3/echo")).to eq(2)
      end
    end

    it "sends a POST exactly once over TLS too" do
      serve(tls: TestCertificates.server_context, behaviour: on_reuse(:reset))
      client = persistent_client(scheme: "https")
      client.account.fetch
      expect { deliver(client) }.to raise_error(Clicksend::ConnectionError) { |e| expect(e).to be_ambiguous }
      expect(requests_to("/v3/sms/send")).to eq(1)
    end
  end

  it "honours the read timeout on a reused connection, and never reads the late response as the next one's" do
    serve(behaviour: on_reuse(0.8))
    client = persistent_client(timeout: 0.3)
    client.account.fetch
    took = elapsed do
      expect { deliver(client) }.to raise_error(Clicksend::TimeoutError) { |e|
        expect(e).to be_ambiguous
        expect(e.request.attempts).to eq(1)
      }
    end
    expect(took).to be < 0.7
    sleep 0.6 # the late response to the send is now on the old socket
    expect(client.request(:get, "/v3/echo").data).to include("path" => "/v3/echo", "index" => 0) # a fresh connection
    expect(requests_to("/v3/sms/send")).to eq(1)
  end

  it "replaces a connection the server closed while idle before writing the request (no retry involved)" do
    serve(idle_timeout: 0.1)
    client = persistent_client
    client.account.fetch
    sleep 0.4
    expect(client.request(:post, "/v3/sms/send").request.attempts).to eq(1)
    expect(requests_to("/v3/sms/send")).to eq(1)
    expect(@server.accepts).to eq(2)
  end

  describe "failures before anything was written: not sent, so retried" do
    # Runs +restart+ before the first retry, then retries at once.
    def restarting_policy(&restart)
      Object.new.tap do |policy|
        policy.define_singleton_method(:max_retries) { 2 }
        policy.define_singleton_method(:delay) do |attempt:, **|
          restart.call if attempt.zero?
          0
        end
      end
    end

    it "a refused connection is not sent and not ambiguous" do
      port = TCPServer.open("127.0.0.1", 0) { |probe| probe.addr[1] } # now closed: nothing listens there
      client = Clicksend::Client.new(username: "u", api_key: "k", base_url: "http://127.0.0.1:#{port}",
        adapter: [:net_http_persistent, {pool_size: 1}], max_retries: 0)
      expect { deliver(client) }.to raise_error(Clicksend::ConnectionError) { |e|
        expect(e).to be_an_instance_of(Clicksend::ConnectionError)
        expect(e.request_may_have_been_sent?).to be(false)
        expect(e).not_to be_ambiguous
        expect(e).to be_retryable
        expect(e.cause.wrapped_exception).to be_a(Net::HTTP::Persistent::Error)
      }
    end

    it "a reused connection whose reconnect is refused: the send is retried and reaches the server once" do
      first = serve
      client = persistent_client(retry_policy: restarting_policy { serve(port: first.port) })
      client.account.fetch
      first.stop # the pooled connection is closed and the port refuses
      sleep 0.2 # let the FIN arrive: a request written before it would meet the keep-alive race instead
      response = client.request(:post, "/v3/sms/send")
      expect(response.request.attempts).to eq(2)
      expect(requests_to("/v3/sms/send", first)).to eq(0)
      expect(requests_to("/v3/sms/send")).to eq(1)
    end

    it "a TLS handshake that times out (open timeout) is retried, and the send reaches the server once" do
      serve(tls: TestCertificates.server_context, stall: ->(connection) { connection.zero? ? 1.0 : 0 })
      response = nil
      took = elapsed { response = persistent_client(scheme: "https").request(:post, "/v3/sms/send") }
      expect(response.request.attempts).to eq(2)
      expect(took).to be < 0.9 # the 0.3s open timeout, not the server's 1s stall
      expect(requests_to("/v3/sms/send")).to eq(1)
      expect(@server.accepts).to eq(2)
    end

    it "waiting too long for a pooled connection is retried, and the send reaches the server once" do
      received = Queue.new
      serve(behaviour: lambda { |request|
        received << request
        (request.index == 0) ? 0.9 : :ok # the first send holds the only pooled connection for 0.9s
      })
      client = persistent_client(pool_size: 1, timeout: 2)
      holder = Thread.new { client.request(:post, "/v3/sms/send", body: {n: 1}) }
      received.pop
      waiter = client.request(:post, "/v3/sms/send", body: {n: 2}) # the pool's checkout gives up after 0.5s
      expect(waiter.request.attempts).to eq(2)
      expect(holder.value.request.attempts).to eq(1)
      expect(requests_to("/v3/sms/send")).to eq(2)
    end

    it "a TLS handshake failure is still treated as possibly sent (TLS errors can follow the write), but nothing arrived" do
      serve(tls: TestCertificates.server_context(signed_by_ca: false))
      expect { deliver(persistent_client(scheme: "https")) }.to raise_error(Clicksend::ConnectionError, /certificate verify failed/) { |e|
        expect(e.cause).to be_a(Faraday::SSLError)
        expect(e).to be_ambiguous
        expect(e.request.attempts).to eq(1)
      }
      expect(@server.requests).to be_empty
    end
  end

  # The layer below the adapter: Net::HTTP::Persistent defaults to
  # max_retries = 1, and Net::HTTP then repeats a PUT (never a POST) on a
  # reset. faraday-net_http_persistent sets max_retries = 0 on every request;
  # this pins why that line matters.
  describe "Net::HTTP::Persistent without Faraday (control)" do
    def raw_request(http, method, path)
      uri = URI("http://127.0.0.1:#{@server.port}#{path}")
      request = Net::HTTPGenericRequest.new(method, method != "GET", true, uri.request_uri)
      request.body = "{}" if method != "GET"
      http.request(uri, request)
    end

    it "retries a PUT by itself when left at its default max_retries" do
      serve(behaviour: on_reuse(:reset))
      http = Net::HTTP::Persistent.new(name: "control")
      expect(http.max_retries).to eq(1)
      raw_request(http, "GET", "/v3/account")
      expect(raw_request(http, "PUT", "/v3/sms/receipts-read").code).to eq("200") # silently sent twice
      expect(requests_to("/v3/sms/receipts-read")).to eq(2)
    ensure
      http&.shutdown
    end
  end
end
