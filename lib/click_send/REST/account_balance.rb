module ClickSend
  module REST
    class AccountBalance      
      include Response
      
      attr_accessor :client
      
      def initialize(client)
        @client = client
      end
            
      def get(opts={})
        params = {method: 'rest'}
        params.merge!(country: opts[:country]) if opts[:country]
        response = @client.post '/rest/v2/balance.json', params
        parse_response(response)
      end
    end
  end
end