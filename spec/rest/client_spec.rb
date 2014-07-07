require 'spec_helper'

describe ClickSend::REST::Client do
  
  it 'should raise an error if API end point does not respond' do
  	stub_request(:post, "https://api.clicksend.com/rest/v2/balance.json").to_raise(TimeoutError)
  	@client=ClickSend::REST::Client.new(:username=>'User', :api_key=>'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  	expect {@client.account_balance}.to raise_error(ClickSend::ClickSendError)
  end

  it 'should set up a new client instance with the given sid and token' do
    @client=ClickSend::REST::Client.new(:username=>'User', :api_key=>'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
    @client.username.should == 'User'
    @client.api_key.should == 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
  end

end
