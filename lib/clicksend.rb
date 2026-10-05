# frozen_string_literal: true

require_relative "clicksend/version"
require_relative "clicksend/errors"
require_relative "clicksend/transport"
require_relative "clicksend/response"
require_relative "clicksend/connection"

# Unofficial Ruby client for the ClickSend v3 REST API.
#
# The namespace is +Clicksend+ (not +ClickSend+) so this gem can be loaded
# alongside ClickSend's official +clicksend_client+ gem, which owns +ClickSend+.
module Clicksend
end
