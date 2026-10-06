# frozen_string_literal: true

module Clicksend
  module Testing
    # Builds ClickSend-shaped JSON responses for FakeAPI.
    # @api private
    module Payloads
      BASE_URL = "https://rest.clicksend.com"
      USER_ID = 1
      SUBACCOUNT_ID = 1
      ERRORS = {
        400 => ["BAD_REQUEST", "Bad request."],
        401 => ["UNAUTHORIZED", "Authorization failed."],
        403 => ["FORBIDDEN", "Forbidden."],
        404 => ["NOT_FOUND", "Resource not found."],
        405 => ["METHOD_NOT_ALLOWED", "Method not allowed."],
        429 => ["HTTP_TOO_MANY_REQUESTS", "Too many attempts."],
        500 => ["INTERNAL_SERVER_ERROR", "Internal server error."]
      }.freeze
      LIMITS = Page::LIMITS

      module_function

      # @return [Clicksend::Transport::Response]
      def respond(status, body, headers = {})
        Transport::Response.new(status: status, headers: {"content-type" => "application/json"}.merge(headers).freeze, body: JSON.generate(body))
      end

      def ok(message, data)
        respond(200, {"http_code" => 200, "response_code" => "SUCCESS", "response_msg" => message, "data" => data})
      end

      def error(status, response_code = nil, response_msg = nil, headers = {})
        code, msg = ERRORS.fetch(status, ["ERROR", "Simulated HTTP #{status}."])
        respond(status, {"http_code" => status, "response_code" => response_code || code, "response_msg" => response_msg || msg, "data" => nil}, headers)
      end

      # ClickSend's pagination envelope. Out-of-range +limit+ and +page+ values
      # are clamped (ClickSend's handling of them is undocumented). An empty
      # list has +last_page+ 0, as observed live.
      def page(items, path, query, message)
        limit = (Integer(query["limit"], 10, exception: false) || LIMITS.min).clamp(LIMITS.min, LIMITS.max)
        number = [Integer(query["page"], 10, exception: false) || 1, 1].max
        last = (items.size + limit - 1) / limit
        slice = items[(number - 1) * limit, limit] || []
        first = (number - 1) * limit + 1 unless slice.empty?
        ok(message, {
          "total" => items.size, "per_page" => limit, "current_page" => number, "last_page" => last,
          "next_page_url" => ("#{BASE_URL}#{path}?page=#{number + 1}" if number < last),
          "prev_page_url" => ("#{BASE_URL}#{path}?page=#{number - 1}" if number > 1),
          "from" => first, "to" => (first + slice.size - 1 if first), "data" => slice
        })
      end

      # An estimate (one part per 160 characters), not ClickSend's rule, which
      # depends on the encoding and on concatenation headers.
      def parts(body)
        [(body.length + 159) / 160, 1].max
      end

      def accepted(message, id, now, price)
        parts = parts(message["body"])
        {
          "direction" => "out", "date" => now.to_i, "to" => message["to"], "body" => message["body"],
          "from" => message["from"], "schedule" => Integer(message["schedule"], exception: false) || now.to_i,
          "message_id" => id, "message_parts" => parts, "message_price" => format("%.4f", Rational(price) * parts),
          "from_email" => message["from_email"], "list_id" => message["list_id"],
          "custom_string" => message["custom_string"] || "", "contact_id" => nil, "user_id" => USER_ID,
          "subaccount_id" => SUBACCOUNT_ID, "is_shared_system_number" => false, "country" => message["country"],
          "carrier" => "", "status" => "SUCCESS"
        }.freeze
      end

      # The minimal shape ClickSend returns for a message it did not accept.
      def rejected(message, id, status)
        {
          "to" => message["to"], "body" => message["body"], "from" => message["from"], "schedule" => "",
          "message_id" => id, "custom_string" => message["custom_string"] || "", "is_shared_system_number" => false,
          "status" => status
        }
      end

      def currency(name)
        {"currency_name_short" => name}
      end

      # A history row for a sent message: "Sent", with the latest receipt's
      # gateway code (200 until there is one).
      def outbound_row(sent, accepted, receipt)
        accepted.except("status", "custom_string", "is_shared_system_number").merge(
          "status" => "Sent", "status_code" => (receipt ? receipt["status_code"].to_s : "200"),
          "status_text" => receipt&.dig("status_text"), "error_code" => receipt&.dig("error_code")&.to_s,
          "error_text" => receipt&.dig("error_text"), "custom_string" => sent.custom_string,
          "first_name" => nil, "last_name" => nil
        )
      end

      def inbound_row(inbound)
        {
          "direction" => "in", "date" => inbound["timestamp"], "to" => inbound["to"], "body" => inbound["body"],
          "from" => inbound["from"], "status" => "Received", "status_code" => nil, "status_text" => nil,
          "error_code" => nil, "error_text" => nil, "message_id" => inbound["message_id"],
          "message_parts" => parts(inbound["body"]), "custom_string" => inbound["custom_string"],
          "user_id" => USER_ID, "subaccount_id" => SUBACCOUNT_ID
        }
      end
    end
  end
end
