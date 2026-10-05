# frozen_string_literal: true

module Clicksend
  module Resources
    # SMS: sending, delivery receipts and inbound replies. Reached through Client#sms.
    class SMS
      # Per-message fields accepted by POST /v3/sms/send (contact_id is
      # documented as "no longer in use" and deliberately omitted).
      MESSAGE_FIELDS = %i[
        to list_id body from source schedule custom_string country from_email exclude_no_sender_id_recipients
      ].freeze
      DEFAULT_FIELDS = (MESSAGE_FIELDS - %i[to list_id body]).freeze

      def initialize(client)
        @client = client
        freeze
      end

      # Sends one SMS (POST /v3/sms/send).
      #
      #   client.sms.deliver(to: "+61411111111", body: "Your code is 481516", from: "Acme")
      #
      # Raises Clicksend::MessageRejected if ClickSend does not accept the
      # message (e.g. status "INVALID_RECIPIENT"), even though the HTTP request
      # succeeded.
      #
      # Sends are never retried after a timeout or 5xx, because ClickSend has
      # no idempotency key and the message may already have been accepted. A
      # Clicksend::TimeoutError therefore means "unknown": reconcile using
      # +custom_string+ before sending again.
      #
      # @param to [String] recipient in E.164 format, e.g. "+61411111111"
      # @param body [String] message text (Unicode is detected by ClickSend)
      # @param from [String, nil] sender ID: alpha tag, dedicated or own number
      # @param schedule [Time, Integer, nil] send later (Time or Unix timestamp)
      # @param custom_string [String, nil] your reference, echoed in receipts and replies
      # @param shorten_urls [Boolean, nil] ask ClickSend to shorten URLs in the body
      # @return [Clicksend::SMS::Message]
      def deliver(to:, body:, from: nil, schedule: nil, custom_string: nil, country: nil, source: nil, from_email: nil, shorten_urls: nil)
        message = {to: to, body: body, from: from, schedule: schedule, custom_string: custom_string,
                   country: country, source: source, from_email: from_email}
        batch = submit([normalize_message(message, nil)], shorten_urls)
        unless batch.messages.size == 1
          raise MalformedResponseError.new(
            "Expected one message result, got #{batch.messages.size} (blocked_count: #{batch.blocked_count.inspect})",
            body: batch.raw
          )
        end

        result = batch.messages.first
        raise MessageRejected, result if result.rejected?

        result
      end

      # Sends several SMS in one request (POST /v3/sms/send).
      #
      #   batch = client.sms.deliver_batch(
      #     [{to: "+61411111111", body: "Hi Ann"}, {to: "+61422222222", body: "Hi Bob"}],
      #     from: "Acme"
      #   )
      #   batch.rejected.each { |m| warn "#{m.to}: #{m.status}" }
      #
      # Each message is a Hash with :body and either :to or :list_id, plus any
      # of the optional fields of #deliver. Keyword arguments other than
      # +shorten_urls+ are defaults applied to every message; a message's own
      # value wins.
      #
      # Never raises for partially failed batches: check Batch#rejected.
      #
      # ClickSend's examples mention up to 1000 messages per request; that
      # limit is not part of the API schema, so it is not enforced here.
      #
      # @return [Clicksend::SMS::Batch]
      def deliver_batch(messages, shorten_urls: nil, **defaults)
        unless messages.is_a?(Array) && !messages.empty?
          raise ArgumentError, "messages must be a non-empty Array of Hashes"
        end
        unknown = defaults.keys - DEFAULT_FIELDS
        unless unknown.empty?
          raise ArgumentError, "unknown default(s) #{unknown.map(&:inspect).join(", ")}; allowed: #{DEFAULT_FIELDS.join(", ")}"
        end

        normalized = messages.each_with_index.map do |message, index|
          raise ArgumentError, "messages[#{index}] must be a Hash" unless message.is_a?(Hash)

          normalize_message(defaults.merge(message.transform_keys(&:to_sym)), index)
        end
        submit(normalized, shorten_urls)
      end

      def inspect
        "#<#{self.class.name}>"
      end

      private

      def submit(messages, shorten_urls)
        body = {messages: messages}
        body[:shorten_urls] = shorten_urls unless shorten_urls.nil?
        Clicksend::SMS::Batch.from_api(@client.request(:post, "/v3/sms/send", body: body).data)
      end

      def normalize_message(message, index)
        label = index ? "messages[#{index}]" : "message"
        unknown = message.keys - MESSAGE_FIELDS
        unless unknown.empty?
          raise ArgumentError, "#{label}: unknown field(s) #{unknown.map(&:inspect).join(", ")}; allowed: #{MESSAGE_FIELDS.join(", ")}"
        end
        raise ArgumentError, "#{label}: body must be a String" unless message[:body].is_a?(String)
        if message[:to].nil? == message[:list_id].nil?
          raise ArgumentError, "#{label}: provide exactly one of to: or list_id:"
        end
        raise ArgumentError, "#{label}: to must be a String" unless message[:to].nil? || message[:to].is_a?(String)

        message = message.compact
        message[:schedule] = unix_time(message[:schedule], label) if message.key?(:schedule)
        message
      end

      def unix_time(value, label)
        case value
        when Integer then value
        when Time then value.to_i
        else
          return value.to_time.to_i if value.respond_to?(:to_time)

          raise ArgumentError, "#{label}: schedule must be a Time or Unix timestamp"
        end
      end
    end
  end
end
