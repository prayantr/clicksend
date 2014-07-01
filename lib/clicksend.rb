require 'faraday'
require 'json'

class Clicksend
  VERSION = "1.0.0"
  RESPONSE={0000 => 'Success', 2006 => 'Missing credentials', 2007 => 'Account not activated', 2015 => 'Invalid recipient', 2016 => 'Throttled', 2017 => 'Invalid sender ID', 2018 => 'Low credit', 2022 => 'Invalid credentials', 2051 => 'Empty message', 2052 => 'Too many recipients', 2100..2199 => 'Internal error'}
  
  def sendsms(to, message, senderid, schedule, customstring, back, messagetype)
  	if to==''
  		'require recipient mobile number'
  	elsif message==''
  		'message can not be empty'
  	else
  		conn = Faraday.new(:url => 'https://api.clicksend.com')
  		conn.basic_auth 'prayantr', 'C77F81F9-CE98-13BB-B42D-BCE30A506AC4'
  		res = conn.post '/rest/v2/send.json', {method: 'rest', to: to, message: message, senderid: senderid, schedule: schedule, customstring: customstring, :return=> back, messagetype: messagetype}
   		RESPONSE[(JSON.parse(res.body)['messages'][0]['result']).to_i]
   	end
  end

end

res=Clicksend.new
puts res.sendsms('+19174083393', 'hello bhai', '', '', '', '', '')