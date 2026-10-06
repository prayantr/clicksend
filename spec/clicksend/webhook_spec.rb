# frozen_string_literal: true

RSpec.describe Clicksend::Webhook do
  let(:receipt_params) { fixture("webhook_receipt") }   # form-encoded: every value a String
  let(:inbound_params) { fixture("webhook_inbound") }

  # What ActionController::Parameters looks like to the gem.
  def rails_params(hash)
    Struct.new(:params) { def to_unsafe_h = params }.new(hash)
  end

  def invalid(&block)
    expect(&block).to raise_error(described_class::InvalidPayload)
  end

  describe ".parse_receipt" do
    it "parses a form-encoded push (all Strings, as Rack gives them)" do
      receipt = described_class.parse_receipt(receipt_params)

      expect(receipt).to be_a(Clicksend::SMS::Receipt)
      expect(receipt).to have_attributes(
        message_id: "4C0F2D1E-7A3B-4E5F-9A8B-0C1D2E3F4A5B", status_code: 201,
        status_text: "Success: Message received on handset.", error_code: nil, error_text: "",
        custom_string: "order-1042", message_type: "sms", subaccount_id: 100_002,
        sent_at: Time.at(1_759_730_400).utc, reported_at: Time.at(1_759_730_412).utc
      )
      expect(receipt).to be_delivered
    end

    it "keeps the archived push-only fields (status, user_id) in raw" do
      raw = described_class.parse_receipt(receipt_params).raw
      expect(raw).to include("status" => "Delivered", "user_id" => "100001")
      expect(raw).to eq(receipt_params)
    end

    it "gives the same model the poll endpoint would for the same fields" do
      expect(described_class.parse_receipt(receipt_params)).to eq(Clicksend::SMS::Receipt.from_api(receipt_params))
    end

    it "parses a JSON-decoded Hash with Integer values (ClickSend's poll example)" do
      payload = fixture("sms_receipt")["data"]
      receipt = described_class.parse_receipt(payload)

      expect(receipt).to eq(Clicksend::SMS::Receipt.from_api(payload))
      expect(receipt).to have_attributes(status_code: 201, subaccount_id: 123_456, error_code: nil)
    end

    it "accepts Symbol keys" do
      expect(described_class.parse_receipt(receipt_params.transform_keys(&:to_sym)))
        .to eq(described_class.parse_receipt(receipt_params))
    end

    it "accepts Rails parameters (anything with to_unsafe_h) and drops Rails' routing keys from raw" do
      routed = receipt_params.merge("controller" => "clicksend", "action" => "receipt", "format" => "html")
      receipt = described_class.parse_receipt(rails_params(routed))

      expect(receipt.raw).to eq(receipt_params)
      expect(receipt).to eq(described_class.parse_receipt(receipt_params))
    end

    it "drops routing keys given as Symbols in a plain Hash too" do
      expect(described_class.parse_receipt(receipt_params.merge(controller: "x", action: "y")).raw).to eq(receipt_params)
    end

    it "requires an integer status_code" do
      invalid { described_class.parse_receipt(receipt_params.except("status_code")) }
      invalid { described_class.parse_receipt(receipt_params.merge("status_code" => "")) }
      invalid { described_class.parse_receipt(receipt_params.merge("status_code" => "Delivered")) }
      expect { described_class.parse_receipt(receipt_params.except("status_code")) }
        .to raise_error(described_class::InvalidPayload, "delivery receipt: status_code is missing or not an integer")
    end

    it "returns frozen values without freezing the caller's Strings" do
      receipt = described_class.parse_receipt(receipt_params)

      expect(receipt).to be_frozen
      expect(receipt.raw).to be_frozen
      expect(receipt.raw.values).to all(be_frozen)
      expect(receipt_params.values.grep(String).none?(&:frozen?)).to be(true)
    end
  end

  describe ".parse_inbound" do
    it "parses a form-encoded push" do
      message = described_class.parse_inbound(inbound_params)

      expect(message).to be_a(Clicksend::SMS::InboundMessage)
      expect(message).to have_attributes(
        message_id: "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A", from: "+447777777777", to: "+61411111111",
        body: "Yes please, Thursday works", original_message_id: "4C0F2D1E-7A3B-4E5F-9A8B-0C1D2E3F4A5B",
        original_body: "Can we confirm your appointment on Thursday? Reply YES or NO",
        custom_string: "order-1042", received_at: Time.at(1_759_730_500).utc
      )
      expect(message.raw).to include("user_id" => "100001", "subaccount_id" => "100002")
      expect(message).to be_frozen
    end

    it "gives the same model the poll endpoint would, including ClickSend's own inbound example" do
      poll_item = fixture("sms_inbound")["data"]["data"].first

      expect(described_class.parse_inbound(inbound_params)).to eq(Clicksend::SMS::InboundMessage.from_api(inbound_params))
      expect(described_class.parse_inbound(poll_item)).to eq(Clicksend::SMS::InboundMessage.from_api(poll_item))
    end

    it "accepts an empty body" do
      expect(described_class.parse_inbound(inbound_params.merge("body" => "")).body).to eq("")
    end

    it "requires from (non-empty) and body (a String)" do
      [
        inbound_params.except("from"), inbound_params.merge("from" => ""), inbound_params.merge("from" => 447_777_777_777),
        inbound_params.except("body"), inbound_params.merge("body" => nil), inbound_params.merge("body" => 42)
      ].each { |payload| invalid { described_class.parse_inbound(payload) } }
    end
  end

  describe ".parse" do
    it "detects a delivery receipt" do
      expect(described_class.parse(receipt_params)).to eq(described_class.parse_receipt(receipt_params))
    end

    it "detects an inbound message" do
      expect(described_class.parse(inbound_params)).to eq(described_class.parse_inbound(inbound_params))
    end

    it "detects with Symbol keys and Rails parameters" do
      expect(described_class.parse(inbound_params.transform_keys(&:to_sym))).to be_a(Clicksend::SMS::InboundMessage)
      expect(described_class.parse(rails_params(receipt_params))).to be_a(Clicksend::SMS::Receipt)
    end

    it "refuses to guess when the fields fit both or neither" do
      [
        receipt_params.merge("body" => "hi"),
        inbound_params.merge("status_code" => "201"),
        inbound_params.except("body"),
        {"message_id" => "4C0F2D1E-7A3B-4E5F-9A8B-0C1D2E3F4A5B"}
      ].each do |payload|
        expect { described_class.parse(payload) }.to raise_error(
          described_class::InvalidPayload,
          "cannot tell whether this is a delivery receipt or an inbound message; use parse_receipt or parse_inbound"
        )
      end
    end

    it "still validates the detected type" do
      invalid { described_class.parse(receipt_params.merge("status_code" => "x")) }
      invalid { described_class.parse(inbound_params.merge("from" => "")) }
    end
  end

  describe "validation" do
    %i[parse parse_receipt parse_inbound].each do |method|
      it "#{method} rejects anything that is not a Hash or Rails parameters" do
        [nil, "message_id=X", [["message_id", "X"]], Object.new, rails_params("not a hash")].each do |params|
          invalid { described_class.public_send(method, params) }
        end
      end

      it "#{method} requires a message_id that is safe to put in an API path" do
        params = (method == :parse_receipt) ? receipt_params : inbound_params
        [nil, "", "../../v3/account", "4C0F2D1E/7A3B", "ID WITH SPACES", "ID\n", 12_345].each do |id|
          expect { described_class.public_send(method, params.merge("message_id" => id)) }
            .to raise_error(described_class::InvalidPayload, "message_id is missing or not a ClickSend message ID")
        end
        invalid { described_class.public_send(method, params.except("message_id")) }
      end
    end

    it "rejects non-scalar values in the fields it reads" do
      [{"a" => "b"}, ["x"], Object.new].each do |value|
        invalid { described_class.parse_receipt(receipt_params.merge("status_code" => value)) }
        invalid { described_class.parse_inbound(inbound_params.merge("body" => value)) }
      end
    end

    it "leaves other non-scalar values out of raw, such as the copy Rails' ParamsWrapper nests into JSON requests" do
      wrapped = inbound_params.merge("clicksend_webhook" => inbound_params, "media" => ["x"], "file" => Object.new)
      message = described_class.parse_inbound(wrapped)
      expect(message.body).to eq(inbound_params["body"])
      expect(message.raw.keys).to match_array(inbound_params.keys)
    end

    it "accepts JSON scalars in fields the gem does not read" do
      payload = receipt_params.merge("flag" => true, "ratio" => 0.5, "nothing" => nil)
      expect(described_class.parse_receipt(payload).raw).to include("flag" => true, "ratio" => 0.5, "nothing" => nil)
    end

    it "rejects keys that are neither Strings nor Symbols, and a key given both ways" do
      invalid { described_class.parse_receipt(receipt_params.merge(1 => "x")) }
      invalid { described_class.parse_receipt(receipt_params.merge(message_id: "4C0F2D1E-7A3B-4E5F-9A8B-0C1D2E3F4A5B")) }
    end

    it "is a Clicksend::Error" do
      expect(described_class::InvalidPayload.ancestors).to include(Clicksend::Error)
    end
  end

  describe "size limits" do
    it "accepts up to MAX_FIELDS keys and rejects more" do
      padding = (receipt_params.size...described_class::MAX_FIELDS).to_h { |i| ["x#{i}", "y"] }
      expect(described_class.parse_receipt(receipt_params.merge(padding)).raw.size).to eq(described_class::MAX_FIELDS)
      expect { described_class.parse_receipt(receipt_params.merge(padding, "one_more" => "y")) }
        .to raise_error(described_class::InvalidPayload, "payload has more than 64 fields")
    end

    it "accepts values up to MAX_BYTES bytes and rejects longer ones, counting bytes not characters" do
      expect(described_class.parse_inbound(inbound_params.merge("body" => "a" * 10_000)).body.bytesize).to eq(10_000)
      invalid { described_class.parse_inbound(inbound_params.merge("body" => "a" * 10_001)) }
      invalid { described_class.parse_inbound(inbound_params.merge("body" => "é" * 5_001)) }
      invalid { described_class.parse_inbound(inbound_params.merge("k" * 10_001 => "v")) }
    end
  end

  describe "error messages" do
    it "never contain values from the payload" do
      secret_values = inbound_params.values + receipt_params.values + ["../../v3/account"]
      failures = [
        -> { described_class.parse_inbound(inbound_params.merge("from" => "")) },
        -> { described_class.parse_inbound(inbound_params.except("body")) },
        -> { described_class.parse_inbound(inbound_params.merge("message_id" => "../../v3/account")) },
        -> { described_class.parse_inbound(inbound_params.merge("body" => "Yes please, Thursday works" * 500)) },
        -> { described_class.parse_inbound(inbound_params.merge("from" => {"from" => "+447777777777"})) },
        -> { described_class.parse_inbound(inbound_params.merge(from: "+447777777777")) },
        -> { described_class.parse(inbound_params.merge("status_code" => "201")) },
        -> { described_class.parse_receipt(receipt_params.merge("status_code" => "Delivered")) },
        -> { described_class.parse_receipt("message_id=4C0F2D1E&from=%2B447777777777") }
      ]

      failures.each do |failure|
        expect(&failure).to raise_error(described_class::InvalidPayload) { |error|
          leaked = secret_values.grep(String).reject(&:empty?).select { |value| error.message.include?(value) }
          expect(leaked).to eq([]), "#{error.message.inspect} leaks #{leaked.inspect}"
          expect(error.message).not_to include("+447777777777")
        }
      end
    end
  end
end

RSpec.describe Clicksend::Webhook, "encodings" do
  let(:inbound) { {"message_id" => "ABC-1", "from" => "+61411111111", "body" => "hi"} }

  it "accepts binary Strings holding valid UTF-8, as Rack may provide them, and returns UTF-8" do
    message = described_class.parse_inbound(inbound.merge("body" => "caf\xC3\xA9".b))
    expect(message.body).to eq("café")
    expect(message.body.encoding).to eq(Encoding::UTF_8)
    expect(JSON.generate(message.raw)).to include("café")
  end

  it "converts other encodings to UTF-8" do
    message = described_class.parse_inbound(inbound.merge("body" => "café".encode("UTF-16LE")))
    expect(message.body).to eq("café")
  end

  it "rejects invalid byte sequences in values and keys as InvalidPayload, never ArgumentError" do
    expect { described_class.parse_inbound(inbound.merge("message_id" => "\xFF\xFE".b)) }.to raise_error(Clicksend::Webhook::InvalidPayload, /UTF-8/)
    expect { described_class.parse_inbound(inbound.merge("body" => "bad \xFF".dup.force_encoding("UTF-8"))) }.to raise_error(Clicksend::Webhook::InvalidPayload, /UTF-8/)
    expect { described_class.parse(inbound.merge("\xFF".b => "x")) }.to raise_error(Clicksend::Webhook::InvalidPayload, /UTF-8/)
  end
end

RSpec.describe Clicksend::Webhook, "unconvertible encodings" do
  it "reports a value that cannot be converted to UTF-8 as InvalidPayload" do
    unconvertible = "\xA4".dup.force_encoding("EUC-JP") # an incomplete EUC-JP sequence: Encoding::InvalidByteSequenceError on encode
    payload = {"message_id" => "ABC-1", "from" => "+61411111111", "body" => unconvertible}
    expect { described_class.parse_inbound(payload) }.to raise_error(Clicksend::Webhook::InvalidPayload, /UTF-8/)
  end
end
