require 'spec_helper'

describe ClickSend::REST::Sms do
  
  it 'should raise an error if provided recipient mobile number is invalid' do
  	stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Recipient mobile number should be provided')
  	@client=ClickSend::REST::Client.new(:username=>'User', :api_key=>'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  	@sender=@client.messages
    expect {@sender.send(:to=>'',:message=>'hello')}.to raise_error(ClickSend::ClickSendError)
  end

  # it 'should raise an error if message is not provided' do
  #   stub_request(:post, "https://User:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").to_raise('Message should be not provided')
  #   @client=ClickSend::REST::Client.new(:username=>'User', :api_key=>'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  #   @sender=@client.messages
  #   expect {@sender.send(:to=>'1111111111')}.to raise_error(ClickSend::ClickSendError)
  #   #@sender.send(:to=>'111111111')
  # end

end