module ClickSend
  module REST
    class Sms < Resource
      
      def send(params={})
        params.reject!{|key, value| ![:to, :message, :senderid, :schedule, :customstring, :return, :messagetype].include?(key)}
        
        raise 'Recipient Mobile Number should be provided' if params[:to].empty?
        raise 'Message content should not be empty' if params[:message].empty?
        
        params.merge!(method: 'rest')
        
        perform_request(:post, '/rest/v2/send.json', params)
      end

      def receive
        perform_request(:post, '/rest/v2/reply.json')
      end

    end
  end
end