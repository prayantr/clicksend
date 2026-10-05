# frozen_string_literal: true

module Clicksend
  module Resources
    # The authenticated account. Reached through Client#account.
    class Account
      def initialize(client)
        @client = client
        freeze
      end

      # GET /v3/account
      #
      #   client.account.fetch.balance # => "4.998000"
      #
      # @return [Clicksend::Account]
      def fetch
        Clicksend::Account.from_api(@client.request(:get, "/v3/account").data)
      end

      def inspect
        "#<#{self.class.name}>"
      end
    end
  end
end
