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
    # It can be nil: a test-number message was observed as "Completed" with no
    # code.
    #
    # The predicates follow ClickSend's "SMS error codes" article (help 42318).
    # The gateway code decides when present. Without one, only statuses whose
    # code that article fixes are used: "Queued", "Scheduled" and
    # "WaitApproval" are always 200 (pending); "Failed" and "Cancelled" are
    # 301 and "CancelledAfterReview" never reached the network (failed). A
    # "Sent" row can be 200 or 201, and "Completed" isn't in the article, so
    # without a code neither is known: all three predicates are false.
    # History statuses whose gateway code help 42318 fixes (see HistoryRecord).
    HISTORY_PENDING_STATUSES = %w[Queued Scheduled WaitApproval].freeze
    HISTORY_FAILED_STATUSES = %w[Failed Cancelled CancelledAfterReview].freeze
    private_constant :HISTORY_PENDING_STATUSES, :HISTORY_FAILED_STATUSES

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

      # Delivered to the handset (gateway code 201).
      def delivered?
        status_code == 201
      end

      # Final and not delivered: code 301, or a failed or cancelled status.
      def failed?
        status_code.nil? ? HISTORY_FAILED_STATUSES.include?(status) : status_code == 301
      end

      # Not final yet: code 200 or 300, or a status that is always 200.
      def pending?
        status_code.nil? ? HISTORY_PENDING_STATUSES.include?(status) : [200, 300].include?(status_code)
      end
    end
  end
end
