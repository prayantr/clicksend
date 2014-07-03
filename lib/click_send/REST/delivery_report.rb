module ClickSend
  module REST
    class DeliveryReport
      include Response
      
      attr_accessor :client
      
      def initialize(client)
        @client = client
      end
            
      def all
        response = @client.post '/rest/v2/delivery.json'
        parse_response(response)
      end

    end
  end
end