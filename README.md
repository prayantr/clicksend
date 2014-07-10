# ClickSend

ClickSend is a ruby gem that provides a clicksend class to check credit and send SMS text messages to single or multiple recipients.

## Installation

As a Plugin (eg rails 2.3.x)

```
% cd vendor/plugins
% git clone git://github.com/prayantr/clicksend
```

As a Gem from gemcutter

```
% gem install clicksend
```

## Usage

You will require an account with https://my.clicksend.com for the username and secret key - They offer a free trial so you can try before buying.

Example ruby code:

```
require 'rubygems'

require 'clicksend'

username = ENV['SMS_USERNAME'] || abort("Missing SMS_USERNAME env variable")
secure_key = ENV['SMS_KEY'] || abort("Missing SMS_KEY env variable")

test_sms = '0411111111'
test_sms2 = '+8611111111111'
landline_sms = '0862252608' # Inteltech's landline number

gateway = InteltechSms.new(username, secure_key)

credit = gateway.get_credit.inspect

puts "You have #{credit} Credit/s left"

begin
    res = gateway.send_sms(test_sms,'Test from Ruby')
    puts "send_sms to #{res.sms} was successfull."
rescue InteltechSms::Error => ex
    puts "send_sms to #{test_sms} failed. Gateway response #{ex.response.class} with code #{ex.response.response_code}."
end

res2 = gateway.send_multiple_sms([test_sms, test_sms2, landline_sms],'Test from Ruby to multiple numbers')

puts "send_multiple_sms (sending to mobiles should work, sending to a landline should fail):"
puts res2.collect {|r| "sms to #{r.sms} #{r.success? ? 'was successfull' : "failed (#{r.class} with code #{r.response_code})"}."}.join("\n")
```

### Dummy for testing

A Dummy class is also provided for use with tests. The dummy class will return a response based on the response code given. 
Instantiate an instance of the DummyInteltechSms, passing the initial credit, and optionally the response code.
Sms messages will be logged to stdout unless log_to_stdout is set to false.

Example ruby code:

```
require 'rubygems'

require 'dummy_inteltech_sms'

test_sms = '123'

gateway = DummyInteltechSms.new(1)

credit = gateway.get_credit.inspect

puts "You have #{credit} Credit/s left"

res = gateway.send_sms(test_sms,'Test from Ruby')
puts "send_sms to #{res.sms} was successfull."

credit = gateway.get_credit.inspect
puts "You have #{credit} Credit/s left"

begin
  # This will return no credit
  res = gateway.send_sms(test_sms,'Test from Ruby')
  puts "send_sms to #{res.sms} was successfull."
rescue InteltechSms::Error => ex
  puts "send_sms to #{test_sms} failed. Gateway response #{ex.response.class} with code #{ex.response.response_code}."
end

res2 = gateway.send_multiple_sms([test_sms, test_sms2, landline_sms],'Test from Ruby to multiple numbers')

gateway.response_code = InteltechSms::UNAUTHORIZED_RESPONSE_CODE
# OR
gateway = DummyInteltechSms.new(1,InteltechSms::UNAUTHORIZED_RESPONSE_CODE)

puts "send_multiple_sms (sending to mobiles should work, sending to a landline should fail):"
puts res2.collect {|r| "sms to #{r.sms} #{r.success? ? 'was successfull' : "failed (#{r.class} with code #{r.response_code})"}."}.join("\n")
```

### Optional arguments

There are a few optional parameters that the gateway will accept.

- senderid – 15 character custom sender ID which can be a mobile number or a alphanumeric string.
e.g. send message from MYCOMPANY. (Additional cost of 0.5 credits/message applies).
Do not use spaces. If left blank, a random mobile number will be used.

- schedule – Allows you to schedule a message delivery. Must be in unix format. e.g. 1348742950 (Use Time.now.utc.to_i to get the current time)

These are passed to the send_sms and send_multiple_sms methods via an optional hash argument:

```
# To schedule the sms in 12 minutes time ...

res = gateway.send_sms(test_sms,'Test from Ruby', :schedule => Time.now.utc.to_i + (12 * 60))

# To schedule the sms and supply a custom sender id

res2 = gateway.send_multiple_sms([test_sms, test_sms2, landline_sms],'Test from Ruby to multiple numbers', :senderid => 'MYCOMPANY', :schedule => 1348742950)
```

## Copyright

Copyright (c) 2014 https://prayantr.com - MIT License. See LICENSE.txt for further details.
