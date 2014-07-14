# clicksend

ClickSend is a ruby gem that provides a clicksend class to check credit and send SMS text messages to single or multiple recipients.

## Installation

To install using [Bundler][bundler] grab the latest stable version:

```
gem 'clicksend', '~> 0.0.1'
```

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

```
@sender = @client.messages
@sender.send(:to => '+919999999999', :message => 'hello world')
```

#### Parameters

| Parameter | Optional | Type | Description |
| --------- | -------- | ---- | ----------- |
|to         | No       | String | Recipient Mobile Number in international format (with leading + and country code). Separate multiple recipients with a comma (,) where applicable. Maximum 1000 recipients. For example: +614XXXXXXXX (Australia), +1XXXXXXXXXX (US), +65XXXXXXXXX (Singapore), +44XXXXXXXXXX (UK) |

<!-- #custom sender ID:
:senderid => ''
#-Alphanumeric e.g. "MyCompany". 11 characters max. No spaces. The recipient will not be able to reply to the message.
#-Numeric e.g. +61411111111. You can enter your own mobile number in international format to make messages appear to come from your mobile number. Replies will be sent directly to your mobile.
#-Leave blank for two-way SMS. Replies will be directed back to the original sender.

# Allows you to schedule message delivery. Must be in unix format.
:schedule => ''
# For example: 1348742950. 
# Leave blank for instant delivery.

# A custom string that will be passed back with replies and delivery reports. Maximum 50      characters.
:customstring => ''

# Redirect to a URL after delivering the message(s).
:return => ''

# For non-English characters use messagetype=Unicode.
# Leave blank for a standard English message.
:messagetype => '' -->

### Receive

```
@receiver = @client.messages
@receiver.receive
```

### Delivery Reports

```
@client.delivery_report
```

### Account Balance

```
@client.account_balance

# optional parameter

# A 2-letter country code (ISO 3166-1 Alpha-2 code).
:country => ''
# e.g. "AU" = Australia.
# If provided, the response will show the account balance and the number of SMS messages you can send to the country specified (credit).
# If the country isn't provided, the response will only show the account balance.
```

## Copyright

Copyright (c) 2014 https://prayantr.com - MIT License. See LICENSE.txt for further details.


[bundler]: http://bundler.io