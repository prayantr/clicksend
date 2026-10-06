# frozen_string_literal: true

module Clicksend
  # Parses delivery receipts and inbound SMS that ClickSend pushes to your URL.
  # Pure functions over params your web framework has already decoded; no I/O.
  #
  # ClickSend pushes through automation rules with the +URL+ action. Receipt
  # rules POST form-encoded fields. Inbound rules POST a form (the default),
  # GET with a query string, or POST JSON, by the rule's +webhook_type+.
  # ClickSend does not document the JSON field names; this assumes they are
  # the same. The current docs define no push payload at all: the field names
  # come from the poll schemas (+sms_receipt+, +inbound_sms+), which match the
  # archived push docs. Pushes also carry +user_id+ and, on receipts, +status+
  # ("Delivered"/"Undelivered"); those stay in +raw+.
  #
  # ClickSend does NOT sign or authenticate pushes: no HMAC, signature,
  # secret or published IP ranges. Anyone who knows the URL can forge one, so:
  # - put an unguessable secret in the URL path and compare it in constant time;
  # - use HTTPS;
  # - treat the event as a hint, and confirm anything consequential with
  #   <tt>client.sms.receipt(event.message_id)</tt>;
  # - process idempotently by +message_id+: several matching rules may each push,
  #   and (per the archived docs) a non-200 is retried every 10 minutes, 10 times;
  # - answer 200 quickly and do the work in a job.
  #
  # Prefer one URL per rule type with #parse_receipt / #parse_inbound; #parse
  # guesses the type from the fields present.
  #
  # Pass the body params, not params merged with route params, so your secret
  # does not end up in +raw+. +raw+ is the payload with String keys, minus
  # Rails' "controller", "action" and "format", frozen.
  #
  # Rails (route: <tt>post "clicksend/:secret/receipts", to: "clicksend#receipt"</tt>):
  #
  #   def receipt
  #     secret = Rails.application.credentials.clicksend_webhook_secret
  #     return head(:not_found) unless ActiveSupport::SecurityUtils.secure_compare(params[:secret].to_s, secret)
  #
  #     receipt = Clicksend::Webhook.parse_receipt(request.request_parameters)
  #     ConfirmReceiptJob.perform_later(receipt.message_id) # client.sms.receipt(id); idempotent on id
  #     head :ok
  #   rescue Clicksend::Webhook::InvalidPayload
  #     head :bad_request
  #   end
  #
  # Rails' +params+ (ActionController::Parameters) is also accepted: the gem
  # calls +to_unsafe_h+, which is safe here because only known fields are read
  # into frozen models (nothing is mass-assigned).
  #
  # Rack / Sinatra (use +request.GET+ for a +get+ inbound rule, or
  # <tt>JSON.parse(request.body.read)</tt> for +json+):
  #
  #   post "/clicksend/:secret/inbound" do
  #     halt 404 unless Rack::Utils.secure_compare(params["secret"].to_s, ENV.fetch("CLICKSEND_WEBHOOK_SECRET"))
  #     message = Clicksend::Webhook.parse_inbound(request.POST)
  #     InboundJob.perform_async(message.message_id, message.raw)
  #     200
  #   rescue Clicksend::Webhook::InvalidPayload
  #     400
  #   end
  #
  # Because the endpoint is unauthenticated, payloads with more than
  # MAX_FIELDS keys, a key or String value over MAX_BYTES bytes, or a value
  # that is not a scalar (Hash, Array, uploaded file, ...) are rejected.
  module Webhook
    # Raised for anything that is not a usable push. The message names fields,
    # never their values (bodies and phone numbers are personal data).
    class InvalidPayload < Error; end

    MAX_FIELDS = 64
    MAX_BYTES = 10_000
    RAILS_ROUTING_KEYS = %w[controller action format].freeze
    SCALARS = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze

    module_function

    # @return [Clicksend::SMS::Receipt, Clicksend::SMS::InboundMessage]
    # @raise [InvalidPayload] also when the type cannot be told from the fields
    def parse(params)
      payload = normalize(params)
      if payload.key?("from") && payload.key?("body") && !payload.key?("status_code")
        inbound(payload)
      elsif payload.key?("status_code") && !payload.key?("body")
        receipt(payload)
      else
        raise InvalidPayload, "cannot tell whether this is a delivery receipt or an inbound message; use parse_receipt or parse_inbound"
      end
    end

    # Requires +message_id+ and an integer +status_code+.
    # @return [Clicksend::SMS::Receipt]
    def parse_receipt(params)
      receipt(normalize(params))
    end

    # Requires +message_id+, a non-empty +from+ and a String +body+ (may be empty).
    # @return [Clicksend::SMS::InboundMessage]
    def parse_inbound(params)
      inbound(normalize(params))
    end

    def receipt(payload)
      message_id!(payload)
      raise InvalidPayload, "delivery receipt: status_code is missing or not an integer" unless Model.integer(payload["status_code"])

      SMS::Receipt.from_api(payload)
    end

    def inbound(payload)
      message_id!(payload)
      from = payload["from"]
      raise InvalidPayload, "inbound message: from is missing or not a non-empty String" unless from.is_a?(String) && !from.empty?
      raise InvalidPayload, "inbound message: body is missing or not a String" unless payload["body"].is_a?(String)

      SMS::InboundMessage.from_api(payload)
    end

    # message_id is interpolated into API paths when the event is confirmed.
    def message_id!(payload)
      return if payload["message_id"].is_a?(String) && payload["message_id"].match?(Resources::SMS::MESSAGE_ID)

      raise InvalidPayload, "message_id is missing or not a ClickSend message ID"
    end

    def normalize(params)
      params = params.to_unsafe_h if !params.is_a?(Hash) && params.respond_to?(:to_unsafe_h)
      raise InvalidPayload, "expected a Hash of params, got #{params.class}" unless params.is_a?(Hash)
      raise InvalidPayload, "payload has more than #{MAX_FIELDS} fields" if params.size > MAX_FIELDS

      params.each_with_object({}) do |(key, value), payload|
        raise InvalidPayload, "payload keys must be Strings or Symbols" unless key.is_a?(String) || key.is_a?(Symbol)

        key = key.to_s
        next if RAILS_ROUTING_KEYS.include?(key)
        raise InvalidPayload, "payload has the same key as both a String and a Symbol" if payload.key?(key)
        raise InvalidPayload, "payload values must be Strings, numbers, booleans or null" unless SCALARS.any? { |type| value.is_a?(type) }
        if key.bytesize > MAX_BYTES || (value.is_a?(String) && value.bytesize > MAX_BYTES)
          raise InvalidPayload, "payload has a key or value longer than #{MAX_BYTES} bytes"
        end

        payload[key] = (value.is_a?(String) && !value.frozen?) ? value.dup.freeze : value
      end.freeze
    end

    private_class_method :receipt, :inbound, :message_id!, :normalize
  end
end
