# frozen_string_literal: true

require "open3"
require "rbconfig"

# The gem depends on neither RSpec nor Minitest: only the opt-in files load
# them. Checked in fresh processes, since this one has RSpec loaded.
RSpec.describe "Loading the test framework helpers" do
  # Runs +code+ in a new Ruby (with warnings on: any warning fails the
  # comparison of its output).
  def ruby(code)
    output, status = Open3.capture2e(RbConfig.ruby, "-w", "-W:deprecated", "-I", File.expand_path("../../../lib", __dir__), "-e", code)
    expect(status).to be_success, output
    output
  end

  def loaded_after(*features)
    ruby(<<~RUBY)
      #{features.map { |feature| "require #{feature.inspect}" }.join("\n")}
      puts [defined?(RSpec::Core), defined?(RSpec::Expectations), defined?(Minitest),
            $LOADED_FEATURES.grep(%r{/(rspec|minitest)[^/]*/}).empty?].inspect
    RUBY
  end

  it "require \"clicksend\" and \"clicksend/testing\" load neither RSpec nor Minitest" do
    expect(loaded_after("clicksend", "clicksend/testing")).to eq("[nil, nil, nil, true]\n")
  end

  it "clicksend/testing/minitest loads Minitest only, and doesn't run it at exit" do
    expect(loaded_after("clicksend/testing/minitest")).to eq(%([nil, nil, "constant", false]\n))
  end

  it "clicksend/testing/rspec loads only rspec-expectations, and works without rspec-core" do
    expect(loaded_after("clicksend/testing/rspec")).to eq(%([nil, "constant", nil, false]\n))
    expect(ruby(<<~RUBY)).to eq("true\nfalse\n")
      require "clicksend/testing/rspec"
      include Clicksend::Testing::RSpecMatchers
      fake = Clicksend::Testing::FakeAPI.new
      fake.client.sms.deliver(to: "+61411111111", body: "Hi")
      puts have_sent_sms(to: "+61411111111").matches?(fake), have_sent_no_sms.matches?(fake)
    RUBY
  end
end
