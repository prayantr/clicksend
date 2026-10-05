# frozen_string_literal: true

# client.request is the low-level escape hatch for endpoints this gem does not
# wrap. These specs pin that it is not a side door: it shares every
# behaviour of the wrapped methods, and it can never send credentials to a
# host other than the configured ClickSend origin.
RSpec.describe "Client#request escape hatch" do
  let(:account_payload) { fixture("account") }

  describe "parity with wrapped methods" do
    def error_from
      yield
      raise "expected an error"
    rescue Clicksend::Error => e
      e
    end

    it "sends the same authentication and default headers" do
      transport = FakeTransport.new(FakeTransport.json(200, account_payload), FakeTransport.json(200, account_payload))
      c = client(transport: transport)
      c.account.fetch
      c.request(:get, "/v3/account")

      wrapped, raw = transport.calls
      expect(raw.headers).to eq(wrapped.headers)
      expect(raw.headers.keys).to contain_exactly("Authorization", "Accept", "User-Agent")
    end

    it "uses the same transport, and therefore the same timeouts" do
      c = client(timeout: 7, open_timeout: 2)
      transport = c.instance_variable_get(:@connection).instance_variable_get(:@transport)
      faraday = transport.instance_variable_get(:@connection)
      expect([faraday.options.timeout, faraday.options.open_timeout]).to eq([7, 2])
      # (spec/integration/send_safety_spec.rb shows the read timeout firing for client.request)
    end

    it "parses responses identically" do
      stub_api(:get, "/v3/account").to_return(json_response(account_payload))
      expect(client.request(:get, "/v3/account").data).to eq(client.account.fetch.raw)
      expect(client.request(:get, "/v3/account").body).to be_frozen
    end

    [400, 401, 403, 404, 429, 500, 503].each do |status|
      it "maps HTTP #{status} to the same error as a wrapped method" do
        body = envelope(nil, http_code: status, response_code: "CODE_#{status}", response_msg: "msg")
        stub_api(:get, "/v3/account").to_return(json_response(body, status: status))
        allow(Kernel).to receive(:sleep)

        wrapped = error_from { client(max_retries: 0).account.fetch }
        raw = error_from { client(max_retries: 0).request(:get, "/v3/account") }

        expect(raw.class).to eq(wrapped.class)
        expect([raw.http_status, raw.response_code, raw.response_msg]).to eq([status, "CODE_#{status}", "msg"])
      end
    end

    it "applies the same retry policy (GET retried, POST not)" do
      allow(Kernel).to receive(:sleep)
      get = stub_api(:get, "/v3/account").to_return({status: 503, body: ""}, json_response(account_payload))
      client.request(:get, "/v3/account")
      expect(get).to have_been_requested.twice

      post = stub_api(:post, "/v3/sms/send").to_return(status: 503, body: "")
      expect { client.request(:post, "/v3/sms/send", body: {messages: []}) }.to raise_error(Clicksend::ServerError)
      expect(post).to have_been_requested.once
    end
  end

  describe "destination safety" do
    let(:origin) { "rest.clicksend.com" }

    before do
      # Any request to any host is answered, so nothing hides behind a
      # WebMock "unregistered request" error; we then inspect where requests went.
      stub_request(:any, /.*/).to_return(json_response(envelope({})))
    end

    def hosts_requested
      WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { |signature| signature.uri.host }.uniq
    end

    {
      "absolute https URL" => "https://evil.example/v3/account",
      "absolute http URL" => "http://evil.example/v3/account",
      "upper-case scheme" => "HTTPS://EVIL.EXAMPLE/v3/account",
      "protocol-relative URL" => "//evil.example/v3/account",
      "triple slash" => "///evil.example/v3/account",
      "backslash host" => "/\\evil.example/v3/account",
      "double backslash" => "\\\\evil.example/v3/account",
      "relative host-looking path" => "evil.example/v3/account",
      "mailto" => "mailto:x@evil.example",
      "leading space" => " /v3/account",
      "CRLF header injection" => "/v3/account\r\nHost: evil.example",
      "embedded newline" => "/v3/account\nX: y",
      "non-string" => URI("https://evil.example/v3/account")
    }.each do |description, path|
      it "rejects a #{description}" do
        expect { client.request(:get, path) }.to raise_error(ArgumentError, /path must be an absolute path/)
        expect(hosts_requested).to eq([])
      end
    end

    {
      "userinfo-looking segment" => "/@evil.example/v3/account",
      "colon userinfo-looking segment" => "/:@evil.example/v3",
      "dotted segment" => "/.evil.example",
      "encoded slashes" => "/%2F%2Fevil.example/v3",
      "path traversal" => "/v3/../../evil.example/account",
      "URL in the query string" => "/v3/account?next=https://evil.example/",
      "URL in a fragment" => '/v3/account#@evil.example'
    }.each do |description, path|
      it "keeps a #{description} on the ClickSend host" do
        client.request(:get, path)
        expect(hosts_requested).to eq([origin])
      end
    end

    it "lets path traversal reach only other paths on the same host" do
      client.request(:get, "/v3/../v2/whatever")
      expect(a_request(:get, "https://#{origin}/v2/whatever")).to have_been_made
    end

    it "does not follow redirects, so credentials can't be forwarded to another host" do
      stub_request(:get, "https://#{origin}/v3/moved").to_return(status: 302, headers: {"Location" => "https://evil.example/steal"})
      expect { client.request(:get, "/v3/moved") }.to raise_error(Clicksend::APIError) { |e| expect(e.http_status).to eq(302) }
      expect(hosts_requested).to eq([origin])
    end

    it "sends credentials only to the configured origin" do
      client.request(:get, "/v3/account")
      expect(a_request(:any, /evil/)).not_to have_been_made
      expect(a_request(:get, "https://#{origin}/v3/account").with(basic_auth: [ApiHelpers::USERNAME, ApiHelpers::API_KEY])).to have_been_made
    end

    it "offers no per-request way to change the host or headers" do
      expect(Clicksend::Client.instance_method(:request).parameters.map(&:last)).to eq(%i[method path query body idempotent])
    end
  end
end
