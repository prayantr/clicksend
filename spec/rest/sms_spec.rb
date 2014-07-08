require 'spec_helper'

describe ClickSend::REST::Sms do
  before do
    @client=ClickSend::REST::Client.new(:username=>'User', :api_key=>'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  end
  
  it 'should raise an error if provided recipient mobile number is invalid' do
  	stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Recipient mobile number should be provided') 	
  	@sender=@client.messages
    expect {@sender.send(:message=>'hello')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should raise an error if message is not provided' do
    stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Message should be provided')
    @sender=@client.messages
    expect {@sender.send(:to=>'+919627939890')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should raise an error if provided recipient mobile number is empty' do
    stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Recipient mobile number should not be empty')   
    @sender=@client.messages
    expect {@sender.send(:to=>'', :message=>'hello')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should raise an error if message is empty' do
    stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Message should not be empty')
    @sender=@client.messages
    expect {@sender.send(:to=>'+919627939890', :message=>'')}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should not raise an error' do
    stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_return(:status => 200, :body => '{"message":"hello", "method":"rest", "to":"+919627939890"}', :headers => {})
    @sender=@client.messages
    expect {@sender.send(:to=>'+919627939890', :message=>'hello')}.not_to raise_error
  end

  it 'should not raise an error' do
    stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/reply.json").to_return(:status => 200, :body => '{}', :headers => {})
    @sender=@client.messages
    expect {@sender.receive}.not_to raise_error
  end

end