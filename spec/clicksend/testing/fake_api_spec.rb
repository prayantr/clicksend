# frozen_string_literal: true

require "clicksend/testing"

RSpec.describe Clicksend::Testing::FakeAPI do
  let(:fake) { described_class.new }

  describe "#client" do
    it "returns a real Client wired to the fake, with production retry rules and no backoff delay" do
      client = fake.client

      expect(client).to be_a(Clicksend::Client)
      expect(client.username).to eq("test")
      expect(client.retry_policy).to have_attributes(max_retries: 2, base_delay: 0, max_delay: 0)
    end

    it "accepts any Client option, including max_retries:" do
      events = []
      instrumenter = Object.new
      instrumenter.define_singleton_method(:instrument) do |name, payload = {}, &block|
        events << name
        block&.call(payload)
      end
      fake.fail_next(:connection_refused)

      expect { fake.client(max_retries: 0).account.fetch }.to raise_error(Clicksend::ConnectionError)
      expect(fake.client(max_retries: 0).retry_policy).to have_attributes(max_retries: 0, base_delay: 0)
      fake.client(username: "someone", instrumenter: instrumenter).account.fetch
      expect(events).to eq(["request.clicksend"])
    end

    it "also works as a transport passed to Client.new" do
      client = Clicksend::Client.new(username: "u", api_key: "k", transport: fake, max_retries: 0)

      expect(client.sms.deliver(to: "+61411111111", body: "Hi")).to be_queued
      expect(fake.sent_messages.size).to eq(1)
    end
  end

  describe "GET /v3/account" do
    it "answers the configured balance and currency, with no API key" do
      fake = described_class.new(balance: "4.998000", currency: "NZD")
      account = fake.client.account.fetch

      expect(account).to have_attributes(username: "test", balance: "4.998000", currency: "NZD", user_id: 1, country: "AU",
        timezone: "Australia/Melbourne")
      expect(JSON.generate(account.raw)).not_to include("api_key")
    end

    it "does not change the balance after sends" do
      fake.client.sms.deliver(to: "+61411111111", body: "Hi")

      expect(fake.client.account.fetch.balance).to eq("10.000000")
    end
  end

  it "answers 404 to endpoints it does not emulate, and to a known path with another method" do
    expect { fake.client.request(:get, "/v3/sms/templates") }.to raise_error(Clicksend::NotFoundError) { |e|
      expect(e.response_code).to eq("NOT_FOUND")
    }
    expect { fake.client.request(:delete, "/v3/account") }.to raise_error(Clicksend::NotFoundError)
    expect(fake.requests.map(&:path)).to eq(["/v3/sms/templates", "/v3/account"])
  end

  describe "#stub" do
    it "wraps a returned Hash in a 200 envelope and passes the Request to the block" do
      seen = nil
      fake.stub(:get, "/v3/sms/templates") do |request|
        seen = request
        {"data" => {"data" => [{"template_id" => 1}]}}
      end

      response = fake.client.request(:get, "/v3/sms/templates", query: {page: 1})

      expect(response.body).to eq("http_code" => 200, "response_code" => "SUCCESS", "response_msg" => "OK", "data" => {"data" => [{"template_id" => 1}]})
      expect(seen).to eq(Clicksend::Testing::Request.new(http_method: :get, path: "/v3/sms/templates", query: {"page" => "1"}, body: nil))
    end

    it "uses a Hash's own http_code as the status" do
      fake.stub(:post, "/v3/sms/price") { {http_code: 400, response_code: "BAD_REQUEST", response_msg: "No.", data: nil} }

      expect { fake.client.request(:post, "/v3/sms/price", body: {}) }.to raise_error(Clicksend::BadRequestError) { |e|
        expect(e.response_msg).to eq("No.")
      }
    end

    it "returns a Transport::Response as is" do
      fake.stub(:put, "/v3/sms/cancel-all") { Clicksend::Transport::Response.new(status: 204, headers: {}, body: "") }

      expect(fake.client.request(:put, "/v3/sms/cancel-all").http_status).to eq(204)
    end

    it "takes precedence over the built-in endpoints and over earlier stubs" do
      fake.stub(:get, "/v3/account") { {"data" => {"balance" => "1.00"}} }
      fake.stub(:get, "/v3/account") { {"data" => {"balance" => "2.00"}} }

      expect(fake.client.account.fetch.balance).to eq("2.00")
    end

    it "may call the fake from its block" do
      fake.stub(:get, "/v3/sms/count") { {"data" => fake.sent_messages.size} }

      expect(fake.client.request(:get, "/v3/sms/count").data).to eq(0)
    end

    it "is subject to injected failures" do
      fake.stub(:post, "/v3/sms/price") { {"data" => {}} }
      fake.fail_next(status: 500, processed: true)

      expect { fake.client.request(:post, "/v3/sms/price", body: {}) }.to raise_error(Clicksend::ServerError) { |e|
        expect(e).to be_ambiguous
      }
    end

    it "validates its arguments and the block's result" do
      expect { fake.stub(:fetch, "/v3/x") { {} } }.to raise_error(ArgumentError, /method must be/)
      expect { fake.stub(:get, "v3/x") { {} } }.to raise_error(ArgumentError, /path must be/)
      expect { fake.stub(:get, "/v3/x?page=1") { {} } }.to raise_error(ArgumentError, /without a query/)
      expect { fake.stub(:get, "/v3/x") }.to raise_error(ArgumentError, /needs a block/)

      fake.stub(:get, "/v3/x") { "nope" }
      # A mistake in a stub fails the test; it is never mistaken for a ClickSend failure.
      expect { fake.client.request(:get, "/v3/x") }
        .to raise_error(Clicksend::Testing::StubError, /must return a Hash or a Clicksend::Transport::Response, got String/)
      expect(fake.requests.size).to eq(1) # not retried
    end
  end

  describe "#reset!" do
    it "forgets everything except the constructor settings" do
      fake = described_class.new(balance: "3.000000")
      client = fake.client
      client.sms.deliver(to: "+61411111111", body: "Hi")
      fake.add_receipt(message_id: "A")
      fake.add_inbound(from: "+61411111111", body: "Hi")
      fake.reject(status: "INSUFFICIENT_CREDIT")
      fake.fail_next(status: 401)
      fake.stub(:get, "/v3/account") { {"data" => {}} }

      expect(fake.reset!).to be(fake)
      expect(fake.sent_messages).to be_empty
      expect(fake.requests).to be_empty
      expect(client.account.fetch.balance).to eq("3.000000")
      expect(client.sms.receipts).to be_empty
      expect(client.sms.inbound).to be_empty
      expect { client.sms.receipt("A") }.to raise_error(Clicksend::NotFoundError)
      expect(client.sms.deliver(to: "+61411111111", body: "Hi")).to be_queued
      expect(fake.sent_messages.size).to eq(1)
    end
  end

  describe "snapshots" do
    it "returns frozen copies of sent messages and requests" do
      fake.client.sms.deliver(to: "+61411111111", body: "Hi")
      sent = fake.sent_messages
      requests = fake.requests

      expect(sent).to be_frozen
      expect(requests).to be_frozen
      expect(sent.first).to be_frozen
      expect(requests.first.query).to be_frozen
      fake.client.sms.deliver(to: "+61411111111", body: "Hi")
      expect(sent.size).to eq(1)
      expect(fake.sent_messages.size).to eq(2)
    end
  end

  describe "thread safety" do
    it "records every concurrent send exactly once, with unique message IDs" do
      client = fake.client
      threads = Array.new(10) do |t|
        Thread.new { 20.times { |i| client.sms.deliver(to: "+61411111111", body: "#{t}-#{i}") } }
      end
      threads.each(&:join)

      expect(fake.sent_messages.size).to eq(200)
      expect(fake.sent_messages.map(&:message_id).uniq.size).to eq(200)
      expect(fake.sent_messages.map(&:body).sort).to eq((0..9).flat_map { |t| (0..19).map { |i| "#{t}-#{i}" } }.sort)
      expect(fake.requests.size).to eq(200)
    end

    it "consumes each injected failure once under concurrency" do
      fake.fail_next(:connection_refused, times: 50)
      client = fake.client(max_retries: 0)
      fetch = lambda do
        client.account.fetch
        :ok
      rescue Clicksend::ConnectionError
        :refused
      end
      outcomes = Array.new(10) { Thread.new { Array.new(10) { fetch.call } } }.flat_map(&:value)

      expect(outcomes.tally).to eq(ok: 50, refused: 50)
    end
  end

  describe "credentials" do
    it "never retains the Authorization header or the API key" do
      client = Clicksend::Client.new(username: "user-7f3a", api_key: "SECRET-KEY-9c1e", transport: fake, max_retries: 1)
      fake.fail_next(:connection_refused)
      client.sms.deliver(to: "+61411111111", body: "Hi")
      client.account.fetch
      client.sms.receipts

      authorization = "Basic #{["user-7f3a:SECRET-KEY-9c1e"].pack("m0")}"
      dumped = [fake.requests.inspect, fake.requests.map(&:to_h).to_s, fake.inspect, fake.sent_messages.inspect].join
      expect(dumped).not_to include("SECRET-KEY-9c1e")
      expect(dumped).not_to include(authorization)
      expect(dumped).not_to include("Authorization")
      expect(fake.instance_variables.map { |name| fake.instance_variable_get(name) }.inspect).not_to include("SECRET-KEY-9c1e")
      expect(Clicksend::Testing::Request.members).to eq(%i[http_method path query body])
    end

    it "keeps inspect short" do
      fake.client.sms.deliver(to: "+61411111111", body: "Hi")

      expect(fake.inspect).to eq("#<Clicksend::Testing::FakeAPI sent_messages=1 requests=1>")
    end
  end

  describe "the transport interface used directly" do
    it "splits a query string out of the path and keeps a non-JSON body as a String" do
      fake.call(:GET, "/v3/sms/history?q=to%3A%2B61411111111", query: {"limit" => 20}, body: nil, headers: {})
      response = fake.call(:post, "/v3/sms/send", query: nil, body: "not json", headers: {})

      expect(fake.requests.first).to have_attributes(http_method: :get, path: "/v3/sms/history",
        query: {"q" => "to:+61411111111", "limit" => "20"})
      expect(fake.requests.last.body).to eq("not json")
      expect(response.status).to eq(400)
      expect(response.headers).to eq("content-type" => "application/json")
    end
  end

  describe "constructor" do
    it "validates its settings" do
      expect { described_class.new(balance: 10) }.to raise_error(ArgumentError, /balance must be a decimal String/)
      expect { described_class.new(message_price: "free") }.to raise_error(ArgumentError, /message_price/)
      expect { described_class.new(currency: "") }.to raise_error(ArgumentError, /currency/)
      expect { described_class.new(clock: Time.now) }.to raise_error(ArgumentError, /clock must respond to #call/)
    end
  end

  it "works as a development dry-run transport: nothing is sent over the network" do
    client = Clicksend::Client.new(username: "dev", api_key: "dev", transport: described_class.new)

    expect(client.sms.deliver(to: "+61411111111", body: "Hi")).to be_queued
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "does not serve history, so tests must state what history shows" do
    expect { fake.client.sms.history }.to raise_error(Clicksend::NotFoundError)
  end
end
