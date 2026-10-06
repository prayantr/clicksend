# frozen_string_literal: true

require "prism"

# Every Ruby example in the user-facing docs must at least parse, so a
# refactoring that renames a method can't leave the README showing invalid
# code. (Behaviour is covered by the specs of each feature.)
RSpec.describe "Documentation examples" do
  def ruby_blocks(file)
    File.read(File.expand_path("../../#{file}", __dir__), encoding: "UTF-8").scan(/^```ruby\n(.*?)^```/m).flatten
  end

  %w[README.md MIGRATING.md CHANGELOG.md docs/clicksend-api-notes.md].each do |file|
    it "#{file} contains only Ruby examples that parse" do
      failures = ruby_blocks(file).each_with_index.filter_map do |code, index|
        # "..." stands for "your code here" in examples, as in `{ |receipt| ... }`.
        result = Prism.parse(code.gsub(/(?<![.\w])\.\.\.(?![.\w])/, "nil"))
        "block #{index + 1}: #{result.errors.map(&:message).join("; ")}\n#{code}" if result.failure?
      end
      expect(failures).to eq([])
    end
  end

  it "finds the README's examples" do
    expect(ruby_blocks("README.md").size).to be > 20
  end
end
