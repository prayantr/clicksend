module ClickSend
  module REST
    ##
    # A base class to wrap all basic methods to interact with ClickSend API.
    # All other resource classes within this library inherit from this class.
    class Resource
      
      attr_accessor :connection

      ##
      # Instantiate a new resource object.
      def initialize(connection)
        @connection = connection
      end      
            
      private
      
      def get(url)
        raise "To be Implemented"
      end
      
      def post(url, params)
        @connection.post(url, params)
      end
      
      def put(url, params)
        raise "To be Implemented"
      end
      
      def delete(url)
        raise "To be Implemented"
      end
      
      ##
      # Define #get, #post, #put and #delete helper methods for sending HTTP
      # requests to ClickSend. Each method returns a hash obtained from parsing 
      # the JSON object in the response body.
      def perform_request(method, url, params={})
        begin
          response = case method
          when :get
            get(url)
          when :post
            post(url, params)
          when :put
            put(url, params)
          when :delete
            delete(url)
          end
          parse_response(response)
        rescue Exception => e
          raise ClickSendError, e.message
        end
      end
      
      ##
      # Parse JSON object returned from ClickSend API and raise error if response
      # fails or is not as expected.
      def parse_response(response)
        begin
          body = MultiJson.load(response.body)
        rescue Exception => e
          raise ClickSendError, e.message
        end
      end
    end
  end
end