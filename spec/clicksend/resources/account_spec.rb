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
    expect { client.account.fetch }.to raise_error(Clicksend::AuthenticationError, "HTTP 401: UNAUTHORIZED - Authorization failed.")
  end

  it "raises MalformedResponseError when data is not an object" do
    stub_api(:get, "/v3/account").to_return(json_response(envelope(nil)))
    expect { client.account.fetch }.to raise_error(Clicksend::MalformedResponseError, /account to be a JSON object/)
  end
end
