# frozen_string_literal: true

require "net/http"
require "stringio"
require "tmpdir"
require_relative "../../script/webhook_capture"

# Phone numbers below are from ranges reserved for fiction (Ofcom's 07700 900xxx,
# ACMA's 0491 570xxx), so they belong to nobody and are not ClickSend test numbers.
RSpec.describe WebhookCapture do
  def http(head, body)
    "#{head.join("\r\n")}\r\n\r\n#{body}"
  end

  def redact(text)
    redactor = WebhookCapture::Redactor.new
    [redactor.redact(text), redactor.notes]
  end

  def decode_form(text)
    URI.decode_www_form(text.split("\r\n\r\n", 2).last)
  end

  let(:form_body) do
    URI.encode_www_form(
      "timestamp" => "1759730500", "from" => "+447700900123", "sms" => "+447700900123", "to" => "+61491570156",
      "originalsenderid" => "+61491570156", "body" => "Call me on 0491 570 157", "message" => "Call me on 0491 570 157",
      "message_id" => "AB12CD34-5678-90EF-ABCD-1234567890AB", "messageid" => "AB12CD34-5678-90EF-ABCD-1234567890AB",
      "original_message_id" => "FFEE0011-2233-4455-6677-8899AABBCCDD", "custom_string" => "", "user_id" => "987654",
      "subaccount_id" => "123456", "new_field" => "from +447700900999"
    )
  end
  let(:form_capture) do
    http(["POST /clicksend/:secret/inbound HTTP/1.1", "Host: tunnel.example", "Content-Type: application/x-www-form-urlencoded",
      "Content-Length: #{form_body.bytesize}", "X-Forwarded-For: 192.0.2.10", "User-Agent: Example/1.0"], form_body)
  end

  describe WebhookCapture::Redactor do
    it "replaces phone numbers, text, IDs and account IDs, keeping field names, order, emptiness and equalities" do
      redacted, notes = redact(form_capture)
      fields = decode_form(redacted).to_h

      expect(decode_form(redacted).map(&:first)).to eq(decode_form(form_capture).map(&:first))
      expect(fields.values_at("from", "sms")).to eq(["+61411111111", "+61411111111"])
      expect(fields.values_at("to", "originalsenderid")).to eq(["+61422222222", "+61422222222"])
      expect(fields.values_at("body", "message")).to eq(["redacted text 1", "redacted text 1"])
      expect(fields.values_at("message_id", "messageid")).to eq(["11111111-1111-1111-1111-111111111111"] * 2)
      expect(fields["original_message_id"]).to eq("22222222-2222-2222-2222-222222222222")
      expect(fields).to include("custom_string" => "", "timestamp" => "1759730500", "user_id" => "100001", "subaccount_id" => "100002")
      expect(fields["new_field"]).to eq("from +61411111111")
      expect(notes).to include(a_string_matching(/unknown field "new_field"/))
      expect(redacted).not_to match(/447700900|491570|987654|123456|0491 570|192\.0\.2\.10|tunnel\.example/)
    end

    it "keeps header names, redacts their values unless known safe, and recomputes Content-Length" do
      redacted, = redact(form_capture)
      head = redacted.split("\r\n\r\n").first.split("\r\n")

      expect(head).to include("Host: [redacted]", "X-Forwarded-For: [redacted]", "User-Agent: Example/1.0",
        "Content-Type: application/x-www-form-urlencoded", "Content-Length: #{redacted.split("\r\n\r\n", 2).last.bytesize}")
    end

    it "produces a fixture the replay helper and the gem accept" do
      redacted, = redact(form_capture)
      Dir.mktmpdir do |dir|
        stub_const("WebhookReplay::DIR", dir)
        File.write(File.join(dir, "capture.http"), redacted)
        message = Clicksend::Webhook.parse(WebhookReplay.params(WebhookReplay.load("capture.http")))

        expect(message).to have_attributes(from: "+61411111111", to: "+61422222222", body: "redacted text 1", custom_string: "")
      end
    end

    it "keeps JSON types: integers stay integers, null stays null" do
      json = JSON.generate("from" => "+447700900123", "timestamp" => 1_759_730_500, "user_id" => 987_654, "custom_string" => nil, "body" => "hi")
      redacted, = redact(http(["POST /clicksend/:secret/inbound HTTP/1.1", "Content-Type: application/json; charset=utf-8"], json))

      expect(JSON.parse(redacted.split("\r\n\r\n", 2).last))
        .to eq("from" => "+61411111111", "timestamp" => 1_759_730_500, "user_id" => 100_001, "custom_string" => nil, "body" => "redacted text 1")
    end

    it "redacts a GET query string and accepts LF line endings" do
      redacted, = redact("GET /clicksend/:secret/inbound?from=%2B447700900123&body=hello HTTP/1.1\nAccept: */*\n\n")
      expect(redacted).to start_with("GET /clicksend/:secret/inbound?from=%2B61411111111&body=redacted+text+1 HTTP/1.1\r\n")
    end

    it "keeps a media URL recognisable as a URL" do
      redacted, notes = redact(http(["POST /clicksend/:secret/inbound HTTP/1.1", "Content-Type: application/x-www-form-urlencoded"],
        "body=https%3A%2F%2Fmedia.example%2Fabc.jpg"))
      expect(decode_form(redacted)).to eq([["body", "https://example.invalid/redacted-media"]])
      expect(notes).to include("body is a URL (inbound MMS?)")
    end

    it "refuses what it can't redact safely" do
      [
        http(["POST /clicksend/:secret/x HTTP/1.1", "Content-Type: text/plain"], "from=+447700900123"),
        http(["POST /clicksend/:secret/x HTTP/1.1", "Content-Type: application/json"], "[1]"),
        http(["POST /my-real-secret/x HTTP/1.1", "Content-Type: application/json"], "{}")
      ].each { |text| expect { redact(text) }.to raise_error(WebhookCapture::Error) }
    end

    it "writes files through .redact" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "in.http"), form_capture)
        notes = WebhookCapture.redact(File.join(dir, "in.http"), File.join(dir, "out.http"))
        expect(File.read(File.join(dir, "out.http"))).to include("from=%2B61411111111")
        expect(notes).to eq(notes.uniq)
      end
    end
  end

  describe WebhookCapture::Server do
    around do |example|
      WebMock.disable_net_connect!(allow_localhost: true)
      Dir.mktmpdir do |dir|
        @dir = File.join(dir, "captures")
        example.run
      end
    ensure
      WebMock.disable_net_connect!
    end

    let(:secret) { "s3cret-token-0123456789" }
    let(:log) { StringIO.new }

    def start(limit: 1)
      server = described_class.new(secret: secret, dir: @dir, port: 0, read_timeout: 2, log: log)
      thread = Thread.new { server.run(limit: limit) }
      [server, thread]
    end

    def post(port, path, body, headers = {})
      Net::HTTP.start("127.0.0.1", port) { |h| h.post(path, body, {"Content-Type" => "application/x-www-form-urlencoded"}.merge(headers)) }
    end

    it "saves a request to the secret path with the secret replaced, readable only by the owner, and answers 200" do
      server, thread = start
      response = post(server.port, "/#{secret}/inbound", "from=%2B447700900123&body=hi", "X-Original-Url" => "/#{secret}/inbound")
      thread.join(5)

      expect(response.code).to eq("200")
      file = server.saved.fetch(0)
      expect(File.stat(file).mode & 0o777).to eq(0o600)
      expect(File.stat(@dir).mode & 0o777).to eq(0o700)
      content = File.binread(file)
      expect(content).to start_with("POST /clicksend/:secret/inbound HTTP/1.1\r\n")
      expect(content).not_to include(secret)
      expect(content).to include("X-Original-Url: /:secret/inbound")
      expect(content).to end_with("\r\n\r\nfrom=%2B447700900123&body=hi")
      expect(log.string).not_to include("447700900123")
    end

    it "answers 404 to any other path and saves nothing" do
      server, thread = start
      expect(post(server.port, "/wrong/inbound", "x=1").code).to eq("404")
      expect(post(server.port, "/#{secret}x/inbound", "x=1").code).to eq("404")
      expect(server.saved).to eq([])
      post(server.port, "/#{secret}/done", "x=1")
      thread.join(5)
    end

    it "rejects oversized and chunked bodies without saving them" do
      server, thread = start
      expect(post(server.port, "/#{secret}/inbound", "x" * (WebhookCapture::MAX_BODY_BYTES + 1)).code).to eq("400")
      # A raw socket: WebMock's Net::HTTP adapter would rewrite a chunked body.
      socket = TCPSocket.new("127.0.0.1", server.port)
      socket.write("POST /#{secret}/inbound HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nx=1\r\n0\r\n\r\n")
      expect(socket.read).to start_with("HTTP/1.1 400 ")
      socket.close
      expect(server.saved).to eq([])
      post(server.port, "/#{secret}/done", "x=1")
      thread.join(5)
      expect(log.string).to include("body over", "chunked bodies are not supported")
    end

    it "can answer saved requests with another status, to observe ClickSend's retries" do
      server = described_class.new(secret: secret, dir: @dir, port: 0, status: "500 Internal Server Error", log: log)
      thread = Thread.new { server.run(limit: 1) }
      expect(post(server.port, "/#{secret}/receipt", "x=1").code).to eq("500")
      thread.join(5)
      expect(server.saved.size).to eq(1)
      expect { described_class.new(secret: secret, dir: @dir, port: 0, status: "500\r\nX: y") }.to raise_error(ArgumentError)
    end

    it "refuses a short or unsafe secret" do
      ["short", "has spaces in it, sixteen+", "x" * 15].each do |bad|
        expect { described_class.new(secret: bad, dir: @dir, port: 0) }.to raise_error(ArgumentError)
      end
    end
  end
end
