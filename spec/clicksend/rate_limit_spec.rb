# frozen_string_literal: true

RSpec.describe Clicksend::RateLimit do
  it "parses the headers observed on GET /v3/account" do
    limit = described_class.from_headers({"x-ratelimit-limit" => "20", "x-ratelimit-remaining" => "17", "ratelimit-reset" => "42"})
    expect(limit).to eq(described_class.new(limit: 20, remaining: 17, reset_in: 42))
    expect(limit).to be_frozen
  end

  it "returns nil when none of the headers is present" do
    expect(described_class.from_headers({"content-type" => "application/json"})).to be_nil
    expect(described_class.from_headers(nil)).to be_nil
  end

  it "keeps the fields that are present and leaves the others nil" do
    expect(described_class.from_headers({"x-ratelimit-remaining" => "3"}))
      .to eq(described_class.new(limit: nil, remaining: 3, reset_in: nil))
  end

  it "ignores values that are not non-negative integers" do
    limit = described_class.from_headers({"x-ratelimit-limit" => "lots", "x-ratelimit-remaining" => "-1", "ratelimit-reset" => " 5 "})
    expect(limit).to eq(described_class.new(limit: nil, remaining: nil, reset_in: 5))
    expect(described_class.from_headers({"x-ratelimit-limit" => "1_000", "ratelimit-reset" => "+5"})).to be_nil
  end

  it "reads the same every time (nothing is computed from the clock)" do
    response = Clicksend::Response.new(http_status: 200, headers: {"ratelimit-reset" => "60"}, body: nil)
    expect(response.rate_limit).to eq(response.rate_limit)
  end

  it "is exposed on successful responses" do
    response = Clicksend::Response.new(http_status: 200, headers: {"x-ratelimit-limit" => "20"}, body: nil)
    expect(response.rate_limit.limit).to eq(20)
    expect(Clicksend::Response.new(http_status: 200, headers: {}, body: nil).rate_limit).to be_nil
  end
end
