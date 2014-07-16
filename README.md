# clicksend

ClickSend is a ruby gem that provides a clicksend class to check credit and send SMS text messages to single or multiple recipients.

## Installation

To install using [Bundler][bundler] grab the latest stable version:

```
gem 'clicksend', '~> 0.0.1'
```

As a Gem from gemcutter

```
% gem install clicksend
```

## Usage

You will require an account with https://my.clicksend.com for the username and secret key - They offer a free trial so you can try before buying.

## Getting Started With REST

### Setup Work

```
require 'rubygems' # not necessary with ruby 1.9 but included for completeness
require 'clicksend'

# put your own credentials here
username = 'ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'      # Your ClickSend username.
api_key = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'  # Your Secure Unique API key.

# set up a client to talk to the ClickSend REST API
@client = ClickSend::REST::Client.new(:username => username, :api_key => api_key)

# secure socket layer is enable
# set false to disable secure socket layer 
@client = ClickSend::REST::Client.new(:username => username, :api_key => api_key, :use_ssl => false)
```

### Send an SMS

Send SMS message from given number.

```
@client.messages.send(:to => '+919999999999', :message => 'hello world')
```

#### Parameters

| Parameter | Required | Type | Description |
| --------- | -------- | ---- | ----------- |
| to        | Yes      | String | Recipient Mobile Number in international format (with leading + and country code). Separate multiple recipients with a comma (,) where applicable. Maximum 1000 recipients.<br>For example:<br>+614XXXXXXXX (Australia)<br>+1XXXXXXXXXX (US)<br> +65XXXXXXXXX (Singapore)<br>+44XXXXXXXXXX (UK) |
| message   | Yes      | String | The message to be sent. Maximum 960 characters. |
| senderid  | No       | String | custom sender ID:<br>-Alphanumeric e.g. "MyCompany". 11 characters max. No spaces. The recipient will not be able to reply to the message.<br>-Numeric e.g. +61411111111. You can enter your own mobile number in international format to make messages appear to come from your mobile number. Replies will be sent directly to your mobile.<br>-Leave blank for two-way SMS. Replies will be directed back to the original sender. |
| schedule  | No      | String  | Allows you to schedule message delivery. Must be in unix format.<br>For example: 1348742950.<br>Leave blank for instant delivery. |
| customstring | No | String | A custom string that will be passed back with replies and delivery reports. Maximum 50 characters. |
| return | No | String | Redirect to a URL after delivering the message(s). |
| messagetype | No | String | For non-English characters use messagetype=Unicode.<br>Leave blank for a standard English message. |

#### Example

```
# replies will be sent directly to given senderid
@client.messages.send(:to => '+919999999999', :message => 'hello world', :senderid => '+918888888888')
```

```
# message will be sent on given schedule
@client.messages.send(:to => '+919999999999', :message => 'hello world', :schedule => '1348742950')
```


### Receive

Poll ClickSend API for replies to messages. Make sure 'Poll our server' settings is selected under 'SMS Reply Report Settings' before using this.

```
@client.messages.receive
```

### Delivery Reports

Direct method to get delivery reports for sent messages using ClickSend API.

```
@client.delivery_report
```

### Account Balance

Direct method to get account balance using ClickSend API.

```
@client.account_balance
```

#### Parameters

| Parameter | Required | Type | Description |
| --------- | -------- | ---- | ----------- |
| country   | No       | String | A 2-letter country code (ISO 3166-1 Alpha-2 code).<br>e.g. "AU" = Australia.<br>If provided, the response will show the account balance and the number of SMS messages you can send to the country specified (credit).<br>If the country isn't provided, the response will only show the account balance. |

#### Example

```
# This will show the account balance and the number of SMS messages you can send to the country specified
@client.account_balance('IN')
```

## Copyright

Copyright (c) 2014 https://prayantr.com - MIT License. See LICENSE.txt for further details.


[bundler]: http://bundler.io