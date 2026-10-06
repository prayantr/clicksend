# frozen_string_literal: true

module Clicksend
  # Instrumentation hooks. Pass any object that responds to
  #
  #   instrument(name, payload) { |payload| ... }
  #
  # as Client.new(instrumenter:). That is ActiveSupport::Notifications'
  # signature, so a Rails application can pass ActiveSupport::Notifications
  # itself and subscribe:
  #
  #   ActiveSupport::Notifications.subscribe("request.clicksend") do |event|
  #     event.payload # => {http_method: :post, path: "/v3/sms/send", operation: "sms.deliver", ...}
  #   end
  #
  # Events:
  #
  # [request.clicksend] Wraps one logical API call, retries included. The
  #   payload has +:http_method+, +:path+, +:operation+ and +:idempotent+ when the
  #   block starts; when it ends, +:attempts+, +:http_status+ (nil if no
  #   response was received), +:response_code+ and +:ambiguous+ are added. If
  #   the call raised, ActiveSupport adds +:exception+ / +:exception_object+.
  # [retry.clicksend] Published (without a block) before each retry, with
  #   +:http_method+, +:path+, +:operation+, +:attempt+ (1 for the first retry),
  #   +:delay+ (seconds), +:error_class+ and +:http_status+.
  #
  # Payloads never contain credentials, headers, query strings, request or
  # response bodies, phone numbers or message text. +path+ is the request path
  # without its query string; for some endpoints it includes a message ID.
  #
  # The instrumenter is called on the caller's thread and must be thread-safe.
  module Instrumentation
    # The default: runs the block and publishes nothing.
    module Null
      module_function

      def instrument(_name, payload = {})
        yield payload if block_given?
      end
    end
  end
end
