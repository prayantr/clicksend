# frozen_string_literal: true

# Experiment 5: what testing against FakeAPI looks like today with stock RSpec
# and ActiveJob test helpers, and what a dedicated matcher would add.
#
#   bundle exec rspec 05_test_helpers_spec.rb
#
# Two examples fail ON PURPOSE (tagged :show_failure) so their failure
# messages can be compared; run with `--tag show_failure` to see them.

require "bundler/setup"
require "logger"
require "active_job"
require "clicksend"
require "clicksend/testing"

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

# Application code: constructor injection of the narrowest dependency (the SMS
# resource), with a production default.
class OtpNotifier
  def initialize(sms: CLICKSEND.sms) = @sms = sms
  def call(user) = @sms.deliver(to: user.fetch(:phone), body: "Code #{user.fetch(:code)}", custom_string: "otp:#{user.fetch(:id)}")
end

class SendOtpJob < ActiveJob::Base
  def perform(id) = OtpNotifier.new.call({id: id, phone: "+61411111111", code: "481516"})
end

# PROTOTYPE ONLY: the kind of matcher a companion gem could ship.
RSpec::Matchers.define :have_sent_sms do |**expected|
  match do |fake|
    @sent = fake.sent_messages
    @sent.count { |m| expected.all? { |k, v| values_match?(v, m.public_send(k)) } } == (@count || 1)
  end
  chain(:once) { @count = 1 }
  chain(:times) { |n| @count = n }
  failure_message do
    "expected #{@count || 1} SMS matching #{expected.inspect}, sent:\n" +
      @sent.map { |m| "  to=#{m.to} custom_string=#{m.custom_string.inspect} body=#{m.body.inspect}" }.join("\n")
  end
end

RSpec.describe "testing with FakeAPI" do
  include ActiveJob::TestHelper

  let(:fake) { Clicksend::Testing::FakeAPI.new }

  before { stub_const("CLICKSEND", fake.client) } # the app's initializer constant, swapped per example

  it "works with stock matchers (Data objects + have_attributes)" do
    OtpNotifier.new(sms: fake.client.sms).call({id: 1, phone: "+61411111111", code: "1"})
    expect(fake.sent_messages).to contain_exactly(have_attributes(to: "+61411111111", custom_string: "otp:1"))
  end

  it "works with ActiveJob's test adapter: enqueued jobs send only when performed" do
    SendOtpJob.perform_later(7)
    expect(fake.sent_messages).to be_empty
    perform_enqueued_jobs
    expect(fake.sent_messages.map(&:custom_string)).to eq(["otp:7"])
  end

  it "prototype matcher" do
    SendOtpJob.perform_later(8)
    perform_enqueued_jobs # (the block form needs rspec-rails' Minitest assertion adapter)
    expect(fake).to have_sent_sms(to: "+61411111111", body: a_string_including("481516")).once
  end

  it "stock matcher failure message", :show_failure do
    OtpNotifier.new(sms: fake.client.sms).call({id: 1, phone: "+61411111111", code: "1"})
    expect(fake.sent_messages).to contain_exactly(have_attributes(to: "+61422222222"))
  end

  it "prototype matcher failure message", :show_failure do
    OtpNotifier.new(sms: fake.client.sms).call({id: 1, phone: "+61411111111", code: "1"})
    expect(fake).to have_sent_sms(to: "+61422222222")
  end
end
