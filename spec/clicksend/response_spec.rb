# frozen_string_literal: true

RSpec.describe Clicksend::Response do
  let(:info) { Clicksend::RequestInfo.new(http_method: :get, path: "/v3/account", operation: "account.fetch", idempotent: true, attempts: 2) }
  let(:body) { {"http_code" => 200, "response_code" => "SUCCESS", "data" => {"a" => 1}}.freeze }
  let(:response) { described_class.new(http_status: 200, headers: {"x" => "1"}, body: body, request: info) }

  describe "1.0 structural compatibility" do
    it "has the same members, so equality ignores the request context" do
      expect(described_class.members).to eq(%i[http_status headers body])
      expect(response).to eq(described_class.new(http_status: 200, headers: {"x" => "1"}, body: body))
      expect(response).to eq(described_class.new(200, {"x" => "1"}, body))
      expect(response.to_h).to eq(http_status: 200, headers: {"x" => "1"}, body: body)
    end

    it "pattern-matches as in 1.0, by position and by key" do
      by_position = case response
      in [200, Hash, Hash => matched_body] then matched_body["data"]
      end
      by_key = case response
      in {http_status: 200, body:} then body["response_code"]
      end
      expect([by_position, by_key]).to eq([{"a" => 1}, "SUCCESS"])
    end
  end

  describe "#request" do
    it "is available, and nil when the response was built without one" do
      expect(response.request).to eq(info)
      expect(described_class.new(http_status: 200, headers: {}, body: nil).request).to be_nil
    end

    it "is kept by #with unless replaced" do
      expect(response.with(http_status: 201).request).to eq(info)
      expect(response.with(request: nil).request).to be_nil
    end

    it "survives Marshal (e.g. Rails.cache), along with the members, and stays frozen" do
      loaded = Marshal.load(Marshal.dump(response)) # rubocop:disable Security/MarshalLoad
      expect(loaded).to eq(response)
      expect(loaded.request).to eq(info)
      expect(loaded).to be_frozen
    end
  end

  it "is what Client#request returns, with the request context" do
    stub_api(:get, "/v3/account").to_return(json_response(fixture("account")))
    result = client.request(:get, "/v3/account", operation: "account.fetch")
    expect(result.request).to have_attributes(operation: "account.fetch", attempts: 1)
    expect(result.to_h.keys).to eq(%i[http_status headers body])
  end
end
