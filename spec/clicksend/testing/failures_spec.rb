# frozen_string_literal: true

require "clicksend/testing"

RSpec.describe Clicksend::Testing::FakeAPI, "#fail_next" do
  let(:fake) { described_class.new }
  let(:client) { fake.client }

  def deliver
    client.sms.deliver(to: "+61411111111", body: "Hi", custom_string: "otp:42")
  end

  def paths
    fake.requests.map { |request| "#{request.method.upcase} #{request.path}" }
  end

  describe "failures before the request was sent (retried for every method)" do
    it ":connection_refused is retried transparently and the message is sent once" do
      fake.fail_next(:connection_refused)

      expect(deliver).to be_queued
      expect(fake.sent_messages.size).to eq(1)
      expect(paths).to eq(["POST /v3/sms/send"] * 2)
    end

    it ":open_timeout is retried transparently and the message is sent once" do
      fake.fail_next(:open_timeout)

      expect(deliver).to be_queued
      expect(fake.sent_messages.size).to eq(1)
      expect(fake.requests.size).to eq(2)
    end

    it "raises the not-sent error, which is retryable and not ambiguous, once the retries are used up" do
      fake.fail_next(:open_timeout, times: 3)

      expect { deliver }.to raise_error(Clicksend::TimeoutError) { |error|
        expect(error.request_may_have_been_sent?).to be(false)
        expect(error).not_to be_ambiguous
        expect(error).to be_retryable
        expect(error.request.attempts).to eq(3)
        expect(error.message).to include("simulated by Clicksend::Testing::FakeAPI")
      }
      expect(fake.sent_messages).to be_empty
    end

    it ":connection_refused raises a ConnectionError that is not a TimeoutError" do
      fake.fail_next(:connection_refused)

      expect { fake.client(max_retries: 0).sms.deliver(to: "+61411111111", body: "Hi") }.to raise_error(Clicksend::ConnectionError) { |error|
        expect(error).not_to be_a(Clicksend::TimeoutError)
        expect(error.request_may_have_been_sent?).to be(false)
      }
    end
  end

  describe "ambiguous failures on a send (never retried)" do
    it ":timeout processed: true raises an ambiguous TimeoutError and the message WAS accepted once" do
      fake.fail_next(:timeout, processed: true)

      expect { deliver }.to raise_error(Clicksend::TimeoutError) { |error|
        expect(error).to be_ambiguous
        expect(error).to be_a(Clicksend::AmbiguousRequestError)
        expect(error).not_to be_retryable
        expect(error.request_may_have_been_sent?).to be(true)
        expect(error.request).to have_attributes(operation: "sms.deliver", attempts: 1, idempotent: false)
      }
      expect(fake.sent_messages.map(&:custom_string)).to eq(["otp:42"])
      expect(fake.requests.size).to eq(1)
    end

    it ":timeout processed: false raises the same error but nothing was accepted" do
      fake.fail_next(:timeout, processed: false)

      expect { deliver }.to raise_error(Clicksend::AmbiguousRequestError) { |error| expect(error).to be_a(Clicksend::TimeoutError) }
      expect(fake.sent_messages).to be_empty
      expect(fake.requests.size).to eq(1)
    end

    it ":connection_reset raises an ambiguous ConnectionError (not a timeout)" do
      fake.fail_next(:connection_reset, processed: true)

      expect { deliver }.to raise_error(Clicksend::ConnectionError) { |error|
        expect(error).not_to be_a(Clicksend::TimeoutError)
        expect(error).to be_ambiguous
      }
      expect(fake.sent_messages.size).to eq(1)

      fake.fail_next(:connection_reset, processed: false)
      expect { deliver }.to raise_error(Clicksend::AmbiguousRequestError)
      expect(fake.sent_messages.size).to eq(1)
    end

    it "status 500 processed: true raises an ambiguous ServerError after accepting the message" do
      fake.fail_next(status: 500, processed: true)

      expect { deliver }.to raise_error(Clicksend::ServerError) { |error|
        expect(error).to be_ambiguous
        expect(error).not_to be_retryable
        expect(error).to have_attributes(http_status: 500, response_code: "INTERNAL_SERVER_ERROR")
      }
      expect(fake.sent_messages.size).to eq(1)
      expect(fake.requests.size).to eq(1)
    end

    it "status 503 processed: false raises an ambiguous ServerError without accepting the message" do
      fake.fail_next(status: 503, processed: false)

      expect { deliver }.to raise_error(Clicksend::ServerError) { |error|
        expect(error).to be_ambiguous
        expect(error.http_status).to eq(503)
      }
      expect(fake.sent_messages).to be_empty
    end
  end

  describe "ambiguous failures on idempotent requests (retried)" do
    it "retries a 500 on GET receipts" do
      fake.add_receipt(message_id: "ABC-1")
      fake.fail_next(status: 500, processed: false)

      expect(client.sms.receipts.map(&:message_id)).to eq(["ABC-1"])
      expect(paths).to eq(["GET /v3/sms/receipts"] * 2)
    end

    it "retries a read timeout on GET account" do
      fake.fail_next(:timeout, processed: true)

      expect(client.account.fetch.username).to eq("test")
      expect(fake.requests.size).to eq(2)
    end

    it "retries mark_receipts_read(before:) after a processed 500, and not the call without a cutoff" do
      fake.fail_next(status: 500, processed: true)
      expect(client.sms.mark_receipts_read(before: Time.now)).to be_nil
      expect(fake.requests.size).to eq(2)

      fake.fail_next(status: 500, processed: true)
      expect { client.sms.mark_receipts_read }.to raise_error(Clicksend::ServerError) { |e| expect(e).to be_ambiguous }
      expect(fake.requests.size).to eq(3)
    end

    it "raises a retryable ServerError once the retry budget is used up" do
      fake.fail_next(status: 502, processed: false, times: 3)

      expect { client.account.fetch }.to raise_error(Clicksend::ServerError) { |error|
        expect(error).to be_retryable
        expect(error).not_to be_ambiguous
        expect(error.request.attempts).to eq(3)
      }
      expect(client.account.fetch.username).to eq("test")
    end
  end

  describe "status: 429" do
    it "is retried, honouring Retry-After, and the message is sent once" do
      allow(Kernel).to receive(:sleep).and_call_original
      fake.fail_next(status: 429, retry_after: 0)

      expect(deliver).to be_queued
      expect(Kernel).to have_received(:sleep).with(0)
      expect(fake.sent_messages.size).to eq(1)
      expect(fake.requests.size).to eq(2)
    end

    it "answers with ClickSend's live 429 body and rate-limit headers" do
      fake.fail_next(status: 429, retry_after: 7)

      expect { fake.client(max_retries: 0).account.fetch }.to raise_error(Clicksend::RateLimitError) { |error|
        expect(error.body).to eq({"http_code" => 429, "response_code" => "HTTP_TOO_MANY_REQUESTS", "response_msg" => "Too many attempts.", "data" => nil})
        expect(error.retry_after).to eq(7)
        expect(error.rate_limit).to have_attributes(limit: 20, remaining: 0, reset_in: 7)
        expect(error).to be_retryable
      }
    end

    it "defaults Retry-After to 0" do
      fake.fail_next(status: 429)

      expect { fake.client(max_retries: 0).account.fetch }.to raise_error(Clicksend::RateLimitError) { |e| expect(e.retry_after).to eq(0) }
    end
  end

  describe "other 4xx statuses (never processed, never retried)" do
    it "maps 401 to AuthenticationError with ClickSend's live envelope" do
      fake.fail_next(status: 401)

      expect { deliver }.to raise_error(Clicksend::AuthenticationError) { |error|
        expect(error).to have_attributes(response_code: "UNAUTHORIZED", response_msg: "Authorization failed.")
        expect(error).not_to be_ambiguous
        expect(error).not_to be_retryable
      }
      expect(fake.sent_messages).to be_empty
      expect(fake.requests.size).to eq(1)
    end

    it "maps other statuses to their error classes" do
      {400 => Clicksend::BadRequestError, 403 => Clicksend::ForbiddenError, 404 => Clicksend::NotFoundError, 418 => Clicksend::ClientError}
        .each do |status, error_class|
          fake.fail_next(status: status)
          expect { client.account.fetch }.to raise_error(error_class) { |e| expect(e.http_status).to eq(status) }
        end
    end
  end

  describe "filters and ordering" do
    it "fails only requests matching path:, letting others through" do
      fake.fail_next(status: 500, processed: false, path: "/v3/sms/send")

      expect(client.account.fetch.balance).to eq("10.000000")
      expect { deliver }.to raise_error(Clicksend::ServerError)
      expect(deliver).to be_queued
      expect(paths).to eq(["GET /v3/account", "POST /v3/sms/send", "POST /v3/sms/send"])
    end

    it "fails only requests matching method:" do
      fake.fail_next(status: 401, method: :put)

      client.account.fetch
      deliver
      expect { client.sms.mark_inbound_read }.to raise_error(Clicksend::AuthenticationError)
      expect(client.sms.mark_inbound_read).to be_nil
    end

    it "fails the next times: matching requests" do
      fake.fail_next(:connection_refused, times: 2, path: "/v3/sms/send")

      expect(deliver).to be_queued # two refused attempts, then the third succeeds
      expect(fake.requests.size).to eq(3)
      expect(deliver).to be_queued
      expect(fake.requests.size).to eq(4)
    end

    it "consumes instructions first in, first out" do
      fake.fail_next(:connection_refused).fail_next(status: 429).fail_next(:timeout, processed: true)

      expect { deliver }.to raise_error(Clicksend::TimeoutError) { |e| expect(e).to be_ambiguous }
      expect(fake.requests.size).to eq(3)
      expect(fake.sent_messages.size).to eq(1)
    end

    it "records every failed attempt in requests" do
      fake.fail_next(:connection_refused).fail_next(:open_timeout)

      deliver
      expect(fake.requests.map(&:body).uniq.size).to eq(1)
      expect(fake.requests.size).to eq(3)
    end
  end

  describe "argument validation" do
    it "requires processed: for ambiguous outcomes" do
      expect { fake.fail_next(:timeout) }.to raise_error(ArgumentError, /fail_next\(:timeout\) needs processed: true or false/)
      expect { fake.fail_next(:connection_reset) }.to raise_error(ArgumentError, /needs processed:/)
      expect { fake.fail_next(status: 500) }.to raise_error(ArgumentError, /fail_next\(status: 500\) needs processed:/)
      expect { fake.fail_next(:timeout, processed: "yes") }.to raise_error(ArgumentError, /needs processed:/)
    end

    it "refuses processed: where a request is never processed" do
      [[:connection_refused], [:open_timeout]].each do |args|
        expect { fake.fail_next(*args, processed: false) }.to raise_error(ArgumentError, /processed: does not apply/)
      end
      expect { fake.fail_next(status: 429, processed: false) }.to raise_error(ArgumentError, /processed: does not apply/)
      expect { fake.fail_next(status: 401, processed: true) }.to raise_error(ArgumentError, /processed: does not apply/)
    end

    it "rejects unknown outcomes and bad statuses" do
      expect { fake.fail_next(:dns) }.to raise_error(ArgumentError, /unknown fail_next outcome :dns/)
      expect { fake.fail_next }.to raise_error(ArgumentError, /needs an outcome/)
      expect { fake.fail_next(:timeout, status: 500, processed: true) }.to raise_error(ArgumentError, /not both/)
      expect { fake.fail_next(status: 200) }.to raise_error(ArgumentError, /400\.\.599/)
      expect { fake.fail_next(status: "500", processed: true) }.to raise_error(ArgumentError, /400\.\.599/)
    end

    it "validates retry_after, path, method and times" do
      expect { fake.fail_next(status: 503, processed: false, retry_after: 1) }.to raise_error(ArgumentError, /only applies to status: 429/)
      expect { fake.fail_next(:connection_refused, retry_after: 1) }.to raise_error(ArgumentError, /only applies to status: 429/)
      expect { fake.fail_next(status: 429, retry_after: -1) }.to raise_error(ArgumentError, /non-negative/)
      expect { fake.fail_next(:connection_refused, path: "v3/sms/send") }.to raise_error(ArgumentError, /path must be/)
      expect { fake.fail_next(:connection_refused, method: :fetch) }.to raise_error(ArgumentError, /method must be/)
      expect { fake.fail_next(:connection_refused, times: 0) }.to raise_error(ArgumentError, /times must be/)
    end

    it "queues nothing when the arguments are invalid" do
      expect { fake.fail_next(:timeout) }.to raise_error(ArgumentError)
      expect(deliver).to be_queued
      expect(fake.requests.size).to eq(1)
    end
  end
end
