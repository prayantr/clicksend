module ClickSend
  module REST
    class Sms
      
      attr_accessor :client
      
      def initialize(client)
        @client = client
      end
            
      def send(params={})
        params.reject!{|key, value| ![:to, :message, :senderid, :schedule, :customstring, :return, :messagetype].include?(key)}
        
        raise 'Recipient Mobile Number should be provided' if params[:to].empty?
        raise 'Message content should not be empty' if params[:message].empty?
        
        params.merge!(method: 'rest')
        
        response = @client.post '/rest/v2/send.json', params
        MultiJson.load(response.body)
      end

      def receive
        response = @client.post '/rest/v2/reply.json'
        MultiJson.load(response.body)
      end

    end
  end
end