# frozen_string_literal: true

# ClickSend's current docs define no push (webhook) payload. Clicksend::Webhook
# reads the field names of the poll schemas, which the archived push docs
# agree with, so a rename in those schemas must fail here (weekly contract job).
require_relative "../../script/openapi_fixtures"

module WebhookContract
  # Every field Clicksend::Webhook (through SMS::Receipt / SMS::InboundMessage)
  # reads from a push.
  READS = {
    "sms_receipt" => %w[message_id status_code status_text error_code error_text custom_string message_type subaccount_id timestamp_send timestamp],
    "inbound_sms" => %w[message_id from to body original_body original_message_id custom_string timestamp]
  }.freeze

  # Listed only in the archived push docs, so expected in pushes but absent
  # from the current schemas. Kept in #raw; never read into model fields.
  ARCHIVED_ONLY = {
    "sms_receipt" => %w[status user_id],
    "inbound_sms" => %w[user_id subaccount_id]
  }.freeze

  FIXTURES = {"sms_receipt" => "webhook_receipt", "inbound_sms" => "webhook_inbound"}.freeze
end

RSpec.describe "ClickSend webhook fields contract", :contract do
  def schema_fields(component)
    OpenAPIFixtures.document("messaging/sms.yaml").dig("components", "schemas", component, "properties").keys
  end

  WebhookContract::READS.each do |component, fields|
    it "every field read from a push is in ClickSend's current #{component} schema" do
      expect(fields - schema_fields(component)).to eq([])
    end

    it "the fields read for #{component} populate every model attribute" do
      payload = fields.to_h { |field| [field, (field == "message_id") ? "A1B2-C3" : "1"] }
      model = (component == "sms_receipt") ? Clicksend::Webhook.parse_receipt(payload) : Clicksend::Webhook.parse_inbound(payload)
      expect(model.to_h.except(:raw).select { |_, value| value.nil? }.keys).to eq([])
    end

    it "the #{WebhookContract::FIXTURES[component]} fixture differs from #{component} only by the archived push-only fields" do
      fixture = JSON.parse(File.read(File.join(OpenAPIFixtures::OUT_DIR, "#{WebhookContract::FIXTURES[component]}.json")))
      expect((fixture.keys - schema_fields(component)).sort).to eq(WebhookContract::ARCHIVED_ONLY[component].sort),
        "ClickSend's schema changed: revisit ARCHIVED_ONLY and the fixture"
    end
  end
end
