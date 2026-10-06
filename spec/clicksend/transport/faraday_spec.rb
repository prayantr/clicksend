# frozen_string_literal: true

require "net/http/persistent"

RSpec.describe Clicksend::Transport::Faraday do
  subject(:transport) do
    described_class.new(base_url: "https://rest.clicksend.com", timeout: 12, open_timeout: 3)
  end

  let(:url) { "https://rest.clicksend.com/v3/sms/send" }

  it "sends the method, path, query, body and the given headers" do
    stub = stub_request(:post, url)
      .with(query: {"page" => "2"}, body: '{"a":1}', headers: {"Content-Type" => "application/json", "X-Test" => "yes"})
      .to_return(status: 200, body: "{}", headers: {"X-RateLimit-Limit" => "20"})

    response = transport.call(:post, "/v3/sms/send", query: {page: 2}, body: '{"a":1}',
      headers: {"Content-Type" => "application/json", "X-Test" => "yes"})

    expect(stub).to have_been_requested.once
    expect(response).to eq(Clicksend::Transport::Response.new(status: 200, headers: {"x-ratelimit-limit" => "20"}, body: "{}"))
  end

  it "configures the timeouts on every request" do
    connection = transport.instance_variable_get(:@connection)
    expect(connection.options.timeout).to eq(12)
    expect(connection.options.open_timeout).to eq(3)
  end

  it "returns frozen, lower-cased headers" do
    stub_request(:get, "https://rest.clicksend.com/v3/account").to_return(status: 200, body: "{}", headers: {"Retry-After" => "1"})
    headers = transport.call(:get, "/v3/account").headers
    expect(headers).to eq("retry-after" => "1")
    expect(headers).to be_frozen
  end

  it "returns non-2xx responses instead of raising (status mapping happens in Connection)" do
    stub_request(:get, "https://rest.clicksend.com/v3/account").to_return(status: 401, body: "denied")
    expect(transport.call(:get, "/v3/account").status).to eq(401)
  end

  describe "failures before a response" do
    def failure_for(exception)
      stub_request(:post, url).to_raise(exception)
      transport.call(:post, "/v3/sms/send", body: "{}")
    rescue Clicksend::ConnectionError => e
      e
    end

    it "maps a read timeout to TimeoutError that may have been sent" do
      error = failure_for(Net::ReadTimeout)
      expect(error).to be_a(Clicksend::TimeoutError)
      expect(error.request_may_have_been_sent?).to be(true)
    end

    it "maps a connect timeout to TimeoutError that was not sent" do
      error = failure_for(Net::OpenTimeout)
      expect(error).to be_a(Clicksend::TimeoutError)
      expect(error.request_may_have_been_sent?).to be(false)
    end

    it "maps a refused connection to ConnectionError that was not sent" do
      error = failure_for(Errno::ECONNREFUSED)
      expect(error).to be_an_instance_of(Clicksend::ConnectionError)
      expect(error.request_may_have_been_sent?).to be(false)
    end

    it "maps a DNS failure to ConnectionError that was not sent" do
      expect(failure_for(SocketError.new("getaddrinfo")).request_may_have_been_sent?).to be(false)
    end

    it "treats TLS errors as possibly sent (they can happen after the request was written)" do
      error = failure_for(OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading"))
      expect(error.request_may_have_been_sent?).to be(true)
    end

    it "treats an unreachable host as possibly sent" do
      expect(failure_for(Errno::EHOSTUNREACH).request_may_have_been_sent?).to be(true)
    end

    it "treats a reset connection as possibly sent" do
      error = failure_for(Errno::ECONNRESET)
      expect(error).to be_an_instance_of(Clicksend::ConnectionError)
      expect(error.request_may_have_been_sent?).to be(true)
    end

    it "keeps the original exception as the cause" do
      expect(failure_for(Errno::ECONNREFUSED).cause).to be_a(Faraday::ConnectionFailed)
    end
  end

  # The shapes faraday-net_http_persistent 2.x (with net-http-persistent 4
  # and connection_pool) raises, as observed in
  # spec/integration/persistent_connection_spec.rb.
  describe "failures from adapter: :net_http_persistent" do
    def failure_from(faraday_error)
      stubs = Faraday::Adapter::Test::Stubs.new { |stub| stub.post("/v3/sms/send") { raise faraday_error } }
      described_class.new(base_url: "https://rest.clicksend.com", timeout: 1, open_timeout: 1, adapter: [:test, stubs])
        .call(:post, "/v3/sms/send", body: "{}")
    rescue Clicksend::ConnectionError => e
      e
    end

    # An exception of +error_class+ raised while handling +cause+, as
    # net-http-persistent raises its Error in a rescue of the Errno.
    def raised_during(cause, error_class, message)
      raise cause
    rescue cause.class
      begin
        raise error_class, message
      rescue error_class => e
        e
      end
    end

    it "treats a refused connection (Net::HTTP::Persistent::Error caused by ECONNREFUSED) as not sent" do
      refused = raised_during(Errno::ECONNREFUSED.new, Net::HTTP::Persistent::Error, "connection refused: 127.0.0.1:1")
      error = failure_from(Faraday::ConnectionFailed.new(refused))
      expect(error).to be_an_instance_of(Clicksend::ConnectionError)
      expect(error.request_may_have_been_sent?).to be(false)
    end

    it "keeps every other Net::HTTP::Persistent::Error as possibly sent (a downed host can follow the write)" do
      down = raised_during(Errno::EHOSTDOWN.new, Net::HTTP::Persistent::Error, "host down: 127.0.0.1:1")
      expect(failure_from(Faraday::ConnectionFailed.new(down)).request_may_have_been_sent?).to be(true)
      expect(failure_from(Faraday::ConnectionFailed.new(Net::HTTP::Persistent::Error.new("connection refused: 127.0.0.1:1"))).request_may_have_been_sent?).to be(true)
    end

    it "treats a connect timeout or a pool checkout timeout as a TimeoutError that was not sent" do
      [Net::OpenTimeout.new, ConnectionPool::TimeoutError.new("Waited 0.5 sec, 0/1 available")].each do |cause|
        error = failure_from(Faraday::TimeoutError.new(cause))
        expect(error).to be_a(Clicksend::TimeoutError)
        expect(error.request_may_have_been_sent?).to be(false), cause.class.name
      end
    end

    it "keeps a read timeout, or a timeout of unknown origin, as possibly sent" do
      [Net::ReadTimeout.new, Timeout::Error.new, nil].each do |cause|
        error = failure_from(Faraday::TimeoutError.new(cause))
        expect(error).to be_a(Clicksend::TimeoutError)
        expect(error.request_may_have_been_sent?).to be(true), cause.class.name
      end
    end
  end
end
