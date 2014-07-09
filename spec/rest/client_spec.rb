require 'spec_helper'

describe ClickSend::REST::Client do

  before :each do
    @client = ClickSend::REST::Client.new(username: 'user', api_key: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  end
  
  it 'should raise an error if API end point does not respond' do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/balance.json").to_raise(TimeoutError)  	
    expect { @client.account_balance }.to raise_error(ClickSend::ClickSendError)
  end

  it 'should set up a new client instance with the given sid and token' do
    expect(@client.username).to eq('user')
    expect(@client.api_key).to eq('xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  end

end
