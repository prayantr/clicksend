# frozen_string_literal: true

module Clicksend
  module SMS
    # An inbound SMS (a reply), from GET /v3/sms/inbound.
    #
    # +original_message_id+ and +original_body+ identify the message you sent
    # that this replies to; +custom_string+ is echoed from that message.
    InboundMessage = Data.define(
      :message_id, :from, :to, :body, :original_body, :original_message_id, :custom_string, :received_at, :raw
    ) do
      include Model::Inspect

      def self.from_api(payload)
        payload = Model.payload!(payload, "inbound message")
        new(
          message_id: Model.string(payload["message_id"]),
          from: Model.string(payload["from"]),
          to: Model.string(payload["to"]),
          body: Model.string(payload["body"]),
          original_body: Model.string(payload["original_body"]),
          original_message_id: Model.string(payload["original_message_id"]),
          custom_string: Model.string(payload["custom_string"]),
          # The schema names this "timestamp"; the list example uses "timestamp_send".
          received_at: Model.time(payload["timestamp"] || payload["timestamp_send"]),
          raw: payload
        )
      end
    end
  end
end
