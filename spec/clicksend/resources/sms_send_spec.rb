# frozen_string_literal: true

RSpec.describe Clicksend::Resources::SMS, "sending" do
  def message_payload(to:, status: "SUCCESS", message_id: "MSG-#{to}", **extra)
    {"direction" => "out", "date" => 1_721_099_039, "to" => to, "body" => "hi", "from" => "Acme", "schedule" => "",
     "message_id" => message_id, "message_parts" => 1, "message_price" => "0.0792", "custom_string" => "",
     "country" => "AU", "carrier" => "Telstra", "status" => status}.merge(extra.transform_keys(&:to_s))
  end

  def send_response(messages, queued: nil, blocked: 0)
    queued ||= messages.count { |m| m["status"] == "SUCCESS" }
    envelope({"total_price" => 0.0792 * queued, "total_count" => messages.size, "queued_count" => queued,
              "messages" => messages, "_currency" => {"currency_name_short" => "AUD"}, "blocked_count" => blocked},
      response_msg: "Messages queued for delivery.")
  end

  describe "#deliver" do
    it "sends one message and returns its result (ClickSend's documented example)" do
      stub = stub_api(:post, "/v3/sms/send", body: {messages: [{to: "+61411111111", body: "test message"}]})
        .with(headers: {"Content-Type" => "application/json"})
        .to_return(json_response(fixture("sms_send")))

      message = client.sms.deliver(to: "+61411111111", body: "test message")

      expect(stub).to have_been_requested.once
      expect(message).to be_a(Clicksend::SMS::Message).and(be_queued)
      expect(message).to have_attributes(
        message_id: "1ABC3200-C38C-6308-BE4B-C7C51D01DCF0", status: "SUCCESS", to: "+61411111111",
        from: "+61431111112", body: "test message", parts: 1, price: "0.0792", country: "AU", carrier: "Vodafone",
        scheduled_at: Time.at(1_721_099_039).utc
      )
      # The published example's "date" is "1721099039," (not an integer); it is kept in raw.
      expect(message.sent_at).to be_nil
      expect(message.raw["date"]).to eq("1721099039,")
    end

    it "sends optional fields and converts schedule times to Unix timestamps" do
      at = Time.utc(2026, 10, 6, 9, 0, 0)
      stub = stub_api(:post, "/v3/sms/send", body: {
        messages: [{to: "+61411111111", body: "hi", from: "Acme", schedule: at.to_i, custom_string: "otp:42",
                    country: "AU", source: "my-app", from_email: "ops@example.com"}],
        shorten_urls: true
      }).to_return(json_response(send_response([message_payload(to: "+61411111111", schedule: at.to_i, date: "1721099039")])))

      message = client.sms.deliver(to: "+61411111111", body: "hi", from: "Acme", schedule: at, custom_string: "otp:42",
        country: "AU", source: "my-app", from_email: "ops@example.com", shorten_urls: true)

      expect(stub).to have_been_requested
      expect(message.scheduled_at).to eq(at)
      expect(message.sent_at).to eq(Time.at(1_721_099_039).utc)
    end

    it "raises MessageRejected when ClickSend does not accept the message, despite HTTP 200" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([message_payload(to: "+6100", status: "INVALID_RECIPIENT")])))

      expect { client.sms.deliver(to: "+6100", body: "hi") }.to raise_error(Clicksend::MessageRejected) { |error|
        expect(error.status).to eq("INVALID_RECIPIENT")
        expect(error.result).to be_a(Clicksend::SMS::Message)
        expect(error.message).to eq("ClickSend rejected the message: INVALID_RECIPIENT (POST /v3/sms/send)")
        expect(error.request.operation).to eq("sms.deliver")
      }
    end

    it "maps HTTP-level failures to typed errors" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(
        envelope(nil, http_code: 400, response_code: "MISSING_REQUIRED_FIELDS", response_msg: "Missing fields."), status: 400
      ))
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }
        .to raise_error(Clicksend::BadRequestError) { |e| expect(e.response_code).to eq("MISSING_REQUIRED_FIELDS") }
    end

    it "is attempted exactly once when the response times out" do
      allow(Kernel).to receive(:sleep)
      stub = stub_api(:post, "/v3/sms/send").to_raise(Net::ReadTimeout)
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }
        .to raise_error(Clicksend::AmbiguousRequestError) { |e|
          expect(e).to be_a(Clicksend::TimeoutError)
          expect(e.request_may_have_been_sent?).to be(true)
          expect(e.request.operation).to eq("sms.deliver")
        }
      expect(stub).to have_been_requested.once
    end

    it "raises MalformedResponseError when the result does not contain exactly one message" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([], blocked: 1)))
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }
        .to raise_error(Clicksend::MalformedResponseError, /Expected one message result, got 0 \(blocked_count: 1\)/)

      stub_api(:post, "/v3/sms/send").to_return(json_response(envelope({"total_count" => 1})))
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }.to raise_error(Clicksend::MalformedResponseError, /no messages list/)
    end

    it "treats an unreadable send result as ambiguous: ClickSend answered 2xx, so messages may have been queued" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([], blocked: 1)))
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }.to raise_error(Clicksend::AmbiguousRequestError) { |e|
        expect(e).to be_a(Clicksend::MalformedResponseError)
        expect(e.request).to have_attributes(path: "/v3/sms/send", operation: "sms.deliver", attempts: 1)
        expect(e.message).to end_with("(POST /v3/sms/send)")
      }

      stub_api(:post, "/v3/sms/send").to_return(json_response(envelope({"total_count" => 1})))
      expect { client.sms.deliver_batch([{to: "+61411111111", body: "hi"}]) }.to raise_error(Clicksend::AmbiguousRequestError) { |e|
        expect(e.request.operation).to eq("sms.deliver_batch")
      }

      stub_api(:post, "/v3/sms/send").to_return(status: 200, body: "<html>maintenance</html>")
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }.to raise_error(Clicksend::MalformedResponseError) { |e| expect(e).to be_ambiguous }
    end

    it "does not mark a rejected message ambiguous: ClickSend decided" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([message_payload(to: "+000", status: "INVALID_RECIPIENT")])))
      expect { client.sms.deliver(to: "+000", body: "hi") }.to raise_error(Clicksend::MessageRejected) { |e|
        expect(e).not_to be_ambiguous
        expect(e).not_to be_retryable
      }
    end

    it "validates arguments before calling ClickSend" do
      expect { client.sms.deliver(body: "hi") }.to raise_error(ArgumentError, /missing keyword: :to/)
      expect { client.sms.deliver(to: "+61411111111", body: nil) }.to raise_error(ArgumentError, /body must be a String/)
      expect { client.sms.deliver(to: 61_411_111_111, body: "hi") }.to raise_error(ArgumentError, /to must be a String/)
      expect { client.sms.deliver(to: "+61411111111", body: "hi", schedule: "tomorrow") }.to raise_error(ArgumentError, /message: expected a Time or Unix timestamp, got "tomorrow"/)
      expect { client.sms.deliver(to: "+61411111111", body: "hi", sender: "x") }.to raise_error(ArgumentError, /unknown keyword: :sender/)
      expect(a_request(:any, /clicksend/)).not_to have_been_made
    end
  end

  describe "#deliver_batch" do
    it "applies defaults to every message, letting each message override them" do
      stub = stub_api(:post, "/v3/sms/send", body: {messages: [
        {to: "+61411111111", body: "Hi Ann", from: "Acme"},
        {to: "+61422222222", body: "Hi Bob", from: "Other", custom_string: "bob"},
        {list_id: "428", body: "Hi all", from: "Acme"}
      ]}).to_return(json_response(send_response([
        message_payload(to: "+61411111111"), message_payload(to: "+61422222222"), message_payload(to: "+61433333333", list_id: 428)
      ])))

      batch = client.sms.deliver_batch([
        {to: "+61411111111", body: "Hi Ann"},
        {"to" => "+61422222222", "body" => "Hi Bob", "from" => "Other", "custom_string" => "bob"},
        {list_id: "428", body: "Hi all"}
      ], from: "Acme")

      expect(stub).to have_been_requested
      expect(batch).to be_a(Clicksend::SMS::Batch)
      expect(batch.size).to eq(3)
      expect(batch.all_queued?).to be(true)
      expect(batch.messages.last.list_id).to eq("428")
      expect(batch.currency).to eq("AUD")
      expect(batch.map(&:to)).to eq(%w[+61411111111 +61422222222 +61433333333])
      expect(batch.count(&:queued?)).to eq(3)
      expect(batch.each).to be_an(Enumerator)
      expect(batch.to_h.keys).to eq(%i[messages total_price total_count queued_count blocked_count currency raw])
    end

    it "reports partial failures without raising" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([
        message_payload(to: "+61411111111"),
        message_payload(to: "+6100", status: "INVALID_RECIPIENT", message_id: nil),
        message_payload(to: "+999", status: "COUNTRY_NOT_ENABLED", message_id: nil)
      ])))

      batch = client.sms.deliver_batch([{to: "+61411111111", body: "a"}, {to: "+6100", body: "b"}, {to: "+999", body: "c"}])

      expect(batch.all_queued?).to be(false)
      expect(batch.queued.map(&:to)).to eq(["+61411111111"])
      expect(batch.rejected.map { |m| [m.to, m.status] }).to eq([["+6100", "INVALID_RECIPIENT"], ["+999", "COUNTRY_NOT_ENABLED"]])
      expect(batch.queued_count).to eq(1)
      expect(batch.total_price).to eq("0.0792")
    end

    it "is not all_queued when ClickSend reports blocked messages" do
      stub_api(:post, "/v3/sms/send").to_return(json_response(send_response([message_payload(to: "+61411111111")], blocked: 1)))
      expect(client.sms.deliver_batch([{to: "+61411111111", body: "a"}, {to: "+61422222222", body: "b"}]).all_queued?).to be(false)
    end

    it "validates messages and defaults before calling ClickSend" do
      expect { client.sms.deliver_batch([]) }.to raise_error(ArgumentError, /non-empty Array/)
      expect { client.sms.deliver_batch({to: "+61411111111", body: "a"}) }.to raise_error(ArgumentError, /non-empty Array/)
      expect { client.sms.deliver_batch(["+61411111111"]) }.to raise_error(ArgumentError, /messages\[0\] must be a Hash/)
      expect { client.sms.deliver_batch([{to: "+61411111111", body: "a"}, {body: "b"}]) }
        .to raise_error(ArgumentError, /messages\[1\]: provide exactly one of to: or list_id:/)
      expect { client.sms.deliver_batch([{to: "+61411111111", list_id: "1", body: "b"}]) }.to raise_error(ArgumentError, /exactly one/)
      expect { client.sms.deliver_batch([{to: "+61411111111", message: "b"}]) }
        .to raise_error(ArgumentError, /messages\[0\]: unknown field\(s\) :message/)
      expect { client.sms.deliver_batch([{to: "+61411111111", body: "a"}], to: "+61400000000") }
        .to raise_error(ArgumentError, /unknown default\(s\) :to/)
      expect(a_request(:any, /clicksend/)).not_to have_been_made
    end
  end
end

RSpec.describe Clicksend::Resources::SMS, "send results without a readable status" do
  def result(messages)
    envelope({"total_count" => messages.size, "queued_count" => 0, "messages" => messages})
  end

  [nil, "", 1].each do |status|
    it "treats a message with status #{status.inspect} as ambiguous, not rejected (it may have been queued)" do
      message = {"message_id" => "A1", "to" => "+61411111111", "status" => status}.compact
      stub_api(:post, "/v3/sms/send").to_return(json_response(result([message])))
      expect { client.sms.deliver(to: "+61411111111", body: "hi") }.to raise_error(Clicksend::MalformedResponseError) { |e| expect(e).to be_ambiguous }
      expect { client.sms.deliver_batch([{to: "+61411111111", body: "hi"}]) }.to raise_error(Clicksend::AmbiguousRequestError)
    end
  end
end
