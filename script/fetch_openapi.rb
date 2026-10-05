# frozen_string_literal: true

# Downloads the ClickSend OpenAPI files this gem's contract specs and
# fixtures depend on into tmp/openapi/. They are published (one file per
# docs section) at https://developers.clicksend.com/docs/_spec/<section>.yaml
# and are not vendored into this repository.

require "fileutils"
require "net/http"
require "uri"

BASE = "https://developers.clicksend.com/docs/_spec/"
FILES = %w[messaging/sms.yaml accounts/management.yaml].freeze
DEST = File.expand_path("../tmp/openapi", __dir__)

FILES.each do |file|
  uri = URI.join(BASE, file)
  response = Net::HTTP.get_response(uri)
  abort "Failed to download #{uri}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  path = File.join(DEST, file)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, response.body)
  puts "#{uri} -> #{path} (#{response.body.bytesize} bytes)"
end
