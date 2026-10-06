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

  describe "README examples that run as written" do
    before { require "clicksend/testing" }

    def readme_block(containing)
      ruby_blocks("README.md").find { |code| code.include?(containing) } or raise "no README example contains #{containing.inspect}"
    end

    it "the FakeAPI walkthrough" do
      code = readme_block("fake = Clicksend::Testing::FakeAPI.new")
      result = Module.new.module_eval(code + "\n[fake, client]")
      fake, client = result
      expect(client).to be_a(Clicksend::Client)
      expect(fake.requests).to be_empty # reset! ran last
    end

    it "every fail_next example is accepted" do
      fake = Clicksend::Testing::FakeAPI.new
      code = readme_block("fake.fail_next(:timeout, processed: true)")
      expect { binding.tap { |b| b.local_variable_set(:fake, fake) }.eval(code) }.not_to raise_error
    end

    it "the ambiguous-send rescue, against the fake" do
      fake = Clicksend::Testing::FakeAPI.new
      fake.fail_next(:timeout, processed: true)
      user = Struct.new(:phone).new("+61411111111")
      attempt = Struct.new(:id).new(42)
      client = fake.client
      text = "Your code is 481516"
      code = readme_block("rescue Clicksend::AmbiguousRequestError => e")
      expect { binding.eval(code) }.not_to raise_error # standard:disable Security/Eval -- evaluates this repository's own README
      expect(fake.sent_messages.size).to eq(1)
    end
  end

  it "finds the README's examples" do
    expect(ruby_blocks("README.md").size).to be > 20
  end
end
