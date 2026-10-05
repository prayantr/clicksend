# frozen_string_literal: true

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

    it "treats a reset connection as possibly sent" do
      error = failure_for(Errno::ECONNRESET)
      expect(error).to be_an_instance_of(Clicksend::ConnectionError)
      expect(error.request_may_have_been_sent?).to be(true)
    end

    it "keeps the original exception as the cause" do
      expect(failure_for(Errno::ECONNREFUSED).cause).to be_a(Faraday::ConnectionFailed)
    end
  end
end
