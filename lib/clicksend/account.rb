# frozen_string_literal: true

module Clicksend
  # Account details from GET /v3/account.
  #
  # +balance+ is ClickSend's decimal String (e.g. "4.998000") in +currency+
  # (e.g. "AUD").
  Account = Data.define(:user_id, :username, :account_name, :balance, :currency, :country, :timezone, :raw) do
    include Model::Inspect

    def self.from_api(payload)
      payload = Model.payload!(payload, "account")
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
  end
end
