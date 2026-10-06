# frozen_string_literal: true

require "clicksend/testing/rspec"

RSpec.describe Clicksend::Testing::RSpecMatchers do
  let(:fake) { Clicksend::Testing::FakeAPI.new }

  def deliver(to: "+61411111111", body: "Your code is 481516", custom_string: "otp:42", **options)
    fake.client.sms.deliver(to: to, body: body, custom_string: custom_string, **options)
  end

  # The message of the expectation failure the block raises.
  def failure_of
    yield
  rescue RSpec::Expectations::ExpectationNotMetError => e
    e.message
  else
    raise "expected the expectation to fail, but it passed"
  end

  it "is included in every example group by the require" do
    expect(self).to be_a(described_class)
  end

  describe "have_sent_sms" do
    it "passes when exactly one sent message matches every given attribute" do
      deliver
      deliver(to: "+61422222222", custom_string: "otp:43")

      expect(fake).to have_sent_sms(to: "+61411111111", body: "Your code is 481516", custom_string: "otp:42")
      expect(fake).to have_sent_sms(custom_string: "otp:43")
    end

    it "matches with ===: Regexps, Ranges, classes, procs and composable matchers" do
      deliver(schedule: Time.now + 3600)

      expect(fake).to have_sent_sms(body: /481516/, to: String, custom_string: ->(value) { value.start_with?("otp:") })
      expect(fake).to have_sent_sms(body: a_string_including("481516"), scheduled_at: (Time.now..Time.now + 7200))
      expect(fake).not_to have_sent_sms(body: /999999/)
    end

    it "with no attributes, expects exactly one SMS" do
      expect(fake).not_to have_sent_sms
      deliver
      expect(fake).to have_sent_sms
    end

    it "fails on a second matching message by default: a duplicate is the bug" do
      2.times { deliver }

      expect(failure_of { expect(fake).to have_sent_sms(to: "+61411111111") }).to eq(<<~MESSAGE.chomp)
        expected exactly 1 SMS matching to: "+61411111111" to have been sent, but 2 matched.
        2 SMS sent:
          1. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
          2. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
      MESSAGE
    end

    it "fails listing what was sent, or saying nothing was" do
      expect(failure_of { expect(fake).to have_sent_sms(to: "+61411111111", body: /code/) }).to eq(<<~MESSAGE.chomp)
        expected exactly 1 SMS matching to: "+61411111111", body: /code/ to have been sent, but 0 matched.
        No SMS was sent.
      MESSAGE

      deliver(to: "+61422222222")
      message = failure_of { expect(fake).to have_sent_sms(to: "+61411111111", body: a_string_including("code")) }
      expect(message).to start_with(%(expected exactly 1 SMS matching to: "+61411111111", body: a string including "code" to have been sent, but 0 matched.\n1 SMS sent:\n))
      expect(message).to end_with(%(  1. to: "+61422222222", custom_string: "otp:42", body: "Your code is 481516"))
    end

    it "takes .once, .twice, .times(n) and .exactly(n).times" do
      expect(fake).to have_sent_sms.exactly(0).times
      deliver
      expect(fake).to have_sent_sms(to: "+61411111111").once
      deliver
      expect(fake).to have_sent_sms(to: "+61411111111").twice
      deliver
      expect(fake).to have_sent_sms(custom_string: "otp:42").times(3)
      expect(fake).to have_sent_sms(custom_string: "otp:42").exactly(3).times

      expect(failure_of { expect(fake).to have_sent_sms.twice }).to start_with("expected exactly 2 SMS to have been sent, but 3 matched.")
    end

    it "counts only accepted messages: rejected recipients were not sent" do
      fake.reject(to: "+61400000000", status: "INVALID_RECIPIENT")
      expect { deliver(to: "+61400000000") }.to raise_error(Clicksend::MessageRejected)

      expect(fake).not_to have_sent_sms(to: "+61400000000")
    end

    it "composes" do
      deliver
      deliver(to: "+61422222222")

      expect(fake).to have_sent_sms(to: "+61411111111").and have_sent_sms(to: "+61422222222")
    end

    it "describes itself" do
      expect(have_sent_sms(to: "+61411111111", body: /code/).description).to eq(%(have sent exactly 1 SMS matching to: "+61411111111", body: /code/))
      expect(have_sent_sms.twice.description).to eq("have sent exactly 2 SMS")
      expect(have_sent_no_sms.description).to eq("have sent no SMS")
    end

    it "rejects unknown attributes, bad counts and anything but a FakeAPI" do
      expect { have_sent_sms(phone: "+61411111111") }.to raise_error(ArgumentError, /unknown attribute :phone; use message_id, to, from, body/)
      expect { have_sent_sms(phone: 1, text: 2) }.to raise_error(ArgumentError, /unknown attributes :phone, :text/)
      expect { have_sent_sms.times(-1) }.to raise_error(ArgumentError, /non-negative Integer/)
      expect { have_sent_sms.exactly("2").times }.to raise_error(ArgumentError, /non-negative Integer/)
      expect { have_sent_sms.times }.to raise_error(ArgumentError, /times\(n\)/)
      expect { expect(fake.client).to have_sent_sms }.to raise_error(ArgumentError, /expects a Clicksend::Testing::FakeAPI .*got Clicksend::Client/)
      expect { expect(fake.sent_messages).to have_sent_sms }.to raise_error(ArgumentError, /not fake.client or fake.sent_messages/)
    end
  end

  describe "not_to have_sent_sms" do
    it "passes when no sent message matches" do
      deliver(to: "+61422222222")

      expect(fake).not_to have_sent_sms(to: "+61411111111")
    end

    it "fails when any message matches, however many: never just 'not exactly one'" do
      2.times { deliver }

      expect(failure_of { expect(fake).not_to have_sent_sms(custom_string: "otp:42") }).to eq(<<~MESSAGE.chomp)
        expected no SMS matching custom_string: "otp:42" to have been sent, but 2 matched.
        2 SMS sent:
          1. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
          2. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
      MESSAGE
    end

    it "refuses a count, which would make the negation ambiguous" do
      expect { expect(fake).not_to have_sent_sms.once }.to raise_error(ArgumentError, /with a count can't be negated/)
      expect { expect(fake).not_to have_sent_no_sms }.to raise_error(ArgumentError, /have_sent_no_sms can't be negated/)
    end
  end

  describe "have_sent_no_sms" do
    it "passes when nothing was sent" do
      expect(fake).to have_sent_no_sms
    end

    it "fails listing what was sent" do
      deliver

      expect(failure_of { expect(fake).to have_sent_no_sms }).to eq(<<~MESSAGE.chomp)
        expected no SMS to have been sent, but 1 matched.
        1 SMS sent:
          1. to: "+61411111111", custom_string: "otp:42", body: "Your code is 481516"
      MESSAGE
    end

    it "with attributes, passes when none of the sent messages matches them" do
      deliver

      expect(fake).to have_sent_no_sms(to: "+61422222222")
      expect(failure_of { expect(fake).to have_sent_no_sms(to: "+61411111111") }).to start_with(
        %(expected no SMS matching to: "+61411111111" to have been sent, but 1 matched.)
      )
    end

    it "takes no count" do
      expect { have_sent_no_sms.once }.to raise_error(ArgumentError, /have_sent_no_sms takes no count/)
    end
  end

  describe "failure output" do
    it "lists at most 10 messages, one line each, and cuts long values" do
      12.times { |i| deliver(to: "+614111111#{format("%02d", i)}", body: "Your code is 481516. #{"x" * 100}") }

      lines = failure_of { expect(fake).to have_sent_no_sms }.lines(chomp: true)
      expect(lines.size).to eq(1 + 1 + 10 + 1)
      expect(lines[1]).to eq("12 SMS sent:")
      expect(lines[2]).to eq(%(  1. to: "+61411111100", custom_string: "otp:42", body: "Your code is 481516. #{"x" * 39}"...))
      expect(lines[11]).to start_with(%(  10. to: "+61411111109"))
      expect(lines.last).to eq("  ... and 2 more")
    end

    it "shows list_id for a list message, and the other attributes the expectation names" do
      fake.client.sms.deliver_batch([{list_id: 428, body: "Hi", from: "Acme"}])

      message = failure_of { expect(fake).to have_sent_sms(from: "Other", country: "AU") }
      expect(message.lines.last).to eq(%(  1. list_id: 428, custom_string: nil, body: "Hi", from: "Acme", country: nil))
    end
  end
end
