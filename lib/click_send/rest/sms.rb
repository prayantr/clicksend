module ClickSend
  module REST
    class Sms < Resource
      
      def send(params={})
        params.reject!{|key, value| ![:to, :message, :senderid, :schedule, :customstring, :return, :messagetype].include?(key)}
        raise ClickSendError, 'Recipient Mobile Number is mandatory' if params[:to].nil? || params[:to].empty?
        raise ClickSendError, 'Message is mandatory' if params[:message].nil? || params[:message].empty?
        
        params.merge!(method: 'rest')
        
        perform_request(:post, '/rest/v2/send.json', params)
      end

      def receive
        perform_request(:post, '/rest/v2/reply.json')
      end

    end
  end
end