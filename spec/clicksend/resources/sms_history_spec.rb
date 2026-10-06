# frozen_string_literal: true

RSpec.describe Clicksend::Resources::SMS, "#history" do
  # ClickSend's documented example row (view-sms-history), with the pagination
  # envelope the schema declares (the example itself omits it).
  let(:row) do
    {"direction" => "out", "date" => 1_715_660_441, "to" => "+61411111111", "body" => "test message, please ignore",
     "status" => "Sent", "from" => "+61447254068", "schedule" => "1715660441", "status_code" => "201",
     "status_text" => "Message delivered to the handset", "error_code" => nil, "error_text" => nil,
     "message_id" => "1EF11A95-31A2-6B70-A3E2-750B2DF4583F", "message_parts" => 1, "message_price" => "0.0792",
     "from_email" => nil, "list_id" => nil, "custom_string" => "otp:42", "contact_id" => nil, "user_id" => 1,
     "subaccount_id" => 2, "country" => "AU", "carrier" => "Vodafone", "first_name" => nil, "last_name" => nil,
     "_api_username" => "someone"}
  end

  def page_of(items, current: 1, last: 1)
    envelope({"total" => items.size, "per_page" => 15, "current_page" => current, "last_page" => last,
              "next_page_url" => nil, "prev_page_url" => nil, "from" => 1, "to" => items.size, "data" => items})
  end

  it "lists history oldest first, as HistoryRecords" do
    stub_api(:get, "/v3/sms/history", query: {"order_by" => "date:asc"}).to_return(json_response(page_of([row])))
    record = client.sms.history.first
    expect(record).to be_a(Clicksend::SMS::HistoryRecord)
    expect(record).to have_attributes(
      message_id: "1EF11A95-31A2-6B70-A3E2-750B2DF4583F", direction: "out", status: "Sent", status_code: 201,
      status_text: "Message delivered to the handset", error_code: nil, to: "+61411111111", from: "+61447254068",
      body: "test message, please ignore", parts: 1, price: "0.0792", custom_string: "otp:42", country: "AU",
      carrier: "Vodafone", sent_at: Time.utc(2024, 5, 14, 4, 20, 41), scheduled_at: Time.utc(2024, 5, 14, 4, 20, 41)
    )
    expect(record).to be_outbound.and be_delivered
    expect(record).not_to be_inbound
    expect(record).to be_frozen
    expect(record.raw["_api_username"]).to eq("someone")
    expect(record.inspect).not_to include("raw")
  end

  it "sends dates as Unix timestamps, one documented q filter, and the order" do
    stub = stub_api(:get, "/v3/sms/history", query: {"date_from" => "1700000000", "date_to" => "1700000600", "q" => "to:+61411111111",
                                                     "order_by" => "date:desc", "page" => "2", "limit" => "100"})
      .to_return(json_response(page_of([row], current: 2, last: 2)))
    client.sms.history(date_from: Time.at(1_700_000_000), date_to: 1_700_000_600, to: "+61411111111", order: :desc, page: 2, limit: 100)
    expect(stub).to have_been_requested
  end

  it "builds q from whichever single filter is given" do
    {from: "+61447254068", status: "Failed", message_id: "1EF11A95-31A2-6B70-A3E2-750B2DF4583F"}.each do |name, value|
      stub = stub_api(:get, "/v3/sms/history", query: {"q" => "#{name}:#{value}", "order_by" => "date:asc"}).to_return(json_response(page_of([])))
      client.sms.history(name => value)
      expect(stub).to have_been_requested
    end
  end

  it "pages through every row" do
    stub_api(:get, "/v3/sms/history", query: {"order_by" => "date:asc"}).to_return(json_response(page_of([row], last: 2)))
    stub_api(:get, "/v3/sms/history", query: {"order_by" => "date:asc", "page" => "2"})
      .to_return(json_response(page_of([row.merge("message_id" => "B", "direction" => "in", "status" => "Received", "status_code" => nil)], current: 2, last: 2)))
    records = client.sms.history.auto_paging_each.to_a
    expect(records.map(&:message_id)).to eq(["1EF11A95-31A2-6B70-A3E2-750B2DF4583F", "B"])
    expect(records.last).to be_inbound
    expect(records.last).not_to be_pending
  end

  it "rejects more than one filter, unsafe filter values and unknown orders before calling ClickSend" do
    expect { client.sms.history(to: "+61411111111", status: "Sent") }.to raise_error(ArgumentError, /at most one of/)
    expect { client.sms.history(to: "+614,status:Sent") }.to raise_error(ArgumentError, /without commas/)
    expect { client.sms.history(to: "") }.to raise_error(ArgumentError, /non-empty String/)
    expect { client.sms.history(to: 61_411_111_111) }.to raise_error(ArgumentError, /non-empty String/)
    expect { client.sms.history(order: :newest) }.to raise_error(ArgumentError, /order must be/)
    expect { client.sms.history(date_from: "yesterday") }.to raise_error(ArgumentError, /date_from/)
    expect(a_request(:any, /clicksend/)).not_to have_been_made
  end

  it "is a GET, so it is retried after a 5xx" do
    allow(Kernel).to receive(:sleep)
    stub = stub_api(:get, "/v3/sms/history", query: {"order_by" => "date:asc"}).to_return({status: 503, body: ""}, json_response(page_of([])))
    expect(client.sms.history).to be_empty
    expect(stub).to have_been_requested.twice
  end

  it "tolerates ClickSend's mixed types in history rows" do
    record = Clicksend::SMS::HistoryRecord.from_api(row.merge("status_code" => 301, "error_code" => 5, "list_id" => 123, "schedule" => ""))
    expect(record).to have_attributes(status_code: 301, error_code: "5", list_id: "123", scheduled_at: nil)
    expect(record).to be_failed
    expect { Clicksend::SMS::HistoryRecord.from_api(nil) }.to raise_error(Clicksend::MalformedResponseError)
  end
end

RSpec.describe Clicksend::SMS::HistoryRecord, "delivery predicates" do
  def record(status, status_code)
    described_class.from_api("message_id" => "A", "direction" => "out", "status" => status, "status_code" => status_code)
  end

  def predicates(status, status_code)
    r = record(status, status_code)
    [r.delivered?, r.failed?, r.pending?]
  end

  # Rows of ClickSend's "SMS error codes" article (help 42318), with the code as a
  # String (as the history schema documents) and as an Integer.
  {
    ["Sent", "200"] => [false, false, true],
    ["Sent", "201"] => [true, false, false],
    ["Queued", "200"] => [false, false, true],
    ["Scheduled", "200"] => [false, false, true],
    ["WaitApproval", "200"] => [false, false, true],
    ["Cancelled", "301"] => [false, true, false],
    ["Failed", "301"] => [false, true, false],
    ["CancelledAfterReview", nil] => [false, true, false],
    ["Sent", 201] => [true, false, false],
    ["Failed", 301] => [false, true, false]
  }.each do |(status, code), expected|
    it "reads #{status.inspect} with code #{code.inspect} as delivered/failed/pending #{expected}" do
      expect(predicates(status, code)).to eq(expected)
    end
  end

  it "uses the documented statuses when the code is missing" do
    expect(predicates("Queued", nil)).to eq([false, false, true])
    expect(predicates("Failed", nil)).to eq([false, true, false])
  end

  it "claims nothing for a row it can't classify, such as the live 'Completed' row with no code" do
    expect(predicates("Completed", nil)).to eq([false, false, false])
    expect(predicates("Sent", nil)).to eq([false, false, false]) # 200 or 201: unknown without a code
    expect(predicates("Received", nil)).to eq([false, false, false])
  end

  it "lets the code decide when status and code disagree" do
    expect(predicates("Completed", "201")).to eq([true, false, false])
    expect(predicates("Completed", "300")).to eq([false, false, true])
  end
end
