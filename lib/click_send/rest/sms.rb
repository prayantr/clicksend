module ClickSend
  module REST
    ##
    # A class to wrap all messaging related functionality within the ClickSend API.
    class Sms < Resource

      ##
      # Send messages using ClickSend API. The +params+ parameter is a
      # hash of options. The following keys are mandatory:
      #
      # === <tt>:to => '+614XXXXXXXX'</tt>
      #
      # Recipient Mobile Number in international format (with leading + and country code). Separate multiple recipients with a comma (,) where applicable. Maximum 1000 recipients.
      # 
      # For example:
      # 
      # +614XXXXXXXX (Australia)
      # 
      # +1XXXXXXXXXX (US)
      # 
      # +65XXXXXXXXX (Singapore)
      # 
      # +44XXXXXXXXXX (UK)
      #
      # === <tt>:message => 'Hello'</tt>
      #
      # The message to be sent. Maximum 960 characters.
      #
      #   
      #   
      # The following keys are optional and can be used:
      # 
      # === <tt>:senderid => '+61411111111'</tt>
      #
      # custom sender ID:
      #
      # -Alphanumeric e.g. "MyCompany". 11 characters max. No spaces. The recipient will not be able to reply to the message.
      #
      # -Numeric e.g. +61411111111. You can enter your own mobile number in international format to make messages appear to come from your mobile number. Replies will be sent directly to your mobile.
      #
      # -Leave blank for two-way SMS. Replies will be directed back to the original sender.      
      # 
      # === <tt>:schedule => '1348742950'</tt>
      # Allows you to schedule message delivery. Must be in unix format. 
      #
      # For example: 1348742950.
      #
      # Leave blank for instant delivery.
      #       
      # === <tt>:customstring => 'From ClickSend'</tt>
      # 
      # A custom string that will be passed back with replies and delivery reports. Maximum 50 characters.
      #      
      # === <tt>:return => 'http://mydomain.com/callback'</tt>
      # 
      # Redirect to a URL after delivering the message(s).
      #      
      # === <tt>:messagetype => 'Unicode'</tt>
      #
      # For non-English characters use messagetype=Unicode.
      #
      # Leave blank for a standard English message.
      def send(params={})
        params[:schedule]=params[:schedule].to_i if !params[:schedule].nil? || !params[:schedule].empty?
        params.reject!{|key, value| ![:to, :message, :senderid, :schedule, :customstring, :return, :messagetype].include?(key)}
        raise ClickSendError, 'Recipient Mobile Number is mandatory' if params[:to].nil? || params[:to].empty?
        raise ClickSendError, 'Message is mandatory' if params[:message].nil? || params[:message].empty?
        
        params.merge!(method: 'rest')
        
        perform_request(:post, '/rest/v2/send.json', params)
      end

      ##
      # Poll ClickSend API for replies to messages. Make sure 'Poll our server'
      # settings is selected under 'SMS Reply Report Settings' before using this.
      def receive
        perform_request(:post, '/rest/v2/reply.json')
      end

    end
  end
end