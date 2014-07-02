require 'faraday'
require 'json'

class Clicksend
  VERSION = "1.0.0"
  RESPONSE = {0000 => 'Success', 2006 => 'Missing credentials', 2007 => 'Account not activated', 2015 => 'Invalid recipient', 2016 => 'Throttled', 2017 => 'Invalid sender ID', 2018 => 'Low credit', 2022 => 'Invalid credentials', 2051 => 'Empty message', 2052 => 'Too many recipients', 2100..2199 => 'Internal error'}
  CONN = Faraday.new(:url => 'https://api.clicksend.com')
  CONN.basic_auth 'prayantr', 'C77F81F9-CE98-13BB-B42D-BCE30A506AC4'

  def sendsms to, message, senderid, schedule, customstring, back, messagetype
  	if to.strip.empty?
  		'recipient mobile number required'
  	elsif message.strip.empty?
  		'message can not be empty'
  	else
      begin
  		  res = CONN.post '/rest/v2/send.json', {method: 'rest', to: to, message: message, senderid: senderid, schedule: schedule, customstring: customstring, :return=> back, messagetype: messagetype}
        RESPONSE[(JSON.parse(res.body)['messages'][0]['result']).to_i]
      rescue
        puts 'error occured'
      end
   	end
  end

  def recievesms
    begin
  	  res = CONN.post '/rest/v2/reply.json'
  	  res.body
    rescue
      puts 'error occured'
    end
  end

  def deliverystatus	
    begin
  	  res = CONN.post '/rest/v2/delivery.json'
  	  res.body
    rescue
      puts 'error occured'
    end
  end

  def accountbalance country	
    begin
  	  res = CONN.post '/rest/v2/balance.json', {method: 'rest', country: country}
  	  res.body
    rescue
      puts 'error occured'
    end
  end
end

# res=Clicksend.new
# puts res.sendsms('+19174083393', 'bhai', '', '', '', '', '')

# res=Clicksend.new
# puts res.recievesms

# res=Clicksend.new
# puts res.deliverystatus

# res=Clicksend.new
# puts res.accountbalance ''