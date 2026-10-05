# frozen_string_literal: true

module Clicksend
  # Account details from GET /v3/account.
  #
  # +balance+ is ClickSend's decimal String (e.g. "4.998000") in +currency+
  # (e.g. "AUD").
  #
  # The response also contains a +_subaccount+ object with the subaccount's
  # +api_key+ (shown in ClickSend's example, confirmed live). That one value is
  # replaced with "[REDACTED]" in #raw so an Account can be logged safely;
  # every other field is kept as returned.
  Account = Data.define(:user_id, :username, :account_name, :balance, :currency, :country, :timezone, :raw) do
    include Model::Inspect

    def self.from_api(payload)
      payload = redact_api_key(Model.payload!(payload, "account"))
      currency = payload["_currency"]
      new(
        user_id: Model.integer(payload["user_id"]),
        username: Model.string(payload["username"]),
        account_name: Model.string(payload["account_name"]),
        balance: Model.decimal(payload["balance"]),
        currency: (Model.string(currency["currency_name_short"]) if currency.is_a?(Hash)),
        country: Model.string(payload["country"]),
        timezone: Model.string(payload["timezone"]),
        raw: payload
      )
    end

    def self.redact_api_key(payload)
      subaccount = payload["_subaccount"]
      return payload unless subaccount.is_a?(Hash) && subaccount.key?("api_key")

      payload.merge("_subaccount" => subaccount.merge("api_key" => Model::REDACTED).freeze).freeze
    end
    private_class_method :redact_api_key
  end
end
