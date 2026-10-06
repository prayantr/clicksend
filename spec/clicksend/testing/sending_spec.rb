# frozen_string_literal: true

require "clicksend/testing"

RSpec.describe Clicksend::Testing::FakeAPI, "sending" do
  let(:now) { Time.utc(2026, 10, 6, 9, 0, 0) }
  let(:fake) { described_class.new(clock: -> { now }) }
  let(:sms) { fake.client.sms }

  describe "#deliver" do
    it "accepts the message, returns ClickSend's accepted shape and records a SentMessage" do
      message = sms.deliver(to: "+61411111111", body: "Hi", from: "Acme", custom_string: "otp:42", country: "AU")

      expect(message).to be_queued
      expect(message).to have_attributes(
        status: "SUCCESS", to: "+61411111111", from: "Acme", body: "Hi", custom_string: "otp:42", country: "AU",
        parts: 1, price: "0.0000", sent_at: now, scheduled_at: now
      )
      expect(message.message_id).to match(/\A[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\z/)
      expect(message.raw.keys).to eq(%w[
        direction date to body from schedule message_id message_parts message_price from_email list_id
        custom_string contact_id user_id subaccount_id is_shared_system_number country carrier status
      ])
      expect(message.raw["date"]).to eq(now.to_i)

      expect(fake.sent_messages).to eq([Clicksend::Testing::SentMessage.new(
        message_id: message.message_id, to: "+61411111111", from: "Acme", body: "Hi", custom_string: "otp:42",
        list_id: nil, schedule: nil, country: "AU", sent_at: now
      )])
      expect(fake.sent_messages.first.sent_at).to be_utc
    end

    it "records the request with its parsed JSON body" do
      sms.deliver(to: "+61411111111", body: "Hi")

      expect(fake.requests.size).to eq(1)
      request = fake.requests.first
      expect(request).to have_attributes(method: :post, path: "/v3/sms/send", query: {})
      expect(request.body).to eq({"messages" => [{"to" => "+61411111111", "body" => "Hi"}]})
      expect(request.body).to be_frozen
    end

    it "keeps a scheduled time" do
      at = now + 3600
      message = sms.deliver(to: "+61411111111", body: "Later", schedule: at)

      expect(message.scheduled_at).to eq(at)
      expect(fake.sent_messages.first.schedule).to eq(at.to_i)
    end

    it "prices each part with message_price (parts estimated at 160 characters)" do
      fake = described_class.new(message_price: "0.0792")
      message = fake.client.sms.deliver(to: "+61411111111", body: "x" * 161)

      expect(message).to have_attributes(parts: 2, price: "0.1584")
    end

    it "raises MessageRejected for a rejected recipient and records nothing as sent" do
      fake.reject(to: "+61400000000", status: "INVALID_RECIPIENT")

      expect { sms.deliver(to: "+61400000000", body: "Hi", custom_string: "x") }.to raise_error(Clicksend::MessageRejected) { |error|
        expect(error.status).to eq("INVALID_RECIPIENT")
        expect(error.result.raw.keys).to eq(%w[to body from schedule message_id custom_string is_shared_system_number status])
        expect(error.result.raw["schedule"]).to eq("")
        expect(error.result.message_id).to match(/\A[0-9A-F-]{36}\z/)
      }
      expect(fake.sent_messages).to be_empty
      expect(sms.deliver(to: "+61411111111", body: "Hi")).to be_queued
    end

    it "rejects every message with a rule that has no recipient" do
      fake.reject(status: "INSUFFICIENT_CREDIT")

      expect { sms.deliver(to: "+61411111111", body: "Hi") }
        .to raise_error(Clicksend::MessageRejected, /INSUFFICIENT_CREDIT/)
    end

    it "applies the most recent matching rule" do
      fake.reject(status: "INSUFFICIENT_CREDIT")
      fake.reject(to: "+61411111111", status: "INVALID_RECIPIENT")
      fake.reject(to: "+61422222222", status: "INVALID_RECIPIENT")
      fake.reject(to: "+61422222222", status: "COUNTRY_NOT_ENABLED")

      statuses = sms.deliver_batch(%w[+61411111111 +61422222222 +61433333333].map { |to| {to: to, body: "Hi"} }).map(&:status)
      expect(statuses).to eq(%w[INVALID_RECIPIENT COUNTRY_NOT_ENABLED INSUFFICIENT_CREDIT])

      fake.reject(status: "THROTTLED")
      expect { sms.deliver(to: "+61411111111", body: "Hi") }.to raise_error(Clicksend::MessageRejected, /THROTTLED/)
    end
  end

  describe "#deliver_batch" do
    it "reports accepted and rejected messages with ClickSend's counts" do
      fake = described_class.new(message_price: "0.0792", currency: "USD")
      fake.reject(to: "+61400000000", status: "INVALID_RECIPIENT")
      fake.reject(to: "+14055555555", status: "COUNTRY_NOT_ENABLED")

      batch = fake.client.sms.deliver_batch(
        [{to: "+61411111111", body: "Hi", custom_string: "a"}, {to: "+61400000000", body: "Hi", custom_string: "b"},
          {to: "+14055555555", body: "Hi", custom_string: "c"}, {to: "+61422222222", body: "Hi", custom_string: "d"}]
      )

      expect(batch).to have_attributes(total_count: 4, queued_count: 2, blocked_count: 1, total_price: "0.1584", currency: "USD")
      expect(batch.queued.map(&:custom_string)).to eq(%w[a d])
      expect(batch.rejected.map(&:status)).to eq(%w[INVALID_RECIPIENT COUNTRY_NOT_ENABLED])
      expect(batch).not_to be_all_queued
      expect(fake.sent_messages.map(&:custom_string)).to eq(%w[a d])
      expect(batch.map(&:message_id).uniq.size).to eq(4)
    end

    it "reports a whole total_price as an integer, as ClickSend does" do
      batch = sms.deliver_batch([{to: "+61411111111", body: "Hi"}])

      expect(batch.raw["total_price"]).to eq(0)
      expect(batch).to be_all_queued
    end

    it "accepts a message to a contact list, with no recipient" do
      batch = sms.deliver_batch([{list_id: 428, body: "Hi all"}])

      expect(batch.first).to have_attributes(status: "SUCCESS", to: nil, list_id: "428")
      expect(fake.sent_messages.first).to have_attributes(to: nil, list_id: 428, body: "Hi all")
    end

    it "does not apply recipient rules to list messages, but does apply catch-all rules" do
      fake.reject(to: "+61411111111", status: "INVALID_RECIPIENT")
      expect(sms.deliver_batch([{list_id: 1, body: "Hi"}]).first).to be_queued

      fake.reject(status: "INSUFFICIENT_CREDIT")
      expect(sms.deliver_batch([{list_id: 1, body: "Hi"}]).first.status).to eq("INSUFFICIENT_CREDIT")
    end
  end

  it "answers 400 to a send without valid messages (reachable only through client.request)" do
    expect { fake.client.request(:post, "/v3/sms/send", body: {messages: [{to: "+61411111111"}]}) }
      .to raise_error(Clicksend::BadRequestError) { |e| expect(e.response_code).to eq("MISSING_REQUIRED_FIELDS") }
    expect { fake.client.request(:post, "/v3/sms/send", body: {}) }.to raise_error(Clicksend::BadRequestError)
    expect(fake.sent_messages).to be_empty
  end

  describe "#reject arguments" do
    it "validates the status and recipient" do
      expect { fake.reject(status: "SUCCESS") }.to raise_error(ArgumentError, /per-message status/)
      expect { fake.reject(status: "invalid") }.to raise_error(ArgumentError, /per-message status/)
      expect { fake.reject(status: :INVALID_RECIPIENT) }.to raise_error(ArgumentError, /per-message status/)
      expect { fake.reject(to: 61_400_000_000, status: "INVALID_RECIPIENT") }.to raise_error(ArgumentError, /to must be/)
      expect { fake.reject(to: "+61400000000") }.to raise_error(ArgumentError, /missing keyword: :status/)
    end

    it "returns the fake for chaining" do
      expect(fake.reject(status: "THROTTLED")).to be(fake)
    end
  end
end
