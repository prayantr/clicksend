# frozen_string_literal: true

require_relative "clicksend/version"
require_relative "clicksend/errors"
require_relative "clicksend/rate_limit"
require_relative "clicksend/instrumentation"
require_relative "clicksend/transport"
require_relative "clicksend/response"
require_relative "clicksend/retry_policy"
require_relative "clicksend/connection"
require_relative "clicksend/page"
require_relative "clicksend/model"
require_relative "clicksend/account"
require_relative "clicksend/resources/account"
require_relative "clicksend/sms/message"
require_relative "clicksend/sms/batch"
require_relative "clicksend/sms/receipt"
require_relative "clicksend/sms/inbound_message"
require_relative "clicksend/sms/history_record"
require_relative "clicksend/resources/sms"
require_relative "clicksend/client"

# Unofficial Ruby client for the ClickSend v3 REST API.
#
# The namespace is +Clicksend+ (not +ClickSend+) so this gem can be loaded
# alongside ClickSend's official +clicksend_client+ gem, which owns +ClickSend+.
module Clicksend
end
