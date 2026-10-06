# frozen_string_literal: true

RSpec.describe Clicksend::Resources::Account do
  it "fetches the account (ClickSend's documented example)" do
    stub_api(:get, "/v3/account").to_return(json_response(fixture("account")))

    account = client.account.fetch

    expect(account).to have_attributes(
      user_id: 116, username: "johndoe1", account_name: "The Awesome Company",
      balance: "4.998000", currency: "AUD", country: "US", timezone: "Australia/Melbourne"
    )
    expect(account.raw["default_country_sms"]).to eq("US")
    expect(account).to be_frozen
    expect(account.inspect).to start_with("#<Clicksend::Account user_id=116,")
    expect(account.inspect).not_to include("raw")
  end

  # GET /v3/account includes a _subaccount object carrying the subaccount's API
  # key (in ClickSend's published example, and confirmed live on 2026-10-05).
  describe "the _subaccount credential echoed by the live API" do
    let(:payload) do
      fixture("account").tap do |body|
        body["data"]["_subaccount"] = {"subaccount_id" => 1, "api_username" => "acme", "api_key" => "SECRET-ECHOED-KEY", "access_sms" => 1}
      end
    end

    before { stub_api(:get, "/v3/account").to_return(json_response(payload)) }

    it "replaces the key in #raw, #to_h and #inspect, keeping every other field" do
      account = client.account.fetch
      expect(account.raw.dig("_subaccount", "api_key")).to eq("[REDACTED]")
      expect(account.raw.dig("_subaccount", "api_username")).to eq("acme")
      expect(account.raw.keys).to eq(payload["data"].keys)
      expect([account.raw.to_s, account.to_h.to_s, account.inspect]).to all(satisfy { |text| !text.include?("SECRET-ECHOED-KEY") })
      expect(account.raw).to be_frozen
      expect(account.raw["_subaccount"]).to be_frozen
    end

    it "leaves payloads without the key alone" do
      [nil, {"subaccount_id" => 1}].each do |subaccount|
        data = payload["data"].merge("_subaccount" => subaccount)
        expect(Clicksend::Account.from_api(data).raw).to equal(data)
      end
      expect(Clicksend::Account.from_api(payload["data"].except("_subaccount")).raw).not_to have_key("_subaccount")
    end

    it "leaves the escape hatch's Response#body untouched (documented: don't log it)" do
      expect(client.request(:get, "/v3/account").body.dig("data", "_subaccount", "api_key")).to eq("SECRET-ECHOED-KEY")
    end
  end

  it "tolerates a missing currency object" do
    payload = fixture("account")
    payload["data"].delete("_currency")
    stub_api(:get, "/v3/account").to_return(json_response(payload))
    expect(client.account.fetch.currency).to be_nil
  end

  it "raises AuthenticationError for rejected credentials" do
    stub_api(:get, "/v3/account").to_return(json_response(
      {"http_code" => 401, "response_code" => "UNAUTHORIZED", "response_msg" => "Authorization failed.", "data" => nil}, status: 401
    ))
    expect { client.account.fetch }.to raise_error(Clicksend::AuthenticationError, "HTTP 401: UNAUTHORIZED - Authorization failed. (GET /v3/account)")
  end

  it "raises MalformedResponseError when data is not an object" do
    stub_api(:get, "/v3/account").to_return(json_response(envelope(nil)))
    expect { client.account.fetch }.to raise_error(Clicksend::MalformedResponseError, /account to be a JSON object/)
  end
end
