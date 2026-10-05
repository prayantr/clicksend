# frozen_string_literal: true

# Response shapes observed against the live API on 2026-10-05 (field names and
# types as observed; all values invented). They differ from ClickSend's
# published examples, so they are pinned here.
RSpec.describe "Live-observed response shapes" do
  # A rejected message carries only a few fields: no price, parts, date,
  # country or carrier, and "schedule" is an empty String.
  let(:invalid_recipient) do
    {"to" => "+000", "body" => "invalid", "from" => "", "schedule" => "", "message_id" => "6F1C3B0A-2D4E-4F5A-8B9C-0D1E2F3A4B5C",
     "custom_string" => "", "is_shared_system_number" => true, "status" => "INVALID_RECIPIENT"}
  end

  # A message to a country the account hasn't enabled: full shape, price "0.0000", 0 parts.
  let(:country_not_enabled) do
    {"to" => "+61411111111", "body" => "ok", "from" => "", "schedule" => "", "message_id" => "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
     "message_parts" => 0, "message_price" => "0.0000", "custom_string" => "", "is_shared_system_number" => true,
     "country" => "AU", "carrier" => "Telstra", "status" => "COUNTRY_NOT_ENABLED"}
  end

  def send_response(messages, queued:, blocked:)
    envelope({"total_price" => 0, "total_count" => messages.size, "queued_count" => queued, "messages" => messages,
              "_currency" => {"currency_name_short" => "USD"}, "blocked_count" => blocked})
  end

  it "raises MessageRejected for a single invalid recipient (HTTP 200)" do
    stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([invalid_recipient], queued: 0, blocked: 0)))

    expect { client.sms.deliver(to: "+000", body: "invalid") }.to raise_error(Clicksend::MessageRejected) { |error|
      result = error.result
      expect(error.status).to eq("INVALID_RECIPIENT")
      expect([result.price, result.parts, result.sent_at, result.scheduled_at, result.country]).to all(be_nil)
      expect(result.message_id).to match(Clicksend::Resources::SMS::MESSAGE_ID)
    }
  end

  it "lists blocked messages in messages[] as well as counting them in blocked_count" do
    stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([country_not_enabled, invalid_recipient], queued: 0, blocked: 1)))

    batch = client.sms.deliver_batch([{to: "+61411111111", body: "ok"}, {to: "+000", body: "invalid"}])

    expect(batch.map(&:status)).to eq(%w[COUNTRY_NOT_ENABLED INVALID_RECIPIENT])
    expect(batch.rejected.size).to eq(2)
    expect(batch.queued).to be_empty
    expect([batch.queued_count, batch.blocked_count, batch.total_count]).to eq([0, 1, 2])
    expect(batch.all_queued?).to be(false)
    expect(batch.first.price).to eq("0.0000")
  end

  it "treats an empty list with last_page 0 as a single empty page" do
    stub = stub_api(:get, "/v3/sms/receipts", query: {"limit" => "15"}).to_return(json_response(envelope(
      {"total" => 0, "per_page" => 15, "current_page" => 1, "last_page" => 0, "next_page_url" => nil, "prev_page_url" => nil,
       "from" => nil, "to" => nil, "data" => []}
    )))

    page = client.sms.receipts(limit: 15)

    expect([page.total, page.last_page, page.size]).to eq([0, 0, 0])
    expect(page.next_page?).to be(false)
    expect(page.auto_paging_each.to_a).to eq([])
    expect(stub).to have_been_requested.once
  end
end
