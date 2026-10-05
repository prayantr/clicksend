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
      MESSAGE_ID = /\A[A-Za-z0-9-]+\z/

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

      # Unread delivery receipts (GET /v3/sms/receipts).
      #
      # Requires an SMS receipt rule with the POLL action in your ClickSend
      # account. Only receipts not yet marked as read are listed, so marking
      # receipts read while paging shifts later pages: process, then call
      # #mark_receipts_read(before:).
      #
      #   client.sms.receipts.auto_paging_each { |receipt| track(receipt) if receipt.delivered? }
      #
      # @return [Clicksend::Page<Clicksend::SMS::Receipt>]
      def receipts(page: nil, limit: nil)
        Page.fetch(@client, "/v3/sms/receipts", page: page, limit: limit) { |item| Clicksend::SMS::Receipt.from_api(item) }
      end

      # One delivery receipt, read or not (GET /v3/sms/receipts/{message_id}).
      # @return [Clicksend::SMS::Receipt]
      def receipt(message_id)
        Clicksend::SMS::Receipt.from_api(@client.request(:get, "/v3/sms/receipts/#{message_id!(message_id)}").data)
      end

      # Marks delivery receipts as read (PUT /v3/sms/receipts-read): all of
      # them, or only those before +before+.
      # @param before [Time, Integer, nil]
      # @return [nil]
      def mark_receipts_read(before: nil)
        @client.request(:put, "/v3/sms/receipts-read", body: date_before(before), idempotent: true)
        nil
      end

      # Unread inbound SMS, i.e. replies (GET /v3/sms/inbound).
      #
      # Requires an SMS inbound rule with the POLL action. As with receipts,
      # only unread messages are listed.
      #
      # @return [Clicksend::Page<Clicksend::SMS::InboundMessage>]
      def inbound(page: nil, limit: nil)
        Page.fetch(@client, "/v3/sms/inbound", page: page, limit: limit) { |item| Clicksend::SMS::InboundMessage.from_api(item) }
      end

      # Marks inbound SMS as read (PUT /v3/sms/inbound-read): all of them, or
      # only those before +before+.
      # @return [nil]
      def mark_inbound_read(before: nil)
        @client.request(:put, "/v3/sms/inbound-read", body: date_before(before), idempotent: true)
        nil
      end

      # Marks one inbound SMS as read (PUT /v3/sms/inbound-read/{message_id}).
      # @return [nil]
      def mark_inbound_message_read(message_id)
        @client.request(:put, "/v3/sms/inbound-read/#{message_id!(message_id)}", idempotent: true)
        nil
      end

      def inspect
        "#<#{self.class.name}>"
      end

      private

      # Message IDs are interpolated into paths, so only ID characters are allowed.
      def message_id!(value)
        return value if value.is_a?(String) && value.match?(MESSAGE_ID)

        raise ArgumentError, "message_id must be a ClickSend message ID such as \"31BC271B-1E0C-45F6-9E7E-97186C46BB82\", got #{value.inspect}"
      end

      def date_before(before)
        before.nil? ? {} : {date_before: unix_time(before, "before")}
      end

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
          # Date/DateTime/ActiveSupport::TimeWithZone; Strings are rejected even
          # if ActiveSupport makes them respond to #to_time.
          return value.to_time.to_i if value.respond_to?(:to_time) && !value.is_a?(String)

          raise ArgumentError, "#{label}: expected a Time or Unix timestamp, got #{value.inspect}"
        end
      end
    end
  end
end
