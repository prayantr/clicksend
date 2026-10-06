# frozen_string_literal: true

require_relative "../../script/webhook_capture"

# Replays every fixture in spec/fixtures/webhooks (see manifest.yml) through
# Rack's request parsing and Clicksend::Webhook. A redacted real capture added
# to captured/ and the manifest is covered here with no new spec code.
RSpec.describe "Webhook replay fixtures" do
  manifest = WebhookReplay.manifest
  kinds = {"receipt" => [:parse_receipt, Clicksend::SMS::Receipt], "inbound" => [:parse_inbound, Clicksend::SMS::InboundMessage]}

  def expected_value(attribute, value)
    (attribute.end_with?("_at") && value) ? Time.at(value).utc : value
  end

  manifest.each do |entry|
    describe entry.fetch("file") do
      let(:capture) { WebhookReplay.load(entry.fetch("file")) }
      let(:params) { WebhookReplay.params(capture) }
      let(:method_name) { kinds.fetch(entry.fetch("kind")).first }

      it "parses with #{kinds.fetch(entry.fetch("kind")).first} into the expected model" do
        model = Clicksend::Webhook.public_send(method_name, params)

        expect(model).to be_a(kinds.fetch(entry.fetch("kind")).last)
        entry.fetch("expect").each do |attribute, value|
          expect(model.public_send(attribute)).to eq(expected_value(attribute, value)), attribute
        end
      end

      it "keeps the fields the gem does not read in raw" do
        raw = Clicksend::Webhook.public_send(method_name, params).raw
        expect(raw).to include(entry.fetch("raw"))
        expect(raw).to eq(params)
      end

      it "is detected as #{entry.fetch("kind")} by Webhook.parse" do
        expect(Clicksend::Webhook.parse(params)).to eq(Clicksend::Webhook.public_send(method_name, params))
      end

      it "parses the same from Rails' request_parameters (ParamsWrapper's nested copy for JSON)" do
        rails = WebhookReplay.rails_request_parameters(capture)
        expect(Clicksend::Webhook.public_send(method_name, rails)).to eq(Clicksend::Webhook.public_send(method_name, params))
      end

      it "has a label, a source and a note" do
        expect(%w[captured first_party archived documented synthetic]).to include(entry.fetch("label"))
        expect(entry.fetch("source")).to match(%r{\Ahttps://})
        expect(entry.fetch("note").to_s.strip).not_to be_empty
      end
    end
  end

  describe "fixture hygiene" do
    files = Dir.glob("**/*", base: WebhookReplay::DIR).reject { |file| File.directory?(File.join(WebhookReplay::DIR, file)) }
    fixtures = files.grep(/\.(form|query|json|http)\z/)

    it "every fixture is in the manifest, and every manifest entry exists" do
      expect(fixtures).to match_array(manifest.map { |entry| entry.fetch("file") })
    end

    it "contains no other files than fixtures, the manifest and READMEs" do
      expect(files - fixtures).to all(match(/\A(manifest\.yml|(\w+\/)?README\.md)\z/))
    end

    fixtures.each do |file|
      it "#{file} holds no phone number other than ClickSend's documented test numbers" do
        values = WebhookReplay.params(WebhookReplay.load(file)).values.grep(String)
        numbers = values.flat_map { |value| value.scan(/\+\d{7,15}/) }
        expect(numbers - WebhookCapture::TEST_NUMBERS).to eq([])
        WebhookCapture::PHONE_FIELDS.each do |field|
          value = WebhookReplay.params(WebhookReplay.load(file))[field]
          expect(WebhookCapture::TEST_NUMBERS).to include(value) if value
        end
      end

      it "#{file} carries no secret, address or credential in its request line or headers" do
        capture = WebhookReplay.load(file)
        expect(capture.target).to start_with("/clicksend/:secret/")
        expect(capture.target).not_to match(/[?&](token|secret|key|k)=/i)
        capture.headers.each do |name, value|
          expect(value).to eq(WebhookCapture::REDACTED), name unless WebhookCapture::KEPT_HEADERS.include?(name.downcase)
        end
      end
    end
  end
end
