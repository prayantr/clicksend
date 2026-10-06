# frozen_string_literal: true

# What changes when a client uses adapter: [:net_http_persistent, {pool_size: N}]
# instead of the default Net::HTTP adapter, measured on real sockets
# (plain HTTP and local TLS). The founding rule must hold unchanged: a request
# that may have been processed is never sent twice automatically and surfaces
# as ambiguous.
PERSISTENT = [:net_http_persistent, {pool_size: 4}].freeze

RSpec.describe "Persistent connections (faraday-net_http_persistent)" do
  after { @server&.stop }

  def serve(**options)
    @server = KeepAliveServer.new(**options)
  end

  def tls(**options)
    TestCertificates.server_context(**options)
  end

  def local_client(adapter: PERSISTENT, scheme: nil, max_retries: 2, **options)
    scheme ||= @server_tls ? "https" : "http"
    Clicksend::Client.new(username: "u", api_key: "k", base_url: "#{scheme}://127.0.0.1:#{@server.port}", adapter: adapter,
      timeout: 0.5, open_timeout: 0.5, retry_policy: Clicksend::RetryPolicy.new(max_retries: max_retries, base_delay: 0, max_delay: 0), **options)
  end

  def deliver(client)
    client.sms.deliver(to: "+61411111111", body: "hi")
  end

  def requests_to(path)
    @server.requests.count { |r| r.path == path }
  end

  # The second request on a connection misbehaves; the first warms it up.
  def misbehave_on_reuse(action)
    ->(request) { (request.index == 1) ? action : :ok }
  end

  [false, true].each do |use_tls|
    context(use_tls ? "over TLS" : "over plain HTTP") do
      before { @server_tls = use_tls }

      def serve(**options)
        super(tls: (tls if @server_tls), **options)
      end

      it "default adapter: opens a new connection for every request (today's behaviour)" do
        serve
        client = local_client(adapter: nil)
        5.times { client.account.fetch }
        expect(@server.accepts).to eq(5)
      end

      it "reuses one connection for sequential requests" do
        serve
        client = local_client
        5.times { client.account.fetch }
        deliver(client)
        expect(@server.accepts).to eq(1)
        expect(@server.requests.map(&:index)).to eq([0, 1, 2, 3, 4, 5])
      end

      describe "no hidden retries when a reused connection fails after the request was written" do
        {close: "closed without a response", reset: "reset"}.each do |action, description|
          it "sends a POST (sms.deliver) exactly once when the connection is #{description}, and reports it as ambiguous" do
            serve(behaviour: misbehave_on_reuse(action))
            client = local_client
            client.account.fetch
            expect { deliver(client) }.to raise_error(Clicksend::ConnectionError) { |e|
              expect(e).to be_ambiguous
              expect(e.request_may_have_been_sent?).to be(true)
              expect(e.request.attempts).to eq(1)
            }
            expect(requests_to("/v3/sms/send")).to eq(1)
          end

          # Net::HTTP itself retries GET/PUT/DELETE once unless max_retries is
          # 0; PUT is how ClickSend buys credit and marks everything read.
          it "sends a non-idempotent PUT exactly once when the connection is #{description}" do
            serve(behaviour: misbehave_on_reuse(action))
            client = local_client
            client.account.fetch
            expect { client.request(:put, "/v3/sms/receipts-read") }.to raise_error(Clicksend::ConnectionError) { |e|
              expect(e).to be_ambiguous
            }
            expect(requests_to("/v3/sms/receipts-read")).to eq(1)
          end

          it "retries an idempotent GET only through the gem's own, visible retry when the connection is #{description}" do
            serve(behaviour: misbehave_on_reuse(action))
            client = local_client
            client.account.fetch
            response = client.request(:get, "/v3/echo")
            expect(response.request.attempts).to eq(2)
            expect(requests_to("/v3/echo")).to eq(2)
          end
        end
      end

      it "a read timeout on a reused connection: the send is ambiguous, sent once, and the late response is never read as the next one's" do
        serve(behaviour: misbehave_on_reuse(:hang), hang: 0.8)
        client = local_client(timeout: 0.3)
        client.account.fetch
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { deliver(client) }.to raise_error(Clicksend::TimeoutError) { |e| expect(e).to be_ambiguous }
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.7
        sleep 0.6 # the late response to the send is now on the old socket
        echo = client.request(:get, "/v3/echo").data
        expect(echo).to include("path" => "/v3/echo", "index" => 0) # a fresh connection, its own response
        expect(requests_to("/v3/sms/send")).to eq(1)
      end

      it "a keep-alive connection the server closed while idle is replaced before the request is written (no retry involved)" do
        serve(idle_timeout: 0.2)
        client = local_client
        client.account.fetch
        sleep 0.5
        expect(deliver(client).status).to eq("SUCCESS")
        expect(requests_to("/v3/sms/send")).to eq(1)
        expect(@server.accepts).to eq(2)
      end

      it "copes with a server that closes the connection after each response (Connection: close)" do
        serve(behaviour: ->(_) { :ok_close })
        client = local_client
        3.times { deliver(client) }
        expect(requests_to("/v3/sms/send")).to eq(3)
        expect(@server.accepts).to eq(3)
      end

      it "shares one client between threads: each thread gets its own connection and its own responses" do
        serve
        client = local_client(adapter: [:net_http_persistent, {pool_size: 8}])
        mismatches = Queue.new
        Array.new(8) { |t|
          Thread.new do
            20.times do |i|
              path = "/v3/echo/#{t}-#{i}"
              mismatches << path unless client.request(:get, path).data["path"] == path
            end
          end
        }.each(&:join)
        expect(mismatches.size).to eq(0)
        expect(@server.requests.size).to eq(160)
        expect(@server.accepts).to be <= 8
      end

      it "fork: the child opens its own connection and the parent's keeps working" do
        serve
        client = local_client
        parent_connection = client.request(:get, "/v3/echo").data["connection"]
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          writer.write(client.request(:get, "/v3/echo").data["connection"].to_s)
          writer.close
          exit!(0)
        end
        writer.close
        child_connection = Integer(reader.read)
        Process.wait(pid)
        expect($?.exitstatus).to eq(0)
        expect(child_connection).not_to eq(parent_connection)
        expect { 3.times { client.request(:get, "/v3/echo") } }.not_to raise_error
        expect(requests_to("/v3/echo")).to eq(5)
      end
    end
  end

  describe "TLS verification is unchanged" do
    [nil, PERSISTENT].each do |adapter|
      context "with #{adapter ? "net_http_persistent" : "the default adapter"}" do
        it "accepts a certificate for the host from a trusted CA" do
          serve(tls: tls)
          expect(local_client(adapter: adapter, scheme: "https").account.fetch).to be_a(Clicksend::Account)
        end

        it "rejects a self-signed certificate before sending anything" do
          serve(tls: tls(signed_by_ca: false))
          expect { deliver(local_client(adapter: adapter, scheme: "https", max_retries: 0)) }.to raise_error(Clicksend::ConnectionError, /certificate verify failed/)
          expect(@server.requests).to be_empty
        end

        it "rejects a trusted certificate for another host name before sending anything" do
          serve(tls: tls(names: "DNS:wrong.example"))
          expect { deliver(local_client(adapter: adapter, scheme: "https", max_retries: 0)) }.to raise_error(Clicksend::ConnectionError, /certificate verify failed|hostname/)
          expect(@server.requests).to be_empty
        end
      end
    end
  end

  # Failures that happen before anything is written. The default adapter
  # reports them as not sent (so a send is retried); with net_http_persistent
  # they reach the gem in a shape it does not recognise, so it assumes the
  # request may have been sent: safe (never a duplicate) but a send that
  # never left is reported as ambiguous and not retried.
  describe "failures before the request was written (classification)" do
    it "connection refused: default adapter says not sent; net_http_persistent is classified as possibly sent" do
      port = TCPServer.open("127.0.0.1", 0) { |probe| probe.addr[1] }
      clients = [nil, PERSISTENT].map do |adapter|
        Clicksend::Client.new(username: "u", api_key: "k", base_url: "http://127.0.0.1:#{port}", adapter: adapter, max_retries: 0)
      end
      sent = clients.map do |client|
        deliver(client)
      rescue Clicksend::ConnectionError => e
        [e.request_may_have_been_sent?, e.ambiguous?]
      end
      expect(sent).to eq([[false, false], [true, true]])
    end

    it "TLS handshake timeout: default adapter says not sent; net_http_persistent is classified as possibly sent" do
      serve(tls: tls, rtt: 2, handshake_rtts: 1) # the handshake waits 2s before the server answers
      outcomes = [nil, PERSISTENT].map do |adapter|
        deliver(local_client(adapter: adapter, scheme: "https", max_retries: 0, open_timeout: 0.3))
      rescue Clicksend::TimeoutError => e
        [e.request_may_have_been_sent?, e.ambiguous?]
      end
      expect(outcomes).to eq([[false, false], [true, true]])
      expect(@server.requests).to be_empty
    end

    it "pool exhausted: a thread waits 0.5s for a connection, then gets an ambiguous TimeoutError for a send that never left" do
      serve(rtt: 0.8, handshake_rtts: 0)
      client = local_client(adapter: [:net_http_persistent, {pool_size: 1}], timeout: 2)
      results = Array.new(2) {
        Thread.new do
          deliver(client).status
        rescue Clicksend::Error => e
          e
        end
      }.map(&:value)
      error = results.find { |r| r.is_a?(Clicksend::Error) }
      expect(results.count("SUCCESS")).to eq(1)
      expect(error).to be_a(Clicksend::TimeoutError)
      expect(error).to be_ambiguous
      expect(error.message).to include("Waited 0.5 sec, 0/1 available")
      expect(error.cause.wrapped_exception).to be_a(ConnectionPool::TimeoutError)
      expect(requests_to("/v3/sms/send")).to eq(1)
    end
  end

  # The layer below the adapter: Net::HTTP::Persistent defaults to
  # max_retries = 1, and Net::HTTP then repeats GET/PUT/DELETE on a reset.
  # faraday-net_http_persistent (every 2.x release) sets max_retries = 0 on
  # each request; this pins why that matters.
  describe "Net::HTTP::Persistent without Faraday (control)" do
    def raw_request(http, method, path)
      uri = URI("http://127.0.0.1:#{@server.port}#{path}")
      request = Net::HTTPGenericRequest.new(method, method != "GET", true, uri.request_uri)
      request.body = "{}" if method != "GET"
      http.request(uri, request)
    end

    it "retries a PUT by itself when left at its default max_retries (1), but never a POST" do
      serve(behaviour: misbehave_on_reuse(:reset))
      http = Net::HTTP::Persistent.new(name: "control")
      expect(http.max_retries).to eq(1)
      raw_request(http, "GET", "/v3/account")
      expect(raw_request(http, "PUT", "/v3/sms/receipts-read").code).to eq("200") # silently sent twice
      expect(requests_to("/v3/sms/receipts-read")).to eq(2)

      @server.stop
      serve(behaviour: misbehave_on_reuse(:reset))
      http = Net::HTTP::Persistent.new(name: "control")
      raw_request(http, "GET", "/v3/account")
      expect { raw_request(http, "POST", "/v3/sms/send") }.to raise_error(Errno::ECONNRESET)
      expect(requests_to("/v3/sms/send")).to eq(1)
    ensure
      http&.shutdown
    end
  end
end
