require 'spec_helper'

describe ClickSend::REST::Sms do
  before do
    @client = ClickSend::REST::Client.new(username: 'user', api_key: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  end
  
  it 'should raise an error if provided recipient mobile number is invalid' do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Recipient mobile number should be provided')
    @messages = @client.messages
    expect {@messages.send(message: 'hello')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should raise an error if message is not provided' do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Message should be provided')
    @messages = @client.messages
    expect {@messages.send(to: '+919999999999')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should raise an error if provided recipient mobile number is empty' do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Recipient mobile number should not be empty')   
    @messages = @client.messages
    expect {@messages.send(to: '', message: 'hello')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should raise an error if message is empty' do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Message should not be empty')
    @messages = @client.messages
    expect {@messages.send(to: '+919999999999', message: '')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should not raise an error' do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_return(status: 200, body: '{"recipientcount":1,"messages":[{"to":"+919999999999","messageid":"EB2FE08D-4202-6D82-4007-74FFBCEB4D49","result":"0000","errortext":"Success"}]}')
    @messages = @client.messages
    expect {@messages.send(to: '+919999999999', message: 'Hello World')}.not_to raise_error
  end

  it 'should not raise an error' do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/reply.json").to_return(status: 200, body: '{}')
    @messages = @client.messages
    expect {@messages.receive}.not_to raise_error
  end

  it "should ignore extra parameters passed to api other than defined in the api" do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").with(body: {to: '+919999999999', method: 'rest', message: 'Hello World', priority: 'high'}).to_return(status: 200, body: '{"recipientcount":1,"messages":[{"to":"+919999999999","messageid":"EB2FE08D-4202-6D82-4007-74FFBCEB4D49","result":"0000","errortext":"Success"}]}')
    @messages = @client.messages
    expect {@messages.send(to: '+919999999999', message: 'Hello World', priority: 'high')}.to raise_error(ClickSend::ClickSendError)

    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").with(body: {to: '+919999999999', method: 'rest', message: 'Hello World'}).to_return(status: 200, body: '{"recipientcount":1,"messages":[{"to":"+919999999999","messageid":"EB2FE08D-4202-6D82-4007-74FFBCEB4D49","result":"0000","errortext":"Success"}]}')
    expect {@messages.send(to: '+919999999999', message: 'Hello World')}.not_to raise_error
  end
end