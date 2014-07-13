module ClickSend
  module REST  # :nodoc:
    ##
    # The ClickSend::REST::Client class stores information related to authentication
    # such as username and api key. 
    #
    # Instantiate a client like this:
    #
    #   @client = ClickSend::REST::Client.new(:username => username, :api_key => api_key)
    #
    # You can configure opts[:use_ssl] to talk to clicksend api via non secure layer. By default
    # this is set as true, you would need to explicitly set this parameter to false if you need to. 
    #
    #   @client = ClickSend::REST::Client.new(:username => username, :api_key => api_key, :use_ssl => false)
    #
    # Once you have a client object you can use it to communicate with clicksend api.
    #
    #   @client.messages.send(:to => '+919999999999', :message => 'Hello from ClickSend')
    #
    class Client
      attr_reader :connection, :site_url, :messages
      
      attr_accessor :username, :api_key

      ##
      # Instantiate a new Faraday client to talk to ClickSend. The +opts+ parameter is a
      # hash of connection configuration options. the following keys are
      # supported:
      #
      # === <tt>:username => 'username'</tt>
      #
      # The username provided by clicksend. In case you don't have one, signup on clicksend.com to get it.
      #
      # === <tt>:api_key => 'password'</tt>
      #
      # The api_key provided by clicksend. You can find this under Manage API Users in Account Settings.
      #
      # === <tt>:use_ssl => false</tt>
      # Define if you need a secure or a non secure connection. Defaults to secure, need to override if one needs
      # to connect via a non-secure connection.
      #
      def initialize(opts={})
        opts.merge!(use_ssl: true)
                
        @username, @api_key = opts[:username], opts[:api_key]
        @host = 'api.clicksend.com'
        
        @site_url = (opts[:use_ssl] ? 'https://' : 'http://') + @host
    
        @connection = Faraday.new(:url => @site_url)
        @connection.basic_auth username, api_key
        @messages = ClickSend::REST::Sms.new(@connection)
      end

      ##
      # Direct method to get delivery reports for sent messages using ClickSend API.
      def delivery_report
        @delivery_report = ClickSend::REST::DeliveryReport.new(@connection)
        @delivery_report.all
      end

      ##
      # Direct method to get account balance using ClickSend API.
      def account_balance(opts={})
        @account_balance = ClickSend::REST::AccountBalance.new(@connection)
        @account_balance.all(opts)
      end
      
      def inspect # :nodoc:
        "#<ClickSend::REST::Client:0x007fc3eb08df48 @api_key=#{@api_key}, @username=#{@username}, @host=#{@host}, @site_url=#{@site_url}"
      end
    end
  end
end
