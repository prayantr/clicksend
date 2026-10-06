# frozen_string_literal: true

require_relative "../testing"

module Clicksend
  module Testing
    # The matching and failure output shared by the RSpec matchers
    # (clicksend/testing/rspec) and the Minitest assertions
    # (clicksend/testing/minitest). Framework-free.
    # @api private
    module SmsExpectations
      ATTRIBUTES = SentMessage.members.freeze
      # Failure output lists at most this many messages...
      MAX_LISTED = 10
      # ...and shortens longer values to this many characters.
      MAX_VALUE_LENGTH = 60

      module_function

      # @return [Array<SentMessage>]
      def sent_messages(fake, helper)
        return fake.sent_messages if fake.is_a?(FakeAPI)

        raise ArgumentError, "#{helper} expects a Clicksend::Testing::FakeAPI (the fake itself, not fake.client " \
          "or fake.sent_messages), got #{fake.class}"
      end

      # Keys must be SentMessage attributes: a typo must fail the test, not
      # match everything.
      def check_attributes!(attributes, helper)
        unknown = attributes.keys - ATTRIBUTES
        return if unknown.empty?

        raise ArgumentError, "#{helper}: unknown attribute#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")}; " \
          "use #{ATTRIBUTES.join(", ")}"
      end

      def check_count!(count, helper)
        raise ArgumentError, "#{helper}: the count must be a non-negative Integer, got #{count.inspect}" unless count.is_a?(Integer) && count >= 0
      end

      # Each expected value is matched with +===+, so Strings, Regexps,
      # Ranges, classes, procs and RSpec's composable matchers all work.
      # @return [Array<SentMessage>]
      def matching(messages, attributes)
        messages.select { |message| attributes.all? { |key, expected| expected === message.public_send(key) } }
      end

      # "SMS matching to: "+61411111111", body: /code/" or "SMS".
      def subject(attributes)
        return "SMS" if attributes.empty?

        "SMS matching #{attributes.map { |key, value| "#{key}: #{describe_value(value)}" }.join(", ")}"
      end

      # The failure when +count+ messages were expected and +matched+ were found.
      def count_failure(attributes, count, matched, messages)
        expectation = count.zero? ? "no #{subject(attributes)}" : "exactly #{count} #{subject(attributes)}"
        "expected #{expectation} to have been sent, but #{matched.size} matched.\n#{listing(messages, attributes)}"
      end

      # "No SMS was sent." or "3 SMS sent:" and one line per message (at
      # most MAX_LISTED).
      def listing(messages, attributes)
        return "No SMS was sent." if messages.empty?

        lines = messages.first(MAX_LISTED).each_with_index.map { |message, index| "  #{index + 1}. #{line(message, attributes)}" }
        lines << "  ... and #{messages.size - MAX_LISTED} more" if messages.size > MAX_LISTED
        "#{messages.size} SMS sent:\n#{lines.join("\n")}"
      end

      # One message on one line: recipient (or list_id), custom_string and
      # body, then any other attribute the expectation names.
      def line(message, attributes)
        keys = [message.to.nil? ? :list_id : :to, :custom_string, :body] | attributes.keys
        keys.map { |key| "#{key}: #{show(message.public_send(key))}" }.join(", ")
      end

      def describe_value(value)
        value.respond_to?(:description) ? value.description : show(value)
      end

      # A long String is cut, with the "..." outside its quotes.
      def show(value)
        return value.inspect unless value.is_a?(String) && value.length > MAX_VALUE_LENGTH

        "#{value[0, MAX_VALUE_LENGTH].inspect}..."
      end
    end
  end
end
