module ClickSend
  module REST
    class DeliveryReport < Resource
      
      def all
        perform_request(:post, '/rest/v2/delivery.json')
      end
      
    end
  end
end