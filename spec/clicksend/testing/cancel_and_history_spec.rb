# frozen_string_literal: true

require "clicksend/testing"

RSpec.describe Clicksend::Testing::FakeAPI, "cancelling and history" do
  let(:now) { Time.utc(2026, 10, 6, 12) }
  let(:fake) { described_class.new(clock: -> { now }) }
  let(:client) { fake.client }

  def scheduled(at = now + 3600, **options)
    client.sms.deliver(to: "+61411111111", body: "Reminder", schedule: at, **options)
  end

  describe "PUT /v3/sms/{message_id}/cancel" do
    it "cancels a message scheduled for the future, which stays among the sent messages" do
      message = scheduled

      expect(client.sms.cancel(message.message_id)).to be_nil
      expect(fake.cancelled_messages.map(&:message_id)).to eq([message.message_id])
      expect(fake.sent_messages.map(&:message_id)).to eq([message.message_id])
      expect(fake.requests.last).to have_attributes(http_method: :put, path: "/v3/sms/#{message.message_id}/cancel", body: nil)
    end

    it "won't guess ClickSend's undocumented answers: a second cancel, a sent message or an unknown ID" do
      message = scheduled
      client.sms.cancel(message.message_id)
      immediate = client.sms.deliver(to: "+61411111111", body: "Now")
      past = scheduled(now - 1)

      [message.message_id, immediate.message_id, past.message_id, "UNKNOWN-ID"].each do |id|
        expect { client.sms.cancel(id) }.to raise_error(Clicksend::Testing::StubError, %r{stub PUT /v3/sms/#{id}/cancel})
      end
      expect(fake.cancelled_messages.size).to eq(1)
    end

    it "lets a test state the undocumented answer with a stub" do
      message = client.sms.deliver(to: "+61411111111", body: "Now")
      fake.stub(:put, "/v3/sms/#{message.message_id}/cancel") do
        {"http_code" => 400, "response_code" => "BAD_REQUEST", "response_msg" => "Assumed by this test.", "data" => nil}
      end

      expect { client.sms.cancel(message.message_id) }.to raise_error(Clicksend::BadRequestError)
    end

    it "simulates an ambiguous cancel that ClickSend did process" do
      message = scheduled
      fake.fail_next(:timeout, processed: true, method: :put)

      expect { client.sms.cancel(message.message_id) }.to raise_error(Clicksend::AmbiguousRequestError)
      expect(fake.cancelled_messages.map(&:message_id)).to eq([message.message_id])
      expect(fake.requests.size).to eq(2) # the send and one cancel: not retried
    end

    it "simulates an ambiguous cancel that ClickSend did not process" do
      message = scheduled
      fake.fail_next(status: 500, processed: false, method: :put)

      expect { client.sms.cancel(message.message_id) }.to raise_error(Clicksend::ServerError) { |e| expect(e).to be_ambiguous }
      expect(fake.cancelled_messages).to be_empty
    end

    it "forgets cancellations on reset!" do
      client.sms.cancel(scheduled.message_id)
      fake.reset!
      expect(fake.cancelled_messages).to be_empty
      expect(fake.cancelled_messages).to be_frozen
    end
  end

  describe "#stub_history" do
    it "still answers 404 to history until a test says what it shows" do
      scheduled
      expect { client.sms.history }.to raise_error(Clicksend::NotFoundError)
    end

    it "shows nothing when given nothing" do
      scheduled
      fake.stub_history

      expect(client.sms.history.to_a).to eq([])
      expect(client.sms.search_history(to: "+61411111111", custom_string: "r:1", sent_after: now - 60)).to eq([])
    end

    it "shows exactly the given messages, in history's live shape, whatever the query" do
      first = scheduled(custom_string: "r:1")
      client.sms.deliver(to: "+61422222222", body: "Other", custom_string: "r:2")
      fake.stub_history(*fake.sent_messages, status: "Scheduled")

      records = client.sms.history(to: "+61499999999", date_from: now + 86_400).to_a
      expect(records.map(&:message_id)).to eq(fake.sent_messages.map(&:message_id))
      expect(records.first).to have_attributes(
        direction: "out", status: "Scheduled", status_code: nil, to: "+61411111111", body: "Reminder", custom_string: "r:1",
        sent_at: now, scheduled_at: now + 3600, parts: 1, price: "0.0000"
      )
      expect(records.first).to be_pending
      expect(client.sms.search_history(to: "+61411111111", custom_string: "r:1", sent_after: now).map(&:message_id)).to eq([first.message_id])
    end

    it "pages like ClickSend and can be changed during a scenario" do
      16.times { |i| client.sms.deliver(to: "+61411111111", body: "Hi #{i}", custom_string: "bulk") }
      fake.stub_history(*fake.sent_messages)

      page = client.sms.history
      expect([page.count, page.last_page]).to eq([15, 2])
      expect(client.sms.search_history(to: "+61411111111", custom_string: "bulk", sent_after: now).size).to eq(16)

      fake.stub_history(fake.sent_messages.first, status: "Cancelled")
      expect(client.sms.history.map(&:status)).to eq(["Cancelled"])
    end

    it "validates its arguments" do
      expect { fake.stub_history({"to" => "+61411111111"}) }.to raise_error(ArgumentError, /SentMessage/)
      message = client.sms.deliver(to: "+61411111111", body: "Hi")
      expect { fake.stub_history(message) }.to raise_error(ArgumentError, /SentMessage/)
      expect { fake.stub_history(fake.sent_messages.last, status: "Received") }.to raise_error(ArgumentError, /status must be one of/)
      expect { fake.stub_history(status: "Delivered") }.to raise_error(ArgumentError, /status must be one of/)
    end
  end
end
