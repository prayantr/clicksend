# frozen_string_literal: true

RSpec.describe Clicksend::Client do
  describe "configuration" do
    it "reads credentials from the environment by default" do
      ENV["CLICKSEND_USERNAME"] = "env-user"
      ENV["CLICKSEND_API_KEY"] = "env-key"
      expect(described_class.new.username).to eq("env-user")
    end

    it "requires a username and an API key" do
      expect { described_class.new(api_key: "k") }.to raise_error(Clicksend::ConfigurationError, /username: or set CLICKSEND_USERNAME/)
      expect { described_class.new(username: "u") }.to raise_error(Clicksend::ConfigurationError, /api_key: or set CLICKSEND_API_KEY/)
      expect { described_class.new(username: " ", api_key: "k") }.to raise_error(Clicksend::ConfigurationError)
    end

    it "has explicit, enabled defaults" do
      c = client
      expect([c.base_url, c.timeout, c.open_timeout, c.max_retries]).to eq(["https://rest.clicksend.com", 30, 5, 2])
    end

    it "validates timeouts and retries" do
      expect { client(timeout: 0) }.to raise_error(Clicksend::ConfigurationError, /timeout/)
      expect { client(open_timeout: nil) }.to raise_error(Clicksend::ConfigurationError, /open_timeout/)
      expect { client(max_retries: -1) }.to raise_error(Clicksend::ConfigurationError, /max_retries/)
    end

    it "accepts only HTTPS origins (HTTP for localhost)" do
      expect(client(base_url: "https://rest.clicksend.com/").base_url).to eq("https://rest.clicksend.com")
      expect(client(base_url: "http://localhost:4567").base_url).to eq("http://localhost:4567")
      ["http://rest.clicksend.com", "https://u:p@rest.clicksend.com", "https://rest.clicksend.com/v3",
        "rest.clicksend.com", "https://rest.clicksend.com?x=1", "ht tp://bad"].each do |url|
        expect { client(base_url: url) }.to raise_error(Clicksend::ConfigurationError), url
      end
    end

    it "strips whitespace around credentials (e.g. a trailing newline from a secrets file)" do
      stub = stub_request(:get, "#{ApiHelpers::BASE}/v3/account").with(basic_auth: %w[user key]).to_return(json_response(envelope({})))
      described_class.new(username: " user\n", api_key: "key\n").request(:get, "/v3/account")
      expect(stub).to have_been_requested
    end

    it "is frozen" do
      expect(client).to be_frozen
    end
  end

  describe "#with" do
    it "returns a new client with overridden settings and keeps the rest" do
      original = client(timeout: 10)
      sub = original.with(username: "sub-user", api_key: "sub-key")
      expect([sub.username, sub.timeout]).to eq(["sub-user", 10])
      expect(original.username).to eq(ApiHelpers::USERNAME)

      stub = stub_request(:get, "#{ApiHelpers::BASE}/v3/account").with(basic_auth: %w[sub-user sub-key]).to_return(json_response(envelope({})))
      sub.request(:get, "/v3/account")
      expect(stub).to have_been_requested
    end

    it "rejects unknown settings" do
      expect { client.with(timout: 3) }.to raise_error(ArgumentError, /timout/)
    end
  end

  describe "secrecy" do
    it "never shows the API key in inspect, to_s or pp" do
      c = client
      expect(c.inspect).to eq('#<Clicksend::Client username="test-user" base_url="https://rest.clicksend.com">')
      expect(c.to_s).not_to include(ApiHelpers::API_KEY)
      expect(PP.pp(c, +"")).not_to include(ApiHelpers::API_KEY)
    end

    it "never logs credentials, bodies or query strings" do
      log = StringIO.new
      stub_api(:get, "/v3/sms/history", query: hash_including({})).to_return(json_response(envelope({}), status: 401))
      expect { client(logger: Logger.new(log)).request(:get, "/v3/sms/history", query: {q: "to:+61411111111"}) }
        .to raise_error(Clicksend::AuthenticationError)
      expect(log.string).to include("GET /v3/sms/history -> 401")
      expect(log.string).not_to include(ApiHelpers::API_KEY)
      expect(log.string).not_to include("61411111111")
    end
  end

  describe "#request (escape hatch)" do
    it "calls an arbitrary endpoint with the same auth, headers and parsing" do
      stub = stub_api(:post, "/v3/sms/templates", body: {template_name: "otp", body: "Code {code}"})
        .with(headers: {"Content-Type" => "application/json", "User-Agent" => %r{\Aclicksend-ruby/1\.0\.0\.rc1 ruby/}})
        .to_return(json_response(envelope({"template_id" => 7})))

      response = client.request(:post, "/v3/sms/templates", body: {template_name: "otp", body: "Code {code}"})

      expect(stub).to have_been_requested.once
      expect(response).to be_a(Clicksend::Response)
      expect(response.data).to eq("template_id" => 7)
    end

    it "drops nil query parameters" do
      stub = stub_api(:get, "/v3/sms/history", query: {"page" => "2"}).to_return(json_response(envelope({})))
      client.request(:get, "/v3/sms/history", query: {page: 2, q: nil})
      expect(stub).to have_been_requested
    end

    it "raises the same typed errors as wrapped endpoints" do
      stub_api(:get, "/v3/nope").to_return(json_response(envelope(nil, http_code: 404, response_code: "NOT_FOUND"), status: 404))
      expect { client.request(:get, "/v3/nope") }.to raise_error(Clicksend::NotFoundError) { |e| expect(e.response_code).to eq("NOT_FOUND") }
    end

    it "accepts string methods" do
      stub_api(:delete, "/v3/sms/templates/1").to_return(json_response(envelope(nil)))
      expect(client.request("DELETE", "/v3/sms/templates/1").http_status).to eq(200)
    end

    it "rejects unsupported methods, malformed paths and full URLs" do
      expect { client.request(:head, "/v3/x") }.to raise_error(ArgumentError, /unsupported HTTP method/)
      ["v3/account", "https://evil.example/v3/account", "//evil.example/v3", "/v3/a b", "/\\evil.example/x", "/v3/x\n", nil].each do |path|
        expect { client.request(:get, path) }.to raise_error(ArgumentError, /path must be/), path.inspect
      end
      expect { client.request(:get, "/v3/x", query: "a=1") }.to raise_error(ArgumentError, /query must be a Hash/)
    end

    describe "retry safety defaults" do
      before { allow(Kernel).to receive(:sleep) }

      it "retries GET after a 5xx" do
        stub = stub_api(:get, "/v3/account").to_return({status: 503, body: ""}, json_response(envelope({})))
        client.request(:get, "/v3/account")
        expect(stub).to have_been_requested.twice
      end

      %i[post put patch delete].each do |method|
        it "does not retry #{method.upcase} after a 5xx unless marked idempotent" do
          stub = stub_api(method, "/v3/x").to_return({status: 503, body: ""}, {status: 503, body: ""}, json_response(envelope({})))
          expect { client.request(method, "/v3/x") }.to raise_error(Clicksend::ServerError)
          expect(stub).to have_been_requested.once

          client.request(method, "/v3/x", idempotent: true)
          expect(stub).to have_been_requested.times(3)
        end
      end

      it "does not retry a POST whose response timed out" do
        stub = stub_api(:post, "/v3/sms/send").to_raise(Net::ReadTimeout)
        expect { client.request(:post, "/v3/sms/send", body: {}) }.to raise_error(Clicksend::TimeoutError)
        expect(stub).to have_been_requested.once
      end

      it "respects max_retries: 0" do
        stub = stub_api(:get, "/v3/account").to_return(status: 503, body: "")
        expect { client(max_retries: 0).request(:get, "/v3/account") }.to raise_error(Clicksend::ServerError)
        expect(stub).to have_been_requested.once
      end
    end
  end

  describe "custom transport" do
    it "sends authentication headers to the injected transport" do
      transport = FakeTransport.new(FakeTransport.json(200, envelope({})))
      client(transport: transport).request(:get, "/v3/account")
      expected = "Basic #{["#{ApiHelpers::USERNAME}:#{ApiHelpers::API_KEY}"].pack("m0")}"
      expect(transport.calls.first.headers).to include("Authorization" => expected)
    end
  end

  describe "thread safety" do
    it "serves concurrent requests from one shared client" do
      stub_api(:get, "/v3/account").to_return(json_response(envelope({"balance" => "1.00"})))
      shared = client
      results = Array.new(10) { Thread.new { shared.request(:get, "/v3/account").data["balance"] } }.map(&:value)
      expect(results).to all(eq("1.00"))
    end
  end
end
