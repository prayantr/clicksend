# frozen_string_literal: true

require "clicksend/testing"

RSpec.describe Clicksend::Testing::FakeAPI, "receipts and inbound" do
  let(:now) { Time.utc(2026, 10, 6, 9, 0, 0) }
  let(:fake) { described_class.new(clock: -> { now }) }
  let(:client) { fake.client }
  let(:sent) do
    client.sms.deliver(to: "+61411111111", body: "Your code", from: "+61422222222", custom_string: "otp:42")
    fake.sent_messages.last
  end

  describe "#add_receipt" do
    it "returns the Receipt the API serves, with ClickSend's poll schema" do
      seeded = fake.add_receipt(message_id: "ABC-1", status_code: 301, error_code: 3, error_text: "Expired",
        custom_string: "ref", timestamp: now, timestamp_send: now - 60)

      expect(seeded).to be_a(Clicksend::SMS::Receipt).and(be_failed)
      expect(seeded).to have_attributes(message_id: "ABC-1", status_code: 301, status_text: "Failed", error_code: 3,
        error_text: "Expired", custom_string: "ref", message_type: "sms", reported_at: now, sent_at: now - 60)
      expect(seeded.raw.keys).to eq(%w[timestamp_send timestamp message_id status_code status_text error_code error_text custom_string subaccount_id message_type])
      expect(seeded.raw["status_code"]).to eq(301)
      expect(client.sms.receipt("ABC-1")).to eq(seeded)
      expect(client.sms.receipts.to_a).to eq([seeded])
    end

    it "takes message_id, custom_string and send time from for: a SentMessage" do
      receipt = fake.add_receipt(for: sent, timestamp: now + 5)

      expect(receipt).to have_attributes(message_id: sent.message_id, custom_string: "otp:42", status_code: 201,
        status_text: "Delivered", sent_at: now, reported_at: now + 5)
      expect(receipt).to be_delivered
      expect(fake.add_receipt(for: sent, custom_string: "other").custom_string).to eq("other")
    end

    it "defaults both timestamps to the clock" do
      expect(fake.add_receipt(message_id: "ABC-1")).to have_attributes(sent_at: now, reported_at: now)
      expect(fake.add_receipt(message_id: "ABC-1", timestamp: 1_000).sent_at).to eq(Time.at(1_000).utc)
    end

    it "validates its arguments" do
      expect { fake.add_receipt }.to raise_error(ArgumentError, /message_id must be/)
      expect { fake.add_receipt(message_id: "../x") }.to raise_error(ArgumentError, /message_id must be/)
      expect { fake.add_receipt(message_id: "A", for: sent) }.to raise_error(ArgumentError, /not both/)
      expect { fake.add_receipt(for: "A") }.to raise_error(ArgumentError, /for: must be a Clicksend::Testing::SentMessage/)
      expect { fake.add_receipt(message_id: "A", status_code: "201") }.to raise_error(ArgumentError, /status_code/)
      expect { fake.add_receipt(message_id: "A", error_code: "3") }.to raise_error(ArgumentError, /error_code/)
      expect { fake.add_receipt(message_id: "A", status_text: :ok) }.to raise_error(ArgumentError, /status_text must be a String/)
      expect { fake.add_receipt(message_id: "A", timestamp: "now") }.to raise_error(ArgumentError, /timestamp must be a Time/)
    end
  end

  describe "listing receipts" do
    it "pages through unread receipts with ClickSend's pagination envelope" do
      40.times { |i| fake.add_receipt(message_id: "MSG-#{i}") }

      first = client.sms.receipts
      expect(first).to have_attributes(total: 40, per_page: 15, current_page: 1, last_page: 3, size: 15)
      expect(first.next_page.map(&:message_id)).to eq((15..29).map { |i| "MSG-#{i}" })
      expect(client.sms.receipts(page: 3).size).to eq(10)
      expect(client.sms.receipts.auto_paging_each.map(&:message_id)).to eq((0..39).map { |i| "MSG-#{i}" })
      expect(client.sms.receipts(limit: 100).last_page).to eq(1)

      body = client.request(:get, "/v3/sms/receipts", query: {page: 2}).data
      expect(body.except("data")).to eq(
        "total" => 40, "per_page" => 15, "current_page" => 2, "last_page" => 3, "from" => 16, "to" => 30,
        "next_page_url" => "https://rest.clicksend.com/v3/sms/receipts?page=3",
        "prev_page_url" => "https://rest.clicksend.com/v3/sms/receipts?page=1"
      )
    end

    it "answers an empty list with last_page 0, as ClickSend does" do
      page = client.sms.receipts

      expect(page).to have_attributes(total: 0, current_page: 1, last_page: 0)
      expect(page).to be_empty
      expect(page.next_page).to be_nil
    end

    it "clamps an out-of-range limit (reachable only through client.request)" do
      20.times { |i| fake.add_receipt(message_id: "MSG-#{i}") }

      expect(client.request(:get, "/v3/sms/receipts", query: {limit: 5}).data["per_page"]).to eq(15)
      expect(client.request(:get, "/v3/sms/receipts", query: {limit: 500}).data["per_page"]).to eq(100)
      expect(client.request(:get, "/v3/sms/receipts", query: {page: 0}).data["current_page"]).to eq(1)
    end

    it "serves one receipt, read or not, and the newest one for a message" do
      fake.add_receipt(for: sent, status_code: 200)
      fake.add_receipt(for: sent, status_code: 201)
      client.sms.mark_receipts_read

      expect(client.sms.receipts).to be_empty
      expect(client.sms.receipt(sent.message_id).status_code).to eq(201)
    end

    it "answers 404 with ClickSend's live body for an unknown receipt" do
      expect { client.sms.receipt("31BC271B-1E0C-45F6-9E7E-97186C46BB82") }.to raise_error(Clicksend::NotFoundError) { |error|
        expect(error.body).to eq({"http_code" => 404, "response_code" => "NOT_FOUND", "response_msg" => "Receipt record not found.", "data" => nil})
      }
    end
  end

  describe "marking receipts read" do
    before do
      fake.add_receipt(message_id: "OLD", timestamp: 100)
      fake.add_receipt(message_id: "EDGE", timestamp: 200)
      fake.add_receipt(message_id: "NEW", timestamp: 300)
    end

    it "marks only receipts strictly before the cutoff" do
      expect(client.sms.mark_receipts_read(before: 200)).to be_nil

      expect(client.sms.receipts.map(&:message_id)).to eq(%w[EDGE NEW])
      expect(fake.requests.find { |r| r.http_method == :put }.body).to eq({"date_before" => 200})
    end

    it "marks every unread receipt without a cutoff" do
      client.sms.mark_receipts_read

      expect(client.sms.receipts).to be_empty
      expect(fake.requests.find { |r| r.http_method == :put }.body).to eq({})
    end

    it "lists receipts added after marking" do
      client.sms.mark_receipts_read
      fake.add_receipt(message_id: "LATER", timestamp: 50)

      expect(client.sms.receipts.map(&:message_id)).to eq(["LATER"])
    end

    it "answers 400 to a non-integer cutoff (reachable only through client.request)" do
      expect { client.request(:put, "/v3/sms/receipts-read", body: {date_before: "soon"}) }.to raise_error(Clicksend::BadRequestError)
      expect(client.sms.receipts.size).to eq(3)
    end
  end

  describe "#add_inbound" do
    it "returns the InboundMessage the API serves, with ClickSend's poll schema" do
      seeded = fake.add_inbound(from: "+61433333333", body: "Hello", to: "+61422222222", timestamp: now - 10)

      expect(seeded).to have_attributes(from: "+61433333333", body: "Hello", to: "+61422222222", received_at: now - 10,
        original_message_id: nil, original_body: nil, custom_string: "")
      expect(seeded.message_id).to match(/\A[0-9A-F-]{36}\z/)
      expect(seeded.raw.keys).to eq(%w[timestamp from body original_body original_message_id to custom_string message_id])
      expect(client.sms.inbound.to_a).to eq([seeded])
    end

    it "builds a reply to a SentMessage with reply_to:" do
      reply = fake.add_inbound(reply_to: sent, body: "STOP")

      expect(reply).to have_attributes(from: "+61411111111", to: "+61422222222", original_message_id: sent.message_id,
        original_body: "Your code", custom_string: "otp:42", received_at: now)
      expect(fake.add_inbound(reply_to: sent, from: "+61499999999", body: "x").from).to eq("+61499999999")
    end

    it "validates its arguments" do
      expect { fake.add_inbound(body: "Hi") }.to raise_error(ArgumentError, /from must be/)
      expect { fake.add_inbound(from: "+61411111111", body: nil) }.to raise_error(ArgumentError, /body must be/)
      expect { fake.add_inbound(from: "+61411111111") }.to raise_error(ArgumentError, /missing keyword: :body/)
      expect { fake.add_inbound(reply_to: {to: "+61411111111"}, body: "x") }.to raise_error(ArgumentError, /reply_to: must be/)
      expect { fake.add_inbound(from: "+61411111111", body: "x", to: 61) }.to raise_error(ArgumentError, /to must be a String/)
      expect { fake.add_inbound(from: "+61411111111", body: "x", timestamp: 1.5) }.to raise_error(ArgumentError, /timestamp/)

      list_message = fake.client.sms.deliver_batch([{list_id: 1, body: "x"}]) && fake.sent_messages.last
      expect { fake.add_inbound(reply_to: list_message, body: "x") }.to raise_error(ArgumentError, /from must be/)
    end
  end

  describe "listing and marking inbound" do
    before do
      fake.add_inbound(from: "+61411111111", body: "a", timestamp: 100)
      fake.add_inbound(from: "+61411111111", body: "b", timestamp: 200)
      fake.add_inbound(from: "+61411111111", body: "c", timestamp: 300)
    end

    it "lists unread inbound messages with pagination" do
      page = client.sms.inbound

      expect(page.map(&:body)).to eq(%w[a b c])
      expect(page).to have_attributes(total: 3, last_page: 1)
    end

    it "marks inbound read before a cutoff, or all" do
      client.sms.mark_inbound_read(before: 300)
      expect(client.sms.inbound.map(&:body)).to eq(%w[c])

      client.sms.mark_inbound_read
      expect(client.sms.inbound).to be_empty
    end

    it "marks one inbound message read and answers the count marked" do
      target = client.sms.inbound.to_a[1]

      expect(client.sms.mark_inbound_message_read(target.message_id)).to be_nil
      expect(client.sms.inbound.map(&:body)).to eq(%w[a c])

      response = client.request(:put, "/v3/sms/inbound-read/#{target.message_id}")
      expect(response.data).to eq(0)
      expect(client.request(:put, "/v3/sms/inbound-read/#{client.sms.inbound.first.message_id}").data).to eq(1)
    end
  end
end
