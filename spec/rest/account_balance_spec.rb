require 'spec_helper'

describe ClickSend::REST::AccountBalance do
  before :each do
    @client = ClickSend::REST::Client.new(username: 'user', api_key: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
    @account_balance = ClickSend::REST::AccountBalance.new(@client.connection)
  end

  it "should not raise error" do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/balance.json").to_return(:status => 200, :body => "{}", :headers => {})
    expect {@account_balance.all}.not_to raise_error
  end

  it "should not raise error if account balance respond with country code" do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/balance.json").to_return(:status => 200, :body => "{}", :headers => {})
    expect {@account_balance.all(:country=>'IN')}.not_to raise_error
  end
end


