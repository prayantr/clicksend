# frozen_string_literal: true

RSpec.describe Clicksend::Resources::SMS, "receipts and replies" do
  def receipt_payload(message_id, status_code)
    {"timestamp_send" => 1_722_565_661, "timestamp" => 1_722_565_700, "message_id" => message_id, "status_code" => status_code,
     "status_text" => "x", "error_code" => nil, "error_text" => nil, "custom_string" => nil, "subaccount_id" => 1, "message_type" => "sms"}
  end

  def paginated(items, current: 1, last: 1)
    envelope({"total" => items.size, "per_page" => 15, "current_page" => current, "last_page" => last, "data" => items})
  end

  describe "#receipts" do
    it "lists unread receipts (ClickSend's documented example)" do
      stub_api(:get, "/v3/sms/receipts", query: {}).to_return(json_response(fixture("sms_receipts")))

      page = client.sms.receipts
      receipt = page.first

      expect(page.size).to eq(1)
      expect(receipt).to be_a(Clicksend::SMS::Receipt)
      expect(receipt).to have_attributes(
        message_id: "D6D16B28-46AC-484A-AB0A-A08CD08EF75C", status_code: 201, # documented as integer, example sends "201"
        status_text: "Success: Message received on handset.", error_code: nil, message_type: "sms",
        subaccount_id: 123_456, sent_at: Time.at(1_722_565_661).utc, reported_at: Time.at(1_722_565_661).utc
      )
      expect(receipt).to be_delivered
      expect(receipt).not_to be_failed
      expect(receipt).not_to be_pending
    end

    it "passes page and limit and walks further pages with typed items" do
      stub_api(:get, "/v3/sms/receipts", query: {"page" => "1", "limit" => "100"})
        .to_return(json_response(paginated([receipt_payload("A", 201)], last: 2)))
      stub_api(:get, "/v3/sms/receipts", query: {"page" => "2", "limit" => "100"})
        .to_return(json_response(paginated([receipt_payload("B", 301)], current: 2, last: 2)))

      receipts = client.sms.receipts(page: 1, limit: 100).auto_paging_each.to_a

      expect(receipts.map(&:message_id)).to eq(%w[A B])
      expect(receipts.map(&:failed?)).to eq([false, true])
    end

    it "classifies documented gateway status codes" do
      {200 => :pending?, 201 => :delivered?, 300 => :pending?, 301 => :failed?}.each do |code, predicate|
        receipt = Clicksend::SMS::Receipt.from_api(receipt_payload("X", code))
        expect(receipt.public_send(predicate)).to be(true), "#{code} should be #{predicate}"
      end
      unknown = Clicksend::SMS::Receipt.from_api(receipt_payload("X", 999))
      expect([unknown.delivered?, unknown.failed?, unknown.pending?]).to eq([false, false, false])
    end

    it "raises MalformedResponseError for items that are not objects" do
      stub_api(:get, "/v3/sms/receipts", query: {}).to_return(json_response(paginated(["oops"])))
      expect { client.sms.receipts }.to raise_error(Clicksend::MalformedResponseError, /receipt to be a JSON object/)
    end
  end

  describe "#receipt" do
    it "fetches one receipt by message ID (ClickSend's documented example)" do
      stub_api(:get, "/v3/sms/receipts/D6D16B28-46AC-484A-AB0A-A08CD08EF75C").to_return(json_response(fixture("sms_receipt")))
      expect(client.sms.receipt("D6D16B28-46AC-484A-AB0A-A08CD08EF75C")).to be_delivered
    end

    it "refuses IDs that could change the request path" do
      ["../account", "A/B", "", nil, "A B"].each do |id|
        expect { client.sms.receipt(id) }.to raise_error(ArgumentError, /message_id must be/), id.inspect
      end
    end

    it "raises NotFoundError for an unknown ID" do
      stub_api(:get, "/v3/sms/receipts/NOPE").to_return(json_response(envelope(nil, http_code: 404, response_code: "NOT_FOUND"), status: 404))
      expect { client.sms.receipt("NOPE") }.to raise_error(Clicksend::NotFoundError)
    end
  end

  describe "#mark_receipts_read" do
    it "marks all receipts read" do
      stub = stub_api(:put, "/v3/sms/receipts-read", body: {}).to_return(json_response(fixture("sms_receipts_read")))
      expect(client.sms.mark_receipts_read).to be_nil
      expect(stub).to have_been_requested
    end

    it "marks receipts before a time read, sending a Unix timestamp" do
      stub = stub_api(:put, "/v3/sms/receipts-read", body: {date_before: 1_722_565_660}).to_return(json_response(fixture("sms_receipts_read")))
      client.sms.mark_receipts_read(before: Time.at(1_722_565_660))
      expect(stub).to have_been_requested
    end

    it "is retried after a 5xx when it has a cutoff, because repeating it changes nothing" do
      allow(Kernel).to receive(:sleep)
      stub = stub_api(:put, "/v3/sms/receipts-read", body: {date_before: 1_722_565_660}).to_return({status: 502, body: ""}, json_response(fixture("sms_receipts_read")))
      client.sms.mark_receipts_read(before: 1_722_565_660)
      expect(stub).to have_been_requested.twice
    end

    it "is not retried without a cutoff: a second 'mark all' could hide receipts that arrived in between" do
      allow(Kernel).to receive(:sleep)
      stub = stub_api(:put, "/v3/sms/receipts-read").to_return({status: 502, body: ""}, json_response(fixture("sms_receipts_read")))
      expect { client.sms.mark_receipts_read }.to raise_error(Clicksend::ServerError) { |e| expect(e).to be_ambiguous }
      expect(stub).to have_been_requested.once
    end
  end

  describe "#inbound" do
    it "lists unread replies (ClickSend's documented example)" do
      stub_api(:get, "/v3/sms/inbound", query: {}).to_return(json_response(fixture("sms_inbound")))

      reply = client.sms.inbound.first

      expect(reply).to be_a(Clicksend::SMS::InboundMessage)
      expect(reply).to have_attributes(
        message_id: "D2F2BCC3-6558-4DAA-858E-AD7529CC809C", from: "+61123456789", to: "+61113456789",
        body: "reply to msg on 7 aug 2024", original_body: "test msg",
        original_message_id: "1EF54639-F16D-681E-947A-4F4FCDFD2B87", custom_string: "",
        received_at: Time.at(1_722_997_250).utc
      )
    end
  end

  describe "#mark_inbound_read and #mark_inbound_message_read" do
    it "marks all (or earlier) replies read" do
      stub = stub_api(:put, "/v3/sms/inbound-read", body: {date_before: 1_961_900_166}).to_return(json_response(fixture("sms_inbound_read")))
      expect(client.sms.mark_inbound_read(before: 1_961_900_166)).to be_nil
      expect(stub).to have_been_requested
    end

    it "marks one reply read" do
      stub = stub_api(:put, "/v3/sms/inbound-read/D2F2BCC3-6558-4DAA-858E-AD7529CC809C")
        .to_return(json_response(fixture("sms_inbound_message_read")))
      expect(client.sms.mark_inbound_message_read("D2F2BCC3-6558-4DAA-858E-AD7529CC809C")).to be_nil
      expect(stub).to have_been_requested
    end

    it "validates its arguments" do
      expect { client.sms.mark_inbound_read(before: "yesterday") }.to raise_error(ArgumentError, /before: expected a Time/)
      expect { client.sms.mark_inbound_message_read("../x") }.to raise_error(ArgumentError, /message_id/)
    end
  end
end
