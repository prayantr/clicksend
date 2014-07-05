require 'click_send/version'
require 'click_send/rest/resource'
require 'click_send/rest/account_balance'
require 'click_send/rest/delivery_report'
require 'click_send/rest/sms'
require 'click_send/rest/client'

module ClickSend
  class ClickSendError < StandardError; end
end