# frozen_string_literal: true

require_relative "lib/billionsend/version"

Gem::Specification.new do |spec|
  spec.name = "billionsend"
  spec.version = BillionSend::VERSION
  spec.authors = ["BillionSend"]
  spec.summary = "Ruby client for the BillionSend email API"
  spec.description = "Send, receive and track email with BillionSend: sending, domains, contacts, broadcasts, " \
                     "automations, templates, webhooks and agent inboxes, with retries, idempotency keys, " \
                     "inbox event streams and webhook verification."
  spec.homepage = "https://github.com/billionsend/billionsend-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://billionsend.com/docs"
  }

  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]
end
