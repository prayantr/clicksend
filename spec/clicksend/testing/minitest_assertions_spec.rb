# frozen_string_literal: true

require "clicksend/testing/minitest"

# Each example runs the assertions inside a real Minitest::Test and checks
# Minitest's result, as a Minitest suite would see it.
RSpec.describe Clicksend::Testing::MinitestAssertions do
  let(:fake) { Clicksend::Testing::FakeAPI.new }

  def deliver(to: "+61411111111", body: "Your code is 481516", custom_string: "otp:42")
    fake.client.sms.deliver(to: to, body: body, custom_string: custom_string)
  end

  # Runs +body+ as a test method of a Minitest::Test that includes the
  # assertions; returns Minitest's result.
  def minitest(&body)
    test_class = Class.new(Minitest::Test) do
      include Clicksend::Testing::MinitestAssertions

      define_method(:test_sms, &body)
    end
    test_class.new(:test_sms).run
  end

  def failure_message(result)
    expect(result).not_to be_passed
    expect(result.failures.size).to eq(1)
    expect(result.failures.first).to be_a(Minitest::Assertion)
    expect(result.failures.first).not_to be_a(Minitest::UnexpectedError)
    result.failures.first.message
  end

  describe "#assert_sms_sent" do
    it "passes, as one assertion, when exactly one sent message matches every given attribute" do
      deliver
      deliver(to: "+61422222222", custom_string: "otp:43")
      fake = self.fake
      returned = nil

      result = minitest do
        returned = assert_sms_sent(fake, to: "+61411111111", body: /481516/, custom_string: "otp:42")
      end

      expect(result).to be_passed
      expect(result.assertions).to eq(1)
      expect(returned).to eq([fake.sent_messages.first])
    end

    it "matches with ===: Regexps, classes and procs" do
      deliver
      fake = self.fake

      expect(minitest { assert_sms_sent(fake, to: String, custom_string: ->(value) { value.end_with?(":42") }) }).to be_passed
    end

    it "fails on a second matching message by default, listing what was sent" do
      2.times { deliver }
      fake = self.fake

      expect(failure_message(minitest { assert_sms_sent(fake, to: "+61411111111") })).to eq(<<~MESSAGE.chomp)
        expected exactly 1 SMS matching to: "+61411111111" to have been sent, but 2 matched.
        2 SMS sent:
          1. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
          2. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
      MESSAGE
    end

    it "fails when nothing matches" do
      fake = self.fake

      expect(failure_message(minitest { assert_sms_sent(fake, body: /code/) })).to eq(<<~MESSAGE.chomp)
        expected exactly 1 SMS matching body: /code/ to have been sent, but 0 matched.
        No SMS was sent.
      MESSAGE
    end

    it "takes count:" do
      3.times { deliver }
      fake = self.fake

      expect(minitest { assert_sms_sent(fake, custom_string: "otp:42", count: 3) }).to be_passed
      expect(minitest { assert_sms_sent(fake, to: "+61499999999", count: 0) }).to be_passed
      expect(failure_message(minitest { assert_sms_sent(fake, count: 2) })).to start_with("expected exactly 2 SMS to have been sent, but 3 matched.")
    end

    it "lists at most 10 messages" do
      11.times { deliver }
      fake = self.fake

      lines = failure_message(minitest { assert_no_sms_sent(fake) }).lines(chomp: true)
      expect(lines.size).to eq(1 + 1 + 10 + 1)
      expect(lines.last).to eq("  ... and 1 more")
    end

    it "reports misuse as an error, not a failed assertion" do
      fake = self.fake

      [
        [-> { assert_sms_sent(fake, phone: "+61411111111") }, /assert_sms_sent: unknown attribute :phone/],
        [-> { assert_sms_sent(fake, count: -1) }, /assert_sms_sent: the count must be a non-negative Integer/],
        [-> { assert_sms_sent(fake.client, to: "+61411111111") }, /assert_sms_sent expects a Clicksend::Testing::FakeAPI/],
        [-> { assert_no_sms_sent(fake.sent_messages) }, /assert_no_sms_sent expects a Clicksend::Testing::FakeAPI/]
      ].each do |call, message|
        result = minitest { instance_exec(&call) }
        expect(result.failures.first).to be_a(Minitest::UnexpectedError)
        expect(result.failures.first.error).to be_a(ArgumentError)
        expect(result.failures.first.error.message).to match(message)
      end
    end
  end

  describe "#assert_no_sms_sent" do
    it "passes when nothing was sent" do
      fake = self.fake
      result = minitest { assert_no_sms_sent(fake) }

      expect(result).to be_passed
      expect(result.assertions).to eq(1)
    end

    it "fails listing what was sent" do
      deliver
      fake = self.fake

      expect(failure_message(minitest { assert_no_sms_sent(fake) })).to eq(<<~MESSAGE.chomp)
        expected no SMS to have been sent, but 1 matched.
        1 SMS sent:
          1. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
      MESSAGE
    end

    it "with attributes, passes when none of the sent messages matches them, however many would" do
      2.times { deliver }
      fake = self.fake

      expect(minitest { assert_no_sms_sent(fake, to: "+61422222222") }).to be_passed
      expect(failure_message(minitest { assert_no_sms_sent(fake, to: "+61411111111") })).to start_with(
        %(expected no SMS matching to: "+61411111111" to have been sent, but 2 matched.)
      )
    end
  end
end
