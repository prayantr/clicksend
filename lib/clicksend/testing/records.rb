# frozen_string_literal: true

module Clicksend
  module Testing
    # A message the FakeAPI accepted (per-message status "SUCCESS"), as
    # submitted. +to+ is nil for a message sent to a contact list
    # (+list_id+); +schedule+ is the Unix time it was scheduled for, or nil;
    # +sent_at+ is the (UTC) time the fake accepted it.
    SentMessage = Data.define(:message_id, :to, :from, :body, :custom_string, :list_id, :schedule, :country, :sent_at)

    # A request the FakeAPI received, recorded whatever its outcome.
    #
    # +http_method+ is a lower-case Symbol; +query+ has String keys and values, as
    # ClickSend would receive them; +body+ is the parsed JSON (deep-frozen), or
    # nil. Headers are never recorded: they carry the credentials.
    Request = Data.define(:http_method, :path, :query, :body)
  end
end
