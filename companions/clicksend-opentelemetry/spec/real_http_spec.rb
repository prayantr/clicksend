# frozen_string_literal: true

# The real HTTP stack (Faraday, Net::HTTP, a local server), with
# opentelemetry-instrumentation-faraday and -net_http installed as in a typical
# application, to show how the spans nest and that tracing changes nothing
# about what reaches the server.
RSpec.describe "Clicksend::OpenTelemetry over real HTTP" do
  after { @server&.stop }

  def serve(*script)
    @server = LocalServer.new(*script)
  end

  def local_client(**options)
    base_url = "http://127.0.0.1:#{@server.port}"
    Clicksend::Client.new(username: "u", api_key: "k", base_url: base_url, timeout: 0.5, open_timeout: 0.5,
      retry_policy: Clicksend::RetryPolicy.new(max_retries: 2, base_delay: 0, max_delay: 0),
      instrumenter: Clicksend::OpenTelemetry::Instrumenter.new(base_url: base_url), **options)
  end

  def http_spans
    spans.reject { |span| span.instrumentation_scope.name == SpanHelpers::SCOPE }
  end

  it "sends a timed-out send exactly once, and reports it as ambiguous" do
    serve(:hang, :ok)
    expect { local_client.sms.deliver(to: "+61411111111", body: "hi") }.to raise_error(Clicksend::TimeoutError) { |e|
      expect(e).to be_ambiguous
      expect(e.request.attempts).to eq(1)
    }
    expect(@server.requests).to eq(["POST /v3/sms/send HTTP/1.1"])
    expect(clicksend_span.attributes).to include("clicksend.ambiguous" => true, "clicksend.attempts" => 1, "error.type" => "Clicksend::TimeoutError")
  end

  it "nests one Faraday CLIENT span per attempt under the clicksend span (Net::HTTP's own span is suppressed)" do
    serve(:unavailable, :unavailable, :ok)
    local_client.request(:get, "/v3/account", operation: "account.fetch")

    parent = clicksend_span
    expect(parent.attributes).to include("clicksend.attempts" => 3, "server.address" => "127.0.0.1", "server.port" => @server.port)
    expect(parent.events.map(&:name)).to eq(%w[clicksend.retry clicksend.retry])
    expect(http_spans.map { |s| [s.name, s.kind, s.instrumentation_scope.name, s.attributes["http.response.status_code"]] }).to eq([
      ["GET", :client, "OpenTelemetry::Instrumentation::Faraday", 503],
      ["GET", :client, "OpenTelemetry::Instrumentation::Faraday", 503],
      ["GET", :client, "OpenTelemetry::Instrumentation::Faraday", 200]
    ])
    expect(http_spans.map(&:parent_span_id).uniq).to eq([parent.span_id])
    expect(@server.requests.size).to eq(3)
  end

  # Not this gem's spans: a warning for the README. HTTP-level instrumentation
  # records the full URL, query string included, so a history search by
  # number puts the number in the Faraday span (url.full).
  it "leaves the query string out of its own span, though Faraday's span records it" do
    serve(:ok)
    local_client.request(:get, "/v3/sms/history", query: {q: "to:+61411111111"}, operation: "sms.history")

    expect(clicksend_span.attributes.values.join).not_to include("61411111111")
    expect(http_spans.first.attributes["url.full"]).to include("61411111111")
  end
end
