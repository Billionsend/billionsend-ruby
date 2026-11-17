# frozen_string_literal: true

require "test_helper"

class RetriesTest < Minitest::Test
  include ClientHelpers

  EMAIL = { "from" => "a@acme.com", "to" => ["b@example.com"], "subject" => "s", "text" => "t" }.freeze

  def test_a_get_is_retried_on_5xx_with_backoff
    mock.error("GET", "/domains", 503, "unavailable", "Try later")
    mock.error("GET", "/domains", 500, "internal", "Oops")
    client.domains.list
    assert_equal 3, mock.calls.size
    assert_equal 2, sleeps.size
    assert_operator sleeps[0], :<=, 0.5
    assert_operator sleeps[0], :>=, 0.375
    assert_operator sleeps[1], :<=, 1.0
    assert_operator sleeps[1], :>=, 0.75
  end

  def test_gives_up_after_max_retries
    3.times { mock.error("GET", "/domains", 503, "unavailable", "Try later") }
    assert_raises(BillionSend::APIError) { client.domains.list }
    assert_equal 3, mock.calls.size
  end

  def test_max_retries_zero_sends_once
    mock.error("GET", "/domains", 503, "unavailable", "Try later")
    assert_raises(BillionSend::APIError) { client(max_retries: 0).domains.list }
    assert_equal 1, mock.calls.size
  end

  def test_a_post_without_a_key_is_not_retried
    mock.error("POST", "/domains", 503, "unavailable", "Try later")
    assert_raises(BillionSend::APIError) { client.domains.create({ "name" => "acme.com" }) }
    assert_equal 1, mock.calls.size
  end

  def test_a_send_is_retried_with_the_same_generated_key
    mock.error("POST", "/emails", 503, "unavailable", "Try later")
    mock.fail("POST", "/emails", BillionSend::APIConnectionError.new)
    client(max_retries: 3).emails.send(EMAIL)
    keys = mock.calls.map { |c| c.header("idempotency-key") }
    assert_equal 3, keys.size
    assert_equal 1, keys.uniq.size
    refute_nil keys.first
  end

  def test_two_sends_get_two_keys
    c = client
    c.emails.send(EMAIL)
    c.emails.send(EMAIL)
    refute_equal(*mock.calls.map { |call| call.header("idempotency-key") })
  end

  def test_retry_after_is_honoured
    mock.error("GET", "/domains", 429, "rate_limit_exceeded", "Slow down", headers: { "retry-after" => "3" })
    client.domains.list
    assert_equal [3.0], sleeps
  end

  def test_retry_after_as_a_date
    at = (Time.now + 2).httpdate
    mock.error("GET", "/domains", 429, "rate_limit_exceeded", "Slow down", headers: { "retry-after" => at })
    client.domains.list
    assert_operator sleeps.first, :<=, 2.0
  end

  def test_a_retry_after_over_sixty_seconds_raises_at_once
    mock.error("GET", "/domains", 429, "rate_limit_exceeded", "Slow down", headers: { "retry-after" => "61" })
    assert_raises(BillionSend::RateLimitError) { client.domains.list }
    assert_equal 1, mock.calls.size
    assert_empty sleeps
  end

  def test_concurrent_idempotent_request_is_retried_when_keyed
    mock.error("POST", "/emails", 409, "concurrent_idempotent_requests", "Still running")
    client.emails.send(EMAIL)
    assert_equal 2, mock.calls.size
  end

  def test_another_conflict_is_not_retried
    mock.error("POST", "/emails", 409, "invalid_idempotent_request", "Key reused with another body")
    assert_raises(BillionSend::ConflictError) { client.emails.send(EMAIL) }
    assert_equal 1, mock.calls.size
  end

  def test_a_4xx_is_not_retried
    mock.error("GET", "/domains/{id}", 404, "not_found", "No such domain")
    assert_raises(BillionSend::NotFoundError) { client.domains.get(ID) }
    assert_equal 1, mock.calls.size
  end

  def test_a_failure_without_an_answer_is_retried_for_a_get
    mock.fail("GET", "/domains", BillionSend::APITimeoutError.new)
    client.domains.list
    assert_equal 2, mock.calls.size
  end

  def test_backoff_is_capped_at_eight_seconds
    6.times { mock.error("GET", "/domains", 503, "unavailable", "Try later") }
    client(max_retries: 6).domains.list
    assert_operator sleeps.max, :<=, 8.0
    assert_operator sleeps.last, :>=, 6.0
  end
end
