# frozen_string_literal: true

# Checks this gem against ClickSend's published OpenAPI files, downloaded by
# `bundle exec rake contract` (needs network; no credentials). Excluded from
# the default suite.
require "json_schemer"
require_relative "../../script/openapi_fixtures"

module OpenAPIContract
  # Every operation this gem wraps, with the query parameters it may send.
  OPERATIONS = [
    ["accounts/management.yaml", "get", "/v3/account", []],
    ["messaging/sms.yaml", "post", "/v3/sms/send", []],
    ["messaging/sms.yaml", "get", "/v3/sms/receipts", %w[page limit]],
    ["messaging/sms.yaml", "get", "/v3/sms/receipts/{message_id}", []],
    ["messaging/sms.yaml", "put", "/v3/sms/receipts-read", []],
    ["messaging/sms.yaml", "get", "/v3/sms/inbound", %w[page limit]],
    ["messaging/sms.yaml", "put", "/v3/sms/inbound-read", []],
    ["messaging/sms.yaml", "put", "/v3/sms/inbound-read/{message_id}", []],
    ["messaging/sms.yaml", "get", "/v3/sms/history", %w[page limit q order_by date_from date_to]]
  ].freeze

  # Fields SMS::HistoryRecord reads from a history row.
  HISTORY_FIELDS = %w[
    message_id direction status status_code status_text error_code error_text to from body message_parts
    message_price custom_string list_id country carrier date schedule
  ].freeze

  # Fields SMS::Message and SMS::Batch read from a POST /v3/sms/send result.
  # +status+ and +message_id+ matter most: a missing status is treated as an
  # unknown outcome, so a rename would turn every send into an ambiguous error.
  SEND_MESSAGE_FIELDS = %w[
    message_id status to from body message_parts message_price custom_string list_id country carrier date schedule
  ].freeze
  SEND_RESULT_FIELDS = %w[messages total_price total_count queued_count blocked_count _currency].freeze

  # The q=field:value fields sms.history lets callers filter on.
  HISTORY_FILTERS = %w[to from status message_id].freeze

  # Places where ClickSend's own examples contradict its own schemas. The gem
  # tolerates both forms (see Clicksend::Model). This list must match exactly,
  # so it is revisited whenever ClickSend fixes or changes something.
  KNOWN_SPEC_INCONSISTENCIES = {
    "account" => ["/data/balance_commission"],           # number in example, string in schema
    "sms_send" => ["/data/messages/0/date"],             # "1721099039," in example, integer in schema
    "sms_receipts" => ["/data/data/0/status_code", "/data/data/0/digits"], # "201" vs integer; null vs non-nullable
    "sms_receipt" => ["/data/status_code", "/data/digits"]
  }.freeze
end

RSpec.describe "ClickSend OpenAPI contract", :contract do
  def self.pointer(*parts)
    "#/" + parts.map { |part| part.gsub("~", "~0").gsub("/", "~1").gsub("{", "%7B").gsub("}", "%7D") }.join("/")
  end

  def openapi(file)
    @openapi ||= {}
    @openapi[file] ||= JSONSchemer.openapi(OpenAPIFixtures.document(file))
  end

  def schema(file, *parts)
    openapi(file).ref(self.class.pointer(*parts))
  end

  def operation(file, verb, path)
    OpenAPIFixtures.document(file).dig("paths", path, verb)
  end

  describe "wrapped operations" do
    OpenAPIContract::OPERATIONS.each do |file, verb, path, query_params|
      it "#{verb.upcase} #{path} exists with the query parameters we send" do
        op = operation(file, verb, path)
        expect(op).not_to be_nil, "#{verb.upcase} #{path} is no longer in #{file}"
        declared = (op["parameters"] || []).select { |param| param["in"] == "query" }.map { |param| param["name"] }
        expect(query_params - declared).to eq([])
      end
    end
  end

  describe "send results" do
    let(:sms_doc) { OpenAPIFixtures.document("messaging/sms.yaml") }
    let(:result) { OpenAPIFixtures.resolve(sms_doc, OpenAPIFixtures.response_schema(sms_doc, "/v3/sms/send", "post").dig("properties", "data")) }
    let(:message) { OpenAPIFixtures.resolve(sms_doc, OpenAPIFixtures.resolve(sms_doc, result.dig("properties", "messages"))["items"]) }

    it "documents every field SMS::Batch reads" do
      expect(OpenAPIContract::SEND_RESULT_FIELDS - result["properties"].keys).to eq([])
    end

    it "documents every field SMS::Message reads" do
      expect(OpenAPIContract::SEND_MESSAGE_FIELDS - message["properties"].keys).to eq([])
    end

    it "documents the per-message status and message ID as strings" do
      expect(message.dig("properties", "status", "type")).to eq("string")
      expect(message.dig("properties", "message_id", "type")).to eq("string")
    end
  end

  describe "list page sizes" do
    %w[/v3/sms/receipts /v3/sms/inbound].each do |path|
      it "keeps the page-size range Page enforces for #{path}" do
        limit = operation("messaging/sms.yaml", "get", path)["parameters"].find { |param| param["name"] == "limit" }["schema"]
        expect([limit["minimum"], limit["maximum"]]).to eq([Clicksend::Page::LIMITS.min, Clicksend::Page::LIMITS.max])
      end
    end
  end

  describe "SMS history" do
    let(:history_op) { operation("messaging/sms.yaml", "get", "/v3/sms/history") }

    it "documents every field SMS::HistoryRecord reads" do
      item = OpenAPIFixtures.response_schema(OpenAPIFixtures.document("messaging/sms.yaml"), "/v3/sms/history", "get")
        .dig("properties", "data", "allOf", 1, "properties", "data", "items", "properties")
      expect(OpenAPIContract::HISTORY_FIELDS - item.keys).to eq([])
    end

    it "documents each q filter sms.history offers, and still not custom_string" do
      q = history_op["parameters"].find { |param| param["name"] == "q" }["description"]
      OpenAPIContract::HISTORY_FILTERS.each { |field| expect(q).to match(/_#{field}_/i), "q no longer documents #{field}" }
      expect(q).not_to match(/custom_string/), "ClickSend now documents custom_string as a filter: offer it in sms.history"
    end

    it "documents date ordering in the form sms.history sends" do
      order_by = history_op["parameters"].find { |param| param["name"] == "order_by" }
      expect(order_by.dig("schema", "default")).to eq("date:asc")
    end

    it "keeps the documented page-size range Page enforces" do
      limit = history_op["parameters"].find { |param| param["name"] == "limit" }["schema"]
      expect([limit["minimum"], limit["maximum"]]).to eq([Clicksend::Page::LIMITS.min, Clicksend::Page::LIMITS.max])
    end
  end

  describe "request bodies built by the gem" do
    # Runs the block against a fake transport and returns the JSON body sent.
    def sent_body
      transport = FakeTransport.new(FakeTransport.json(200, envelope(nil)))
      begin
        yield client(transport: transport)
      rescue Clicksend::MalformedResponseError
        # The canned response isn't a send result; only the request matters here.
      end
      JSON.parse(transport.calls.last.body)
    end

    def expect_valid(body, path, verb = "post")
      errors = schema("messaging/sms.yaml", "paths", path, verb, "requestBody", "content", "application/json", "schema").validate(body).to_a
      expect(errors.map { |error| error["error"] }).to eq([])
    end

    it "deliver with only required fields" do
      expect_valid(sent_body { |c| c.sms.deliver(to: "+61411111111", body: "hi") }, "/v3/sms/send")
    end

    it "deliver with every optional field" do
      body = sent_body do |c|
        c.sms.deliver(to: "+61411111111", body: "hi", from: "Acme", schedule: Time.now + 60, custom_string: "ref",
          country: "AU", source: "app", from_email: "ops@example.com", shorten_urls: true)
      end
      expect_valid(body, "/v3/sms/send")
    end

    it "deliver_batch with recipients, a list and defaults" do
      body = sent_body do |c|
        c.sms.deliver_batch([{to: "+61411111111", body: "a"}, {list_id: "428", body: "b", exclude_no_sender_id_recipients: true}],
          from: "Acme", schedule: 1_900_000_000)
      end
      expect_valid(body, "/v3/sms/send")
    end

    it "mark_receipts_read and mark_inbound_read, with and without a cutoff" do
      expect_valid(sent_body { |c| c.sms.mark_receipts_read }, "/v3/sms/receipts-read", "put")
      expect_valid(sent_body { |c| c.sms.mark_receipts_read(before: Time.now) }, "/v3/sms/receipts-read", "put")
      expect_valid(sent_body { |c| c.sms.mark_inbound_read(before: Time.now) }, "/v3/sms/inbound-read", "put")
    end
  end

  describe "fixtures" do
    OpenAPIFixtures::FIXTURES.each do |name, (file, path, verb)|
      it "#{name}.json matches ClickSend's current example for #{verb.upcase} #{path}" do
        committed = JSON.parse(File.read(File.join(OpenAPIFixtures::OUT_DIR, "#{name}.json")))
        expect(committed).to eq(OpenAPIFixtures.generate(name).first),
          "ClickSend changed this example; run `ruby script/openapi_fixtures.rb` and review the diff"
      end

      it "#{name}.json conforms to the response schema, apart from known inconsistencies" do
        fixture = JSON.parse(File.read(File.join(OpenAPIFixtures::OUT_DIR, "#{name}.json")))
        response_schema = schema(file, "paths", path, verb, "responses", "200", "content", "application/json", "schema")
        mismatches = response_schema.validate(fixture).map { |error| error["data_pointer"] }.uniq.sort
        expect(mismatches).to eq(OpenAPIContract::KNOWN_SPEC_INCONSISTENCIES.fetch(name, []).sort)
      end
    end
  end
end
