# frozen_string_literal: true

RSpec.describe Clicksend::Resources::SMS, "#cancel" do
  let(:message_id) { "1EF50711-2787-68F4-8223-9F9C4393E380" }
  let(:path) { "/v3/sms/#{message_id}/cancel" }

  it "PUTs to the message's cancel path with no body and returns nil (ClickSend's documented example)" do
    stub = stub_api(:put, path).to_return(json_response(fixture("sms_cancel")))

    expect(client.sms.cancel(message_id)).to be_nil
    expect(stub).to have_been_requested
    expect(a_request(:put, "#{ApiHelpers::BASE}#{path}").with { |request| request.body.to_s.empty? }).to have_been_made
  end

  it "labels the request sms.cancel and does not treat it as idempotent" do
    events = []
    instrumenter = Object.new
    instrumenter.define_singleton_method(:instrument) do |_name, payload, &block|
      block.call(payload)
      events << payload
    end
    stub_api(:put, path).to_return(json_response(fixture("sms_cancel")))

    client(instrumenter: instrumenter).sms.cancel(message_id)
    expect(events.last).to include(http_method: :put, path: path, operation: "sms.cancel", idempotent: false)
  end

  it "is not retried after a timeout: the outcome is unknown, so the error is ambiguous" do
    allow(Kernel).to receive(:sleep)
    timeout = stub_api(:put, path).to_raise(Net::ReadTimeout)
    expect { client.sms.cancel(message_id) }.to raise_error(Clicksend::AmbiguousRequestError) { |e|
      expect(e).to be_a(Clicksend::TimeoutError)
      expect(e.retryable?).to be(false)
      expect(e.request).to have_attributes(operation: "sms.cancel", idempotent: false, attempts: 1)
    }
    expect(timeout).to have_been_requested.once
  end

  it "is not retried after a 5xx either" do
    allow(Kernel).to receive(:sleep)
    server = stub_api(:put, path).to_return({status: 502, body: ""}, json_response(fixture("sms_cancel")))
    expect { client.sms.cancel(message_id) }.to raise_error(Clicksend::ServerError) { |e| expect(e).to be_ambiguous }
    expect(server).to have_been_requested.once
  end

  it "is retried after a 429, which ClickSend documents as not served" do
    allow(Kernel).to receive(:sleep)
    stub = stub_api(:put, path).to_return(
      json_response(envelope(nil, http_code: 429, response_code: "HTTP_TOO_MANY_REQUESTS"), status: 429, headers: {"Retry-After" => "0"}),
      json_response(fixture("sms_cancel"))
    )
    expect(client.sms.cancel(message_id)).to be_nil
    expect(stub).to have_been_requested.twice
  end

  it "raises the typed error for whatever ClickSend answers to a message it won't cancel" do
    stub_api(:put, path).to_return(json_response(envelope(nil, http_code: 404, response_code: "NOT_FOUND", response_msg: "Not found."), status: 404))
    expect { client.sms.cancel(message_id) }.to raise_error(Clicksend::NotFoundError) { |e| expect(e).not_to be_ambiguous }
  end

  it "treats an error inside a 2xx body as ambiguous, like every other undocumented answer" do
    stub_api(:put, path).to_return(json_response(envelope(nil, http_code: 400, response_code: "BAD_REQUEST")))
    expect { client.sms.cancel(message_id) }.to raise_error(Clicksend::BadRequestError) { |e| expect(e).to be_ambiguous }
  end

  it "accepts only message ID characters, since the ID is part of the path" do
    ["", "../account", "A B", nil, 42, "#{message_id}/cancel"].each do |bad|
      expect { client.sms.cancel(bad) }.to raise_error(ArgumentError, /message_id must be a ClickSend message ID/)
    end
    expect(a_request(:any, /clicksend/)).not_to have_been_made
  end
end
