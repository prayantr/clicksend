# frozen_string_literal: true

# Both lockfiles record the core gem's own version (the companion bundles it
# by path). A version bump that forgets one of them breaks `bundle install
# --frozen` in CI for that bundle only, so pin it here where everyone runs.
RSpec.describe "lockfile versions" do
  root = File.expand_path("../..", __dir__)

  {
    "Gemfile.lock" => "Gemfile.lock",
    "companions/clicksend-opentelemetry/Gemfile.lock" => "companion Gemfile.lock"
  }.each do |path, name|
    it "#{name} records clicksend #{Clicksend::VERSION}" do
      locked = File.read(File.join(root, path))[/^    clicksend \(([^)]+)\)$/, 1]
      expect(locked).to eq(Clicksend::VERSION), "refresh #{path} (bundle lock) after bumping lib/clicksend/version.rb"
    end
  end
end
