# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Minitest::Test
  include ClientHelpers

  {
    400 => BillionSend::ValidationError,
    401 => BillionSend::AuthenticationError,
    403 => BillionSend::PermissionDeniedError,
    404 => BillionSend::NotFoundError,
    409 => BillionSend::ConflictError,
    422 => BillionSend::ValidationError,
    429 => BillionSend::RateLimitError,
    500 => BillionSend::APIError,
    503 => BillionSend::APIError,
    418 => BillionSend::Error
  }.each do |status, klass|
    define_method("test_status_#{status}_raises_#{klass.name.split("::").last}") do
      mock.error("GET", "/domains/{id}", status, "some_error", "Something went wrong",
                 headers: { "x-request-id" => "req_123" })
      error = assert_raises(klass) { client(max_retries: 0).domains.get(ID) }
      assert_instance_of klass, error
      assert_equal status, error.status_code
      assert_equal "some_error", error.name
      assert_equal "Something went wrong", error.message
      assert_equal "req_123", error.request_id
      assert_equal "#{status} some_error: Something went wrong", error.to_s
    end
  end

  def test_rate_limit_carries_retry_after
    mock.error("GET", "/domains", 429, "rate_limit_exceeded", "Slow down", headers: { "retry-after" => "7" })
    error = assert_raises(BillionSend::RateLimitError) { client(max_retries: 0).domains.list }
    assert_in_delta 7.0, error.retry_after
  end

  def test_an_error_without_a_json_body_keeps_its_text
    mock.respond("GET", "/domains", 502, body: "Bad gateway", headers: { "content-type" => "text/plain" })
    error = assert_raises(BillionSend::APIError) { client(max_retries: 0).domains.list }
    assert_equal "application_error", error.name
    assert_equal "Bad gateway", error.message
  end

  def test_a_failure_without_an_answer
    mock.fail("GET", "/domains", BillionSend::APITimeoutError.new)
    error = assert_raises(BillionSend::APITimeoutError) { client(max_retries: 0).domains.list }
    assert_kind_of BillionSend::APIConnectionError, error
    assert_nil error.status_code
    assert_equal "application_error", error.name
  end

  def test_every_error_is_a_billionsend_error
    [BillionSend::APIConnectionError, BillionSend::WebhookVerificationError, BillionSend::RateLimitError].each do |k|
      assert_operator k, :<, BillionSend::Error
    end
  end
end
