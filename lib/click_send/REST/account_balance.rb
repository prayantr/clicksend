module ClickSend
  module REST
    class AccountBalance
      
      attr_accessor :client
      
      def initialize(client)
        @client = client
      end
            
      def get(opts={})
        params = {method: 'rest'}
        params.merge!(country: opts[:country]) if opts[:country]
        response = @client.post '/rest/v2/balance.json', params
        MultiJson.load(response.body)
      end
    end
  end
end