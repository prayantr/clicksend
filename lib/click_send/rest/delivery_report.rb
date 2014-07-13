module ClickSend
  module REST
    ##
    # A class to wrap delivery report related functionality within the ClickSend API.    
    class DeliveryReport < Resource
      
      ##
      # Poll ClickSend API for delivery reports for sent messages. Make sure 'Poll our server'
      # settings is selected under 'SMS Delivery Report Settings' before using this.      
      def all
        perform_request(:post, '/rest/v2/delivery.json')
      end
      
    end
  end
end