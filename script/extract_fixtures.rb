# frozen_string_literal: true

# Regenerates spec/fixtures/*.json from the examples in ClickSend's
# published OpenAPI files (run script/fetch_openapi.rb first).
#
# When an operation's response schema carries a complete example, it is
# copied verbatim. Otherwise the fixture is assembled from the per-property
# examples in the schema. Either way the content is ClickSend's, not ours;
# spec/fixtures/README.md records which is which.

require "json"
require "yaml"

SPEC_DIR = File.expand_path("../tmp/openapi", __dir__)
OUT_DIR = File.expand_path("../spec/fixtures", __dir__)

FIXTURES = {
  "account" => ["accounts/management.yaml", "/v3/account", "get"],
  "sms_send" => ["messaging/sms.yaml", "/v3/sms/send", "post"],
  "sms_receipts" => ["messaging/sms.yaml", "/v3/sms/receipts", "get"],
  "sms_receipt" => ["messaging/sms.yaml", "/v3/sms/receipts/{message_id}", "get"],
  "sms_receipts_read" => ["messaging/sms.yaml", "/v3/sms/receipts-read", "put"],
  "sms_inbound" => ["messaging/sms.yaml", "/v3/sms/inbound", "get"],
  "sms_inbound_read" => ["messaging/sms.yaml", "/v3/sms/inbound-read", "put"],
  "sms_inbound_message_read" => ["messaging/sms.yaml", "/v3/sms/inbound-read/{message_id}", "put"]
}.freeze

def resolve(document, schema)
  return schema unless schema.is_a?(Hash) && schema["$ref"]

  resolve(document, schema["$ref"].delete_prefix("#/").split("/").reduce(document) { |node, key| node.fetch(key) })
end

def example_for(document, schema)
  schema = resolve(document, schema)
  return schema["example"] if schema.key?("example")

  if schema["allOf"]
    schema["allOf"].map { |part| example_for(document, part) }.grep(Hash).reduce({}, :merge)
  elsif schema["type"] == "object" || schema["properties"]
    (schema["properties"] || {}).to_h { |name, property| [name, example_for(document, property)] }
  elsif schema["type"] == "array"
    item = example_for(document, schema["items"] || {})
    item.nil? ? [] : [item]
  end
end

sources = {}
FIXTURES.each do |name, (file, path, verb)|
  document = YAML.load_file(File.join(SPEC_DIR, file))
  schema = resolve(document, document.dig("paths", path, verb, "responses", "200", "content", "application/json", "schema"))
  sources[name] = schema.key?("example") ? "verbatim" : "assembled from property examples"
  File.write(File.join(OUT_DIR, "#{name}.json"), "#{JSON.pretty_generate(example_for(document, schema))}\n")
  puts "#{name}: #{verb.upcase} #{path} (#{sources[name]})"
end
