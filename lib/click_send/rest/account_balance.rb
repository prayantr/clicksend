module ClickSend
  module REST
    ##
    # A class to wrap account balance related functionality within the ClickSend API.    
    class AccountBalance < Resource
      
      ##
      # Get account balance details from ClickSend API.
      # The following keys are optional:
      #
      # === <tt>:country => 'AU'</tt>
      #
      # A 2-letter country code (ISO 3166-1 Alpha-2 code).
      #
      # e.g. "AU" = Australia.
      #
      # If provided, the response will show the account balance and the number of SMS messages you can send to the country specified (credit).
      #
      # If the country isn't provided, the response will only show the account balance.
      def all(opts={})
        params = {method: 'rest'}
        params.merge!(country: opts[:country]) if opts[:country]
        perform_request(:post, '/rest/v2/balance.json', params)
      end
      
    end
  end
end