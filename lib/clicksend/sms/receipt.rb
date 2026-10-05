# frozen_string_literal: true

module Clicksend
  module SMS
    # A delivery receipt from GET /v3/sms/receipts[/{message_id}].
    #
    # +status_code+ is the SMS gateway code documented in ClickSend's help
    # centre ("SMS error codes", https://help.clicksend.com/en/articles/42318-sms-error-codes):
    #
    #   200  sent / queued / scheduled (not final)
    #   201  delivered to the handset
    #   300  temporary network failure; ClickSend retries automatically (not final)
    #   301  failed or cancelled (final); see status_text / error_code
    Receipt = Data.define(
      :message_id, :status_code, :status_text, :error_code, :error_text, :custom_string,
      :message_type, :subaccount_id, :sent_at, :reported_at, :raw
    ) do
      include Model::Inspect

      def self.from_api(payload)
        payload = Model.payload!(payload, "receipt")
        new(
          message_id: Model.string(payload["message_id"]),
          status_code: Model.integer(payload["status_code"]),
          status_text: Model.string(payload["status_text"]),
          error_code: Model.integer(payload["error_code"]),
          error_text: Model.string(payload["error_text"]),
          custom_string: Model.string(payload["custom_string"]),
          message_type: Model.string(payload["message_type"]),
          subaccount_id: Model.integer(payload["subaccount_id"]),
          sent_at: Model.time(payload["timestamp_send"]),
          reported_at: Model.time(payload["timestamp"]),
          raw: payload
        )
      end

      def delivered?
        status_code == 201
      end

      def failed?
        status_code == 301
      end

      # Not final yet: sent/queued (200) or temporarily failing and being retried (300).
      def pending?
        status_code == 200 || status_code == 300
      end
    end
  end
end
