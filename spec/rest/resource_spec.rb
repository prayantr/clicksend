require 'spec_helper'

describe ClickSend::REST::Resource do
  before :each do
    @client = ClickSend::REST::Client.new(username: 'user', api_key: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  	@resource = ClickSend::REST::Resource.new(@client.connection)
  end

  it "should raise an error" do
    expect {@resource.send(:get, '/rest/v2/delivery.json')}.to raise_error('To be Implemented')
  end

  it "should not raise error" do
  	stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").with(body: {to: '+919999999999', message: 'Hello World'}).to_return(status: 200, body: '{"recipientcount":1,"messages":[{"to":"+919999999999","messageid":"EB2FE08D-4202-6D82-4007-74FFBCEB4D49","result":"0000","errortext":"Success"}]}')
		expect {@resource.send(:post, '/rest/v2/send.json', {:to=>'+919999999999', :message=>'Hello World'})}.not_to raise_error
	end

	it "should raise an error" do
    expect {@resource.send(:put, '/rest/v2/delivery.json', 'hello')}.to raise_error('To be Implemented')
	end

	it "should raise an error" do
    expect {@resource.send(:delete, '/rest/v2/delivery.json')}.to raise_error('To be Implemented')  
  end

  it "should not raise error" do
  	stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/send.json").with(body: {to: '+919999999999', message: 'Hello World'}).to_return(status: 200, body: '{"recipientcount":1,"messages":[{"to":"+919999999999","messageid":"EB2FE08D-4202-6D82-4007-74FFBCEB4D49","result":"0000","errortext":"Success"}]}')
		expect {@resource.send(:perform_request, :post, '/rest/v2/send.json', {:to=>'+919999999999', :message=>'Hello World'})}.not_to raise_error
	end

	# it "should not raise error" do
 #  	stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/balance.json").to_return(:status => 200, :body => "{}", :headers => {})
 #    expect {@resource.send(:parse_response, /\#\<Faraday::Response:0x89d3b38\>/)}.not_to raise_error
	# end
end