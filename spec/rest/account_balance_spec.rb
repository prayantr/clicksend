require 'spec_helper'

describe ClickSend::REST::AccountBalance do
	before :each do
		@client=ClickSend::REST::Client.new
	end


  it "should give account balance" do
  	@account_balance = ClickSend::REST::AccountBalance.new(@client)
  	#@account_balance.all.should_not raise_error
  end

  it "should give account balance with country code" do
  	#@account_balance = ClickSend::REST::AccountBalance.new
  	#@account_balance.all('IN').should_not raise_error
  end
end


