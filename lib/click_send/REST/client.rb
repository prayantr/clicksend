module ClickSend
  module REST
    class Client      
      attr_reader :connection, :site_url, :messages
      
      attr_accessor :username, :api_key

      def initialize(opts={})
        opts.merge!(use_ssl: true)
                
        @username, @api_key = opts[:username], opts[:api_key]
        @host = 'api.clicksend.com'
        
        @site_url = (opts[:use_ssl] ? 'https://' : 'http://') + @host
    
        @connection = Faraday.new(:url => @site_url)
        @connection.basic_auth username, api_key
        @messages = ClickSend::REST::Sms.new(@connection)
        @connection
      end

      def delivery_report
        @delivery_report = ClickSend::REST::DeliveryReport.new(@connection)
        @delivery_report.all
      end
      
      def account_balance(opts={})
        @account_balance = ClickSend::REST::AccountBalance.new(@connection)
        @account_balance.all(opts)
      end
      
      def inspect
        "#<ClickSend::REST::Client:0x007fc3eb08df48 @api_key=#{@api_key}, @username=#{@username}, @host=#{@host}, @site_url=#{@site_url}"
      end
    end
  end
end
