# frozen_string_literal: true

RSpec.describe Clicksend::Model do
  it "coerces integers leniently" do
    expect([1, "2", "1721099039,", 1.5, nil].map { |v| described_class.integer(v) }).to eq([1, 2, nil, nil, nil])
    expect(described_class.integer("010")).to eq(10)
  end

  it "converts Unix timestamps to UTC times" do
    expect(described_class.time("1722565661")).to eq(Time.utc(2024, 8, 2, 2, 27, 41))
    expect(described_class.time(nil)).to be_nil
  end

  it "keeps prices as decimal strings" do
    expect([described_class.decimal(0.0792), described_class.decimal("0.0792"), described_class.decimal(nil)]).to eq(["0.0792", "0.0792", nil])
  end
end
