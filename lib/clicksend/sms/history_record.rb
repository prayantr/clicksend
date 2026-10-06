# frozen_string_literal: true

module Clicksend
  module SMS
    # One row of SMS history (GET /v3/sms/history): a message you sent
    # (+direction+ "out") or received ("in").
    #
    # +status+ is ClickSend's history status ("Queued", "Sent", "Completed",
    # "Scheduled", "WaitApproval", "Failed", "Cancelled", "CancelledAfterReview",
    # "Received"), which is not the send-time status of SMS::Message.
    # +status_code+ is the gateway code also used by receipts (see
    # SMS::Receipt): 200 not final, 201 delivered, 300 retrying, 301 failed.
    HistoryRecord = Data.define(
      :message_id, :direction, :status, :status_code, :status_text, :error_code, :error_text,
      :to, :from, :body, :parts, :price, :custom_string, :list_id, :country, :carrier,
      :sent_at, :scheduled_at, :raw
    ) do
      include Model::Inspect

      def self.from_api(payload)
        payload = Model.payload!(payload, "history record")
        scheduled = Model.integer(payload["schedule"])
        new(
          message_id: Model.string(payload["message_id"]),
          direction: Model.string(payload["direction"]),
          status: Model.string(payload["status"]),
          status_code: Model.integer(payload["status_code"]),
          status_text: Model.string(payload["status_text"]),
          error_code: Model.code(payload["error_code"]),
          error_text: Model.string(payload["error_text"]),
          to: Model.string(payload["to"]),
          from: Model.string(payload["from"]),
          body: Model.string(payload["body"]),
          parts: Model.integer(payload["message_parts"]),
          price: Model.decimal(payload["message_price"]),
          custom_string: Model.string(payload["custom_string"]),
          list_id: Model.code(payload["list_id"]),
          country: Model.string(payload["country"]),
          carrier: Model.string(payload["carrier"]),
          sent_at: Model.time(payload["date"]),
          scheduled_at: (Time.at(scheduled).utc if scheduled&.positive?),
          raw: payload
        )
      end

      def outbound?
        direction == "out"
      end

      def inbound?
        direction == "in"
      end

      def delivered?
        status_code == 201
      end

      def failed?
        status_code == 301
      end

      # Not final yet: sent/queued/scheduled (200) or temporarily failing (300).
      def pending?
        status_code == 200 || status_code == 300
      end
    end
  end
end
