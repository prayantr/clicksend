# frozen_string_literal: true

module Clicksend
  # Helpers shared by the immutable value objects built from API payloads.
  #
  # Every model keeps the complete payload it was built from as +raw+ (a
  # frozen Hash), so fields this gem does not expose yet remain available.
  # Values are coerced leniently because ClickSend's own documentation is not
  # consistent about types (e.g. receipt +status_code+ is documented as an
  # integer but shown as "201"); a value that cannot be coerced becomes nil
  # and stays visible in +raw+.
  module Model
    # Replaces credential values that ClickSend echoes back in payloads.
    REDACTED = "[REDACTED]"

    module_function

    def payload!(value, what)
      return value if value.is_a?(Hash)

      raise MalformedResponseError.new("Expected #{what} to be a JSON object, got #{value.class}", body: value)
    end

    def string(value)
      value if value.is_a?(String)
    end

    def integer(value)
      case value
      when Integer then value
      when String then Integer(value, 10, exception: false)
      end
    end

    # Unix timestamp (Integer or numeric String) -> UTC Time
    def time(value)
      integer(value)&.then { |seconds| Time.at(seconds).utc }
    end

    # Prices are kept as decimal Strings (ClickSend sends both "0.0792" and
    # 0.0792); convert with BigDecimal if you need arithmetic.
    def decimal(value)
      case value
      when String then value
      when Numeric then value.to_s
      end
    end

    # Data#inspect without the (large) raw payload.
    module Inspect
      def inspect
        fields = to_h.except(:raw).map { |name, value| "#{name}=#{value.inspect}" }
        "#<#{self.class.name} #{fields.join(", ")}>"
      end
      alias_method :to_s, :inspect
    end
  end
end
