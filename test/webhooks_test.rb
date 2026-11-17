# frozen_string_literal: true

require "test_helper"
require "openssl"

# Webhook signature verification, against the API's signing vectors: the
# published Standard Webhooks vector the API's own signing test pins, and a
# rotation vector signed the way the API signs.
class WebhooksTest < Minitest::Test
  SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  MSG_ID = "msg_p5jXN8AQM9LWM0D4loKWxJek"
  TIMESTAMP = 1_614_265_330
  PAYLOAD = '{"test": 2432232314}'
  SIGNATURE = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
  HEADERS = { "webhook-id" => MSG_ID, "webhook-timestamp" => TIMESTAMP.to_s, "webhook-signature" => SIGNATURE }.freeze

  ROTATED = "whsec_BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="
  ROTATION_PAYLOAD = '{"type":"email.delivered","created_at":"2026-11-16T09:00:00.000Z","data":{"email_id":"e1"}}'
  ROTATION_SIGNATURE = "v1,VfgCmhkRJMAi9nv9R1rsE49fWcTpLQ8gcMN9e7uGbrk= v1,IRvb7GZmh00vSNTRcSQ0MTb0qfbEKpRQlNS8r3daFnQ="

  def verify(payload = PAYLOAD, headers = HEADERS, secret = SECRET, now: TIMESTAMP, **options)
    BillionSend.verify_webhook(payload, headers, secret, now: now, **options)
  end

  def test_published_vector
    assert_equal({ "test" => 2_432_232_314 }, verify)
  end

  def test_any_header_case_and_binary_payload
    assert verify(PAYLOAD.b, HEADERS.transform_keys(&:upcase))
  end

  def test_either_secret_verifies_during_a_rotation
    headers = { "webhook-id" => "msg_rot", "webhook-timestamp" => "1700000000",
                "webhook-signature" => ROTATION_SIGNATURE }
    [ROTATED, SECRET].each do |secret|
      event = verify(ROTATION_PAYLOAD, headers, secret, now: 1_700_000_000)
      assert_equal "email.delivered", event["type"]
      assert_equal({ "email_id" => "e1" }, event["data"])
    end
  end

  def test_a_changed_body_fails
    assert_raises(BillionSend::WebhookVerificationError) { verify('{"test": 2432232315}') }
  end

  def test_a_wrong_secret_fails
    error = assert_raises(BillionSend::WebhookVerificationError) do
      verify(PAYLOAD, HEADERS, "whsec_#{["k" * 24].pack("m0")}")
    end
    assert_equal "No webhook signature matches", error.message
  end

  def test_the_timestamp_must_be_within_the_tolerance
    assert_raises(BillionSend::WebhookVerificationError) { verify(now: TIMESTAMP + 301) }
    assert_raises(BillionSend::WebhookVerificationError) { verify(now: TIMESTAMP - 301) }
    assert verify(now: TIMESTAMP + 301, tolerance: 400)
  end

  def test_missing_or_malformed_headers_fail
    %w[webhook-id webhook-timestamp webhook-signature].each do |name|
      assert_raises(BillionSend::WebhookVerificationError) { verify(PAYLOAD, HEADERS.except(name)) }
    end
    assert_raises(BillionSend::WebhookVerificationError) do
      verify(PAYLOAD, HEADERS.merge("webhook-timestamp" => "16142653e3"))
    end
    assert_raises(BillionSend::WebhookVerificationError) do
      verify(PAYLOAD, HEADERS.merge("webhook-signature" => "v2,#{SIGNATURE.split(",").last}"))
    end
  end

  def test_a_body_that_is_not_an_object_fails
    key = "k" * 32
    secret = "whsec_#{[key].pack("m0")}"
    signed = [OpenSSL::HMAC.digest("SHA256", key, "#{MSG_ID}.#{TIMESTAMP}.[1]")].pack("m0")
    headers = HEADERS.merge("webhook-signature" => "v1,#{signed}")
    error = assert_raises(BillionSend::WebhookVerificationError) { verify("[1]", headers, secret) }
    assert_equal "Webhook body is not a JSON object", error.message
  end

  def test_bad_secrets_are_refused
    ["MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", "whsec_!!!", "whsec_#{["k" * 8].pack("m0")}",
     "whsec_#{["k" * 65].pack("m0")}"].each do |secret|
      assert_raises(ArgumentError) { verify(PAYLOAD, HEADERS, secret) }
    end
  end
end
