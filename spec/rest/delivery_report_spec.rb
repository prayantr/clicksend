require 'spec_helper'

describe ClickSend::REST::DeliveryReport do
  before :each do
    @client = ClickSend::REST::Client.new(username: 'user', api_key: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx')
  end

  it "should not raise error" do
    stub_request(:post, "https://user:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@api.clicksend.com/rest/v2/delivery.json").to_return(:status => 200, :body => "{}", :headers => {})
    @delivery_report = ClickSend::REST::DeliveryReport.new(@client.connection)
    expect {@delivery_report.all}.not_to raise_error
  end
end