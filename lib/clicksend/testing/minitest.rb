# frozen_string_literal: true

require "minitest"
require_relative "../testing"
require_relative "sms_expectations"

module Clicksend
  module Testing
    # Minitest assertions over a FakeAPI's sent messages. Opt-in (never
    # loaded by +require "clicksend"+); include them where you need them:
    #
    #   require "clicksend/testing/minitest"
    #
    #   class ActiveSupport::TestCase # or Minitest::Test
    #     include Clicksend::Testing::MinitestAssertions
    #   end
    #
    #   assert_sms_sent fake, to: "+61411111111", body: /481516/, custom_string: "otp:42"
    #   assert_sms_sent fake, to: "+61411111111", count: 2
    #   assert_no_sms_sent fake, to: "+61422222222"
    #   assert_no_sms_sent fake
    #
    # They match the attributes of SentMessage (to, body, custom_string,
    # from, list_id, scheduled_at, country, message_id, sent_at) with +===+,
    # so Strings, Regexps and procs work. "Sent" means accepted
    # (fake.sent_messages): rejected recipients don't count.
    module MinitestAssertions
      # Asserts that exactly +count+ sent messages match every given
      # attribute. The default count is 1: a second matching message is the
      # duplicate this assertion is there to catch.
      # @return [Array<SentMessage>] the matching messages
      def assert_sms_sent(fake, count: 1, **attributes)
        clicksend_assert_sms_count(fake, count, attributes, "assert_sms_sent")
      end

      # Asserts that no message was sent or, given attributes, that none of
      # the sent messages matches them.
      # @return [true]
      def assert_no_sms_sent(fake, **attributes)
        clicksend_assert_sms_count(fake, 0, attributes, "assert_no_sms_sent")
        true
      end

      private

      def clicksend_assert_sms_count(fake, count, attributes, name)
        SmsExpectations.check_attributes!(attributes, name)
        SmsExpectations.check_count!(count, name)
        sent = SmsExpectations.sent_messages(fake, name)
        matched = SmsExpectations.matching(sent, attributes)
        assert(matched.size == count, -> { SmsExpectations.count_failure(attributes, count, matched, sent) })
        matched
      end
    end
  end
end
