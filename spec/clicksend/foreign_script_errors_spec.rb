# frozen_string_literal: true

require "clicksend/testing"

# A ScriptError (NotImplementedError, LoadError) from code outside the gem must
# be handled like a StandardError: after an accepted send it may not escape as
# a non-Clicksend error, because job runners rescue Exception and would send
# again. Interrupt and other non-script exceptions still propagate.
RSpec.describe "ScriptError from code outside the gem" do
  let(:fake) { Clicksend::Testing::FakeAPI.new }

  def deliver(client)
    client.sms.deliver(to: "+61411111111", body: "hi")
  end

  it "from a logger after an accepted send: the send's result is returned" do
    logger = Object.new
    def logger.info(*) = raise(NotImplementedError, "abstract logger")
    def logger.warn(*) = raise(NotImplementedError, "abstract logger")
    expect(deliver(fake.client(logger: logger))).to be_queued
    expect(fake.sent_messages.size).to eq(1)
  end

  it "from an instrumenter after the request is done: the send's result is returned" do
    instrumenter = Object.new
    def instrumenter.instrument(_name, payload = {})
      yield payload if block_given?
      raise LoadError, "cannot load such file -- some/exporter"
    end
    expect(deliver(fake.client(instrumenter: instrumenter))).to be_queued
    expect(fake.sent_messages.size).to eq(1)
  end

  it "from an instrumenter after a failed send: the ambiguous error is raised, not the LoadError" do
    instrumenter = Object.new
    def instrumenter.instrument(_name, payload = {})
      yield payload if block_given?
    ensure
      raise LoadError, "cannot load such file -- some/exporter"
    end
    fake.fail_next(:timeout, processed: true)
    expect { deliver(fake.client(instrumenter: instrumenter)) }.to raise_error(Clicksend::AmbiguousRequestError)
    expect(fake.sent_messages.size).to eq(1)
  end

  it "from a custom transport: an ambiguous ConnectionError for a send, keeping the cause" do
    transport = Object.new
    def transport.call(*, **) = raise(NotImplementedError, "subclass must implement #call")
    client = Clicksend::Client.new(username: "u", api_key: "k", transport: transport)
    expect { deliver(client) }.to raise_error(Clicksend::ConnectionError) { |e|
      expect(e).to be_ambiguous
      expect(e.cause).to be_a(NotImplementedError)
    }
  end

  it "from a retry policy: retrying stops and the request's own error is raised" do
    policy = Struct.new(:max_retries) { def delay(**) = raise(NotImplementedError, "todo") }.new(2)
    fake.fail_next(status: 503, processed: false)
    expect { fake.client(retry_policy: policy).account.fetch }.to raise_error(Clicksend::ServerError)
  end

  it "still lets Interrupt through" do
    logger = Object.new
    def logger.info(*) = raise(Interrupt)
    expect { deliver(fake.client(logger: logger)) }.to raise_error(Interrupt)
  end
end
