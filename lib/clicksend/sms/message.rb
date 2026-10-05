# frozen_string_literal: true

module Clicksend
  module SMS
    # The result for one message submitted to POST /v3/sms/send.
    #
    # +status+ is ClickSend's per-message status: "SUCCESS" means the message
    # was accepted and queued; anything else (e.g. "INVALID_RECIPIENT",
    # "INSUFFICIENT_CREDIT", "COUNTRY_NOT_ENABLED") means it was not. The HTTP
    # status of the request does not reflect individual messages.
    Message = Data.define(
      :message_id, :status, :to, :from, :body, :parts, :price, :custom_string,
      :list_id, :country, :carrier, :sent_at, :scheduled_at, :raw
    ) do
      include Model::Inspect

      def self.from_api(payload)
        payload = Model.payload!(payload, "message")
        scheduled = Model.integer(payload["schedule"])
        new(
          message_id: Model.string(payload["message_id"]),
          status: Model.string(payload["status"]),
          to: Model.string(payload["to"]),
          from: Model.string(payload["from"]),
          body: Model.string(payload["body"]),
          parts: Model.integer(payload["message_parts"]),
          price: Model.decimal(payload["message_price"]),
          custom_string: Model.string(payload["custom_string"]),
          list_id: Model.string(payload["list_id"]) || Model.integer(payload["list_id"])&.to_s,
          country: Model.string(payload["country"]),
          carrier: Model.string(payload["carrier"]),
          sent_at: Model.time(payload["date"]),
          scheduled_at: (Time.at(scheduled).utc if scheduled&.positive?),
          raw: payload
        )
      end

      # Accepted by ClickSend and queued for delivery (status "SUCCESS").
      # Delivery to the handset is reported later by a receipt.
      def queued?
        status == "SUCCESS"
      end

      def rejected?
        !queued?
      end
    end
  end
end
