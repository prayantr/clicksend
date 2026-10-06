# frozen_string_literal: true

require "clicksend/testing"

RSpec.describe Clicksend::Testing::FakeAPI, "history" do
  let(:times) { [Time.utc(2026, 10, 6, 9, 0, 0)] }
  let(:fake) { described_class.new(message_price: "0.0792", clock: -> { times.first }) }
  let(:client) { fake.client }

  def at(time)
    times[0] = time
    yield
  end

  def t(minute)
    Time.utc(2026, 10, 6, 9, minute, 0)
  end

  before do
    at(t(0)) { client.sms.deliver(to: "+61411111111", body: "first", from: "Acme", custom_string: "a") }
    at(t(10)) { fake.add_inbound(reply_to: fake.sent_messages.first, body: "reply") }
    at(t(20)) { client.sms.deliver(to: "+61422222222", body: "second", custom_string: "b") }
  end

  it "lists sent and inbound messages oldest first with the documented fields" do
    records = client.sms.history.to_a

    expect(records.map { |r| [r.direction, r.body, r.sent_at] }).to eq([
      ["out", "first", t(0)], ["in", "reply", t(10)], ["out", "second", t(20)]
    ])
    expect(records[0]).to have_attributes(status: "Sent", status_code: 200, to: "+61411111111", from: "Acme",
      custom_string: "a", parts: 1, price: "0.0792", message_id: fake.sent_messages.first.message_id)
    expect(records[0]).to be_outbound.and(be_pending)
    expect(records[1]).to have_attributes(status: "Received", from: "+61411111111", to: "Acme", custom_string: "a")
    expect(records[1]).to be_inbound
    expect(records[0].raw.keys).to include("direction", "date", "to", "body", "status", "from", "schedule", "status_code",
      "status_text", "error_code", "error_text", "message_id", "message_parts", "message_price", "list_id",
      "custom_string", "user_id", "subaccount_id", "country", "carrier")
    expect(records[0].raw["status_code"]).to eq("200")
  end

  it "reports the latest receipt's gateway code on the sent message" do
    sent = fake.sent_messages.first
    fake.add_receipt(for: sent, status_code: 301, error_code: 3, error_text: "Expired")

    record = client.sms.history(message_id: sent.message_id).first
    expect(record).to have_attributes(status: "Sent", status_code: 301, status_text: "Failed", error_code: "3", error_text: "Expired")
    expect(record).to be_failed

    fake.add_receipt(for: sent, status_code: 201)
    expect(client.sms.history(message_id: sent.message_id).first).to be_delivered
  end

  it "orders by date descending" do
    expect(client.sms.history(order: :desc).map(&:body)).to eq(%w[second reply first])
    expect(fake.requests.last.query).to include("order_by" => "date:desc")
  end

  it "filters by inclusive date range" do
    expect(client.sms.history(date_from: t(10)).map(&:body)).to eq(%w[reply second])
    expect(client.sms.history(date_to: t(10)).map(&:body)).to eq(%w[first reply])
    expect(client.sms.history(date_from: t(5), date_to: t(15)).map(&:body)).to eq(%w[reply])
    expect(fake.requests.last.query).to eq("date_from" => t(5).to_i.to_s, "date_to" => t(15).to_i.to_s, "order_by" => "date:asc")
  end

  it "filters with one q=field:value" do
    expect(client.sms.history(to: "+61422222222").map(&:body)).to eq(%w[second])
    expect(client.sms.history(from: "+61411111111").map(&:body)).to eq(%w[reply])
    expect(client.sms.history(status: "Received").map(&:body)).to eq(%w[reply])
    expect(client.sms.history(message_id: fake.sent_messages.last.message_id).map(&:body)).to eq(%w[second])
    expect(client.sms.history(to: "+61400000000").to_a).to be_empty
  end

  it "does not list rejected messages" do
    fake.reject(status: "INVALID_RECIPIENT")
    expect { client.sms.deliver(to: "+61433333333", body: "nope") }.to raise_error(Clicksend::MessageRejected)

    expect(client.sms.history.map(&:body)).not_to include("nope")
  end

  it "paginates" do
    20.times { client.sms.deliver(to: "+61411111111", body: "more") }

    page = client.sms.history
    expect(page).to have_attributes(total: 23, last_page: 2, size: 15)
    expect(page.auto_paging_each.count).to eq(23)
  end

  it "answers 400 to an unsupported q (reachable only through client.request)" do
    expect { client.request(:get, "/v3/sms/history", query: {q: "custom_string:a"}) }.to raise_error(Clicksend::BadRequestError)
    expect { client.request(:get, "/v3/sms/history", query: {q: "to"}) }.to raise_error(Clicksend::BadRequestError)
  end
end
