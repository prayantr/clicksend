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
username = 'ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
api_key = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

# set up a client to talk to the ClickSend REST API
@client = ClickSend::REST::Client.new(:username => username, :api_key => api_key)
```

### Send an SMS

```
@sender = @client.messages
@sender.send(:to => '+919999999999', :message => 'hello world')
```

## Copyright

Copyright (c) 2014 https://prayantr.com - MIT License. See LICENSE.txt for further details.


[bundler]: http://bundler.io