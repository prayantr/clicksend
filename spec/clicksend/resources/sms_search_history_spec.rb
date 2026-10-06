# frozen_string_literal: true

RSpec.describe Clicksend::Resources::SMS, "#search_history" do
  let(:sent_after) { Time.at(1_700_000_000) }
  let(:margin) { Clicksend::Resources::SMS::HISTORY_SEARCH_MARGIN }

  def row(**overrides)
    {"direction" => "out", "date" => 1_700_000_030, "to" => "+61411111111", "body" => "Your code is 481516",
     "status" => "Completed", "from" => "Acme", "schedule" => "1700000030", "status_code" => nil, "status_text" => nil,
     "message_id" => "A", "message_parts" => 0, "message_price" => "0.0000", "custom_string" => "otp:42"}
      .merge(overrides.transform_keys(&:to_s))
  end

  def page_of(items, current: 1, last: 1)
    envelope({"total" => items.size, "per_page" => 100, "current_page" => current, "last_page" => last,
              "next_page_url" => nil, "prev_page_url" => nil, "from" => 1, "to" => items.size, "data" => items})
  end

  def query(**extra)
    {"q" => "to:+61411111111", "date_from" => (1_700_000_000 - margin).to_s, "order_by" => "date:asc", "limit" => "100"}
      .merge(extra.transform_keys(&:to_s))
  end

  it "asks for the recipient's history from a widened window, 100 rows a page" do
    stub = stub_api(:get, "/v3/sms/history", query: query).to_return(json_response(page_of([row])))

    records = client.sms.search_history(to: "+61411111111", custom_string: "otp:42", sent_after: sent_after)

    expect(stub).to have_been_requested
    expect(records.map(&:message_id)).to eq(["A"])
    expect(records.first).to be_a(Clicksend::SMS::HistoryRecord)
  end

  it "widens an upper bound too" do
    stub = stub_api(:get, "/v3/sms/history", query: query(date_to: 1_700_000_060 + margin)).to_return(json_response(page_of([])))
    client.sms.search_history(to: "+61411111111", custom_string: "otp:42", sent_after: 1_700_000_000, sent_before: Time.at(1_700_000_060))
    expect(stub).to have_been_requested
  end

  it "accepts sent_before equal to sent_after (one instant, widened both ways)" do
    stub = stub_api(:get, "/v3/sms/history", query: query(date_to: 1_700_000_000 + margin)).to_return(json_response(page_of([])))
    client.sms.search_history(to: "+61411111111", custom_string: "otp:42", sent_after: 1_700_000_000, sent_before: 1_700_000_000)
    expect(stub).to have_been_requested
  end

  it "keeps only outbound rows whose recipient and custom_string are exactly the ones given" do
    rows = [
      row(message_id: "A"),
      row(message_id: "case", custom_string: "OTP:42"),
      row(message_id: "prefix", custom_string: "otp:421"),
      row(message_id: "empty", custom_string: ""),
      row(message_id: "nil", custom_string: nil),
      row(message_id: "longer-number", to: "+614111111112"),
      row(message_id: "reply", direction: "in", to: "+61411111111"),
      row(message_id: "again", date: 1_700_000_090)
    ]
    stub_api(:get, "/v3/sms/history", query: query).to_return(json_response(page_of(rows)))

    records = client.sms.search_history(to: "+61411111111", custom_string: "otp:42", sent_after: sent_after)
    expect(records.map(&:message_id)).to eq(%w[A again])
  end

  it "reads every page, since a match can be on any of them" do
    stub_api(:get, "/v3/sms/history", query: query).to_return(json_response(page_of([row(custom_string: "other")], last: 2)))
    stub_api(:get, "/v3/sms/history", query: query(page: 2)).to_return(json_response(page_of([row(message_id: "B")], current: 2, last: 2)))

    expect(client.sms.search_history(to: "+61411111111", custom_string: "otp:42", sent_after: sent_after).map(&:message_id)).to eq(["B"])
  end

  it "returns an empty Array when history shows nothing, which says nothing about whether it was sent" do
    stub_api(:get, "/v3/sms/history", query: query).to_return(json_response(page_of([])))
    expect(client.sms.search_history(to: "+61411111111", custom_string: "otp:42", sent_after: sent_after)).to eq([])
  end

  it "validates its arguments before calling ClickSend" do
    defaults = {to: "+61411111111", custom_string: "otp:42", sent_after: sent_after}
    search = ->(**args) { client.sms.search_history(**defaults, **args) }
    ["0411111111", "61411111111", "+0411111111", "+6141111111 ", "", nil].each do |bad|
      expect { search.call(to: bad) }.to raise_error(ArgumentError, /E\.164/)
    end
    expect { search.call(custom_string: "") }.to raise_error(ArgumentError, /custom_string/)
    expect { search.call(custom_string: :otp) }.to raise_error(ArgumentError, /custom_string/)
    expect { search.call(sent_after: nil) }.to raise_error(ArgumentError, /sent_after/)
    expect { search.call(sent_after: "today") }.to raise_error(ArgumentError, /sent_after/)
    expect { search.call(sent_before: sent_after - 1) }.to raise_error(ArgumentError, /sent_before must not be earlier/)
    expect { client.sms.search_history(to: "+61411111111", custom_string: "x") }.to raise_error(ArgumentError, /sent_after/)
    expect(a_request(:any, /clicksend/)).not_to have_been_made
  end

  it "is a GET, so a 5xx is retried" do
    allow(Kernel).to receive(:sleep)
    stub = stub_api(:get, "/v3/sms/history", query: query).to_return({status: 503, body: ""}, json_response(page_of([row])))
    expect(client.sms.search_history(to: "+61411111111", custom_string: "otp:42", sent_after: sent_after).size).to eq(1)
    expect(stub).to have_been_requested.twice
  end
end
