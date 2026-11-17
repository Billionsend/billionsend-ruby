# frozen_string_literal: true

require "minitest/autorun"
require "billionsend"
require_relative "support/contract"

module ClientHelpers
  ID = "6a1f1d38-3c55-4a4e-9a57-0f2b3c4d5e6f"
  ID2 = "7b2e2e49-4d66-4b5f-8b68-1a3c4d5e6f70"

  def mock
    @mock ||= Contract::Mock.new
  end

  # Seconds the client waited between attempts.
  def sleeps
    @sleeps ||= []
  end

  def client(**options)
    c = BillionSend::Client.new(api_key: Contract::API_KEY, base_url: Contract::BASE_URL, transport: mock, **options)
    c.sleeper = ->(seconds) { sleeps << seconds }
    c
  end
end
