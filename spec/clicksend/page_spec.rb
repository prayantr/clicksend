# frozen_string_literal: true

RSpec.describe Clicksend::Page do
  def page_payload(current, last, items, total: nil, per_page: 15)
    envelope({"total" => total || items.size, "per_page" => per_page, "current_page" => current, "last_page" => last,
              "next_page_url" => nil, "prev_page_url" => nil, "from" => 1, "to" => items.size, "data" => items})
  end

  def stub_page(number, last, items, limit: nil)
    query = {"page" => number.to_s}
    query["limit"] = limit.to_s if limit
    stub_api(:get, "/v3/things", query: query).to_return(json_response(page_payload(number, last, items)))
  end

  it "fetches one page with page and limit parameters" do
    stub_page(1, 1, [{"id" => 1}], limit: 50)
    page = client.paginate("/v3/things", page: 1, limit: 50)
    expect(page.to_a).to eq([{"id" => 1}])
    expect([page.current_page, page.last_page, page.total, page.per_page]).to eq([1, 1, 1, 15])
    expect(page.next_page?).to be(false)
    expect(page.next_page).to be_nil
  end

  it "omits page and limit when not given" do
    stub = stub_api(:get, "/v3/things", query: {}).to_return(json_response(page_payload(1, 1, [])))
    client.paginate("/v3/things")
    expect(stub).to have_been_requested
  end

  it "keeps caller query parameters on every page" do
    stub_api(:get, "/v3/things", query: {"q" => "x", "page" => "1"}).to_return(json_response(page_payload(1, 2, [{"id" => 1}])))
    second = stub_api(:get, "/v3/things", query: {"q" => "x", "page" => "2"}).to_return(json_response(page_payload(2, 2, [{"id" => 2}])))
    client.paginate("/v3/things", query: {q: "x"}, page: 1).auto_paging_each.to_a
    expect(second).to have_been_requested
  end

  it "walks all pages lazily with auto_paging_each" do
    stub_page(1, 3, [{"id" => 1}, {"id" => 2}])
    second = stub_page(2, 3, [{"id" => 3}])
    third = stub_page(3, 3, [{"id" => 4}])
    page = client.paginate("/v3/things", page: 1)

    expect(page.auto_paging_each.first(3).map { |item| item["id"] }).to eq([1, 2, 3])
    expect(third).not_to have_been_requested

    expect(page.auto_paging_each.map { |item| item["id"] }).to eq([1, 2, 3, 4])
    expect(second).to have_been_requested.twice
  end

  it "stops on an empty page even if last_page says otherwise" do
    stub_page(1, 5, [])
    expect(client.paginate("/v3/things", page: 1).auto_paging_each.to_a).to eq([])
  end

  it "stops, without yielding duplicates, if the API does not advance" do
    stub_page(1, 3, [{"id" => 1}])
    stub_api(:get, "/v3/things", query: {"page" => "2"}).to_return(json_response(page_payload(1, 3, [{"id" => 1}])))
    expect(client.paginate("/v3/things", page: 1).auto_paging_each.to_a).to eq([{"id" => 1}])
  end

  it "accepts numeric strings in pagination metadata" do
    stub_api(:get, "/v3/things", query: {}).to_return(json_response(envelope({"total" => "1", "per_page" => "15", "current_page" => "1", "last_page" => "1", "data" => []})))
    expect(client.paginate("/v3/things").total).to eq(1)
  end

  it "enforces ClickSend's documented limit range and positive pages" do
    expect { client.paginate("/v3/things", limit: 10) }.to raise_error(ArgumentError, /between 15 and 100/)
    expect { client.paginate("/v3/things", limit: 101) }.to raise_error(ArgumentError)
    expect { client.paginate("/v3/things", page: 0) }.to raise_error(ArgumentError, /page/)
  end

  it "raises MalformedResponseError when the response is not paginated" do
    stub_api(:get, "/v3/things", query: {}).to_return(json_response(envelope({"id" => 1})))
    expect { client.paginate("/v3/things") }.to raise_error(Clicksend::MalformedResponseError, /paginated/)

    stub_api(:get, "/v3/other", query: {}).to_return(json_response(envelope({"data" => [], "total" => 0})))
    expect { client.paginate("/v3/other") }.to raise_error(Clicksend::MalformedResponseError, /per_page/)
  end

  it "is frozen and has a compact inspect" do
    stub_page(1, 1, [{"id" => 1}])
    page = client.paginate("/v3/things", page: 1)
    expect(page).to be_frozen
    expect(page.inspect).to eq("#<Clicksend::Page current_page=1 last_page=1 total=1 items=1>")
  end
end
