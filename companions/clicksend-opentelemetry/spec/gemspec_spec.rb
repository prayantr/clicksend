# frozen_string_literal: true

RSpec.describe "clicksend-opentelemetry.gemspec" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:spec) { Dir.chdir(root) { Gem::Specification.load("clicksend-opentelemetry.gemspec") } }

  it "depends at runtime on clicksend 1.x and the OpenTelemetry API only (never the SDK)" do
    expect(spec.runtime_dependencies.map { |d| [d.name, d.requirement.to_s] }).to contain_exactly(
      ["clicksend", "~> 1.1"], ["opentelemetry-api", "~> 1.1"]
    )
  end

  it "ships the library and its documents, nothing else" do
    expect(spec.files).to include("lib/clicksend/opentelemetry.rb", "README.md", "CHANGELOG.md", "LICENSE.txt")
    expect(spec.files.grep_v(%r{\Alib/|\A(README|CHANGELOG)\.md\z|\ALICENSE\.txt\z})).to eq([])
  end

  it "matches the core gem's Ruby requirement and release metadata" do
    expect(spec.required_ruby_version.to_s).to eq(">= 3.3")
    expect(spec.metadata).to include("rubygems_mfa_required" => "true", "allowed_push_host" => "https://rubygems.org")
    expect(spec.version.to_s).to eq(Clicksend::OpenTelemetry::VERSION)
  end
end
