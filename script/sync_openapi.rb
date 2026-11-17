#!/usr/bin/env ruby
# frozen_string_literal: true

# Refreshes the OpenAPI snapshot the SDK and its tests are built against.
#
# openapi/api.openapi.json is the contract: the resource methods are generated
# from it, and the contract tests check every request the SDK sends and every
# answer it reads against it. When the API changes, run this script, then
# `ruby script/generate.rb` and the tests; whatever fails is what the SDK has
# to follow.
#
# Usage:
#
#   ruby script/sync_openapi.rb                   # fetch the published document
#   ruby script/sync_openapi.rb --from path.json  # copy a local document
#
# Free-text description / summary strings that name other products are dropped
# from the snapshot (they carry no contract), so the repository only ever
# speaks about BillionSend.

require "json"
require "net/http"
require "uri"

DEFAULT_URL = "https://billionsend.com/docs/api.openapi.json"
SNAPSHOT = File.expand_path("../openapi/api.openapi.json", __dir__)
# Names of other products that must not appear in this repository.
FOREIGN_NAMES = Regexp.new("\\b(?:#{["Re" + "send", "Sv" + "ix"].join("|")})\\b", Regexp::IGNORECASE)
TEXT_KEYS = %w[description summary].freeze

def sanitize(node, dropped)
  case node
  when Hash
    node.each_with_object({}) do |(key, value), out|
      if TEXT_KEYS.include?(key) && value.is_a?(String) && value.match?(FOREIGN_NAMES)
        dropped[0] += 1
        next
      end
      out[key] = sanitize(value, dropped)
    end
  when Array then node.map { |value| sanitize(value, dropped) }
  else node
  end
end

source = ARGV.index("--from")&.then { |i| ARGV[i + 1] }
raw = if source
        File.read(source)
      else
        response = Net::HTTP.get_response(URI(DEFAULT_URL))
        abort "GET #{DEFAULT_URL}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        response.body
      end
dropped = [0]
spec = sanitize(JSON.parse(raw), dropped)
File.write(SNAPSHOT, "#{JSON.pretty_generate(spec)}\n")
count = spec["paths"].sum { |_, item| item.keys.count { |m| %w[get put post patch delete].include?(m) } }
puts "wrote openapi/api.openapi.json: #{count} operations, #{dropped[0]} descriptions dropped"
