module ClickSend
  module REST
    module Response
      RESPONSE_CODES = 
      {
        0000 => 'Success', 
        2006 => 'Missing credentials',
        2007 => 'Account not activated',
        2015 => 'Invalid recipient',
        2016 => 'Throttled',
        2017 => 'Invalid sender ID',
        2018 => 'Low credit',
        2022 => 'Invalid credentials',
        2051 => 'Empty message',
        2052 => 'Too many recipients',
        2100 => 'Internal error'
      }
      
      def parse_response(response)
        MultiJson.load(response.body)        
      end
    end
  end
end