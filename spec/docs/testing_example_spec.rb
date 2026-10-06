# frozen_string_literal: true

require "clicksend/testing"

# Runs the RSpec example from the documentation of lib/clicksend/testing.rb
# exactly as written, so the example can't drift from the code.
module TestingDocExample
  SOURCE = File.read(File.expand_path("../../lib/clicksend/testing.rb", __dir__), encoding: "UTF-8")
  # Code lines are "  #   code", blank lines inside the example are "  #";
  # the first prose comment ("  # text") or non-comment line ends it.
  lines = SOURCE.lines.map do |line|
    if line.match?(/\A  #\s*\n\z/) then "\n"
    elsif (code = line[/\A  #   (.*\n)\z/m, 1]) then code
    end
  end
  start = lines.index { |line| line&.start_with?("class OtpSender") }
  CODE = lines[start..].take_while { |line| !line.nil? }.join
end

# standard:disable Security/Eval -- evaluates this repository's own documentation
eval(TestingDocExample::CODE, TOPLEVEL_BINDING, "lib/clicksend/testing.rb (doc example)")
# standard:enable Security/Eval

RSpec.describe "The lib/clicksend/testing.rb example" do
  it "was found and defines the documented examples" do
    expect(TestingDocExample::CODE).to include("class OtpSender", "RSpec.describe OtpSender", "never sends twice")
  end
end
