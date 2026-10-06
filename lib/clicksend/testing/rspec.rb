# frozen_string_literal: true

require "rspec/expectations"
require_relative "../testing"
require_relative "sms_expectations"

module Clicksend
  module Testing
    # RSpec matchers over a FakeAPI's sent messages. Opt-in, from your
    # spec_helper (never loaded by +require "clicksend"+):
    #
    #   require "clicksend/testing/rspec"
    #
    # which includes them in every example group (with rspec-core; otherwise
    # include Clicksend::Testing::RSpecMatchers yourself).
    #
    #   expect(fake).to have_sent_sms(to: "+61411111111", body: /481516/, custom_string: "otp:42")
    #   expect(fake).to have_sent_sms(to: "+61411111111").twice
    #   expect(fake).not_to have_sent_sms(to: "+61422222222")
    #   expect(fake).to have_sent_no_sms
    #
    # They match the attributes of SentMessage (to, body, custom_string,
    # from, list_id, scheduled_at, country, message_id, sent_at) with +===+,
    # so Strings, Regexps, procs and composable matchers work. "Sent" means
    # accepted (fake.sent_messages): rejected recipients don't count.
    #
    # Without a count, have_sent_sms expects exactly one matching message:
    # a second one is the duplicate these matchers are there to catch.
    module RSpecMatchers
      # Passes when exactly one sent message (or the chained count) matches
      # every given attribute. Negated, passes when none matches.
      # @return [HaveSentSms]
      def have_sent_sms(**attributes)
        HaveSentSms.new(attributes)
      end

      # Passes when no message was sent or, given attributes, none of the
      # sent messages matches them.
      # @return [HaveSentSms]
      def have_sent_no_sms(**attributes)
        HaveSentSms.new(attributes, count: 0, name: "have_sent_no_sms")
      end

      # The matcher behind #have_sent_sms and #have_sent_no_sms.
      class HaveSentSms
        include ::RSpec::Matchers::Composable

        def initialize(attributes, count: nil, name: "have_sent_sms")
          SmsExpectations.check_attributes!(attributes, name)
          @attributes = attributes
          @count = count
          @name = name
          @fixed = !count.nil?
        end

        # @return [self]
        def once = exactly(1)

        # @return [self]
        def twice = exactly(2)

        # +exactly(n).times+, or just +times(n)+.
        # @return [self]
        def exactly(count)
          raise ArgumentError, "#{@name} takes no count; use have_sent_sms(...).exactly(n).times" if @fixed

          SmsExpectations.check_count!(count, @name)
          @count = count
          self
        end

        # @return [self]
        def times(count = nil)
          return exactly(count) unless count.nil?
          raise ArgumentError, "use have_sent_sms(...).times(n) or .exactly(n).times" if @count.nil?

          self
        end

        def matches?(fake)
          evaluate(fake)
          @matched.size == expected_count
        end

        def does_not_match?(fake)
          if @fixed || !@count.nil?
            raise ArgumentError, "#{@name}#{" with a count" unless @fixed} can't be negated: " \
              "say how many you expect, e.g. to have_sent_sms(...).exactly(0).times"
          end

          evaluate(fake)
          @matched.empty?
        end

        def failure_message
          SmsExpectations.count_failure(@attributes, expected_count, @matched, @sent)
        end

        def failure_message_when_negated
          SmsExpectations.count_failure(@attributes, 0, @matched, @sent)
        end

        def description
          return "have sent no #{SmsExpectations.subject(@attributes)}" if expected_count.zero?

          "have sent exactly #{expected_count} #{SmsExpectations.subject(@attributes)}"
        end

        private

        def expected_count = @count || 1

        def evaluate(fake)
          @sent = SmsExpectations.sent_messages(fake, @name)
          @matched = SmsExpectations.matching(@sent, @attributes)
        end
      end
    end
  end
end

if defined?(RSpec.configure)
  RSpec.configure { |config| config.include(Clicksend::Testing::RSpecMatchers) }
end
