module ClickSend
  module REST
    class AccountBalance < Resource
      
      def all(opts={})
        params = {method: 'rest'}
        params.merge!(country: opts[:country]) if opts[:country]
        perform_request(:post, '/rest/v2/balance.json', params)
      end
      
    end
  end
end