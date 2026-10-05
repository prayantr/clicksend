# frozen_string_literal: true

module Clicksend
  module SMS
    # The result of POST /v3/sms/send for one or more messages.
    #
    # A batch request succeeds at the HTTP level even when some (or all)
    # messages are not accepted, so always check #rejected / #all_queued?.
    #
    # A Batch is Enumerable over its messages (batch.map(&:message_id)).
    Batch = Data.define(:messages, :total_price, :total_count, :queued_count, :blocked_count, :currency, :raw) do
      include Model::Inspect
      include Enumerable

      # Enumerable#to_h would shadow Data#to_h (members => values); keep Data's.
      define_method(:to_h, Data.instance_method(:to_h))

      def self.from_api(payload)
        payload = Model.payload!(payload, "send result")
        unless payload["messages"].is_a?(Array)
          raise MalformedResponseError.new("Send result has no messages list", body: payload)
        end

        currency = payload["_currency"]
        new(
          messages: payload["messages"].map { |message| Message.from_api(message) }.freeze,
          total_price: Model.decimal(payload["total_price"]),
          total_count: Model.integer(payload["total_count"]),
          queued_count: Model.integer(payload["queued_count"]),
          blocked_count: Model.integer(payload["blocked_count"]),
          currency: (Model.string(currency["currency_name_short"]) if currency.is_a?(Hash)),
          raw: payload
        )
      end

      def each(&)
        return messages.each unless block_given?

        messages.each(&)
        self
      end

      def size
        messages.size
      end

      # Messages ClickSend accepted and queued.
      def queued
        messages.select(&:queued?)
      end

      # Messages ClickSend did not accept, each with its status.
      def rejected
        messages.reject(&:queued?)
      end

      # True when every message was accepted and ClickSend reports none blocked.
      def all_queued?
        rejected.empty? && blocked_count.to_i.zero?
      end
    end
  end
end
