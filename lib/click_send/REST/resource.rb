module ClickSend
  module REST
    class Resource
      
      attr_accessor :client
      
      def initialize(client)
        @client = client
      end      
            
      private
      
      def get(url)
        @client.get(url, params)
      end
      
      def post(url, params)
        @client.post(url, params)
      end
      
      def put(url, params)
        @client.put(url, params)
      end
      
      def delete(url)
        raise "To be Implemented"
      end
      
      def perform_request(method, url, params={})
        response = case method
        when :get
          get(url)
        when :post
          post(url, params)
        when :put
          post(url, params)
        when :delete
          delete(url)
        end
        parse_response(response)
      end
      
      def parse_response(response)
        body = MultiJson.load(response.body)
      end
    end
  end
end