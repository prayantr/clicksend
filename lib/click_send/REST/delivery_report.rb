module ClickSend
  module REST
    class DeliveryReport
      
      attr_accessor :client
      
      def initialize(client)
        @client = client
      end
            
      def all
        response = @client.post '/rest/v2/delivery.json'
        MultiJson.load(response.body)
      end

    end
  end
end