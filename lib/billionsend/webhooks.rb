# frozen_string_literal: true

require "json"
require "openssl"

module BillionSend
  # Verifies the signature of a webhook delivery.
  #
  # BillionSend signs every delivery the Standard Webhooks way: the secret is
  # +whsec_+ followed by base64 of 24 to 64 bytes, the signed content is
  # +<webhook-id>.<webhook-timestamp>.<body>+, and +webhook-signature+ holds
  # +v1,<base64 HMAC-SHA256>+, several space-separated during a secret rotation.
  module Webhooks
    # Seconds a delivery's timestamp may differ from the receiver's clock.
    DEFAULT_TOLERANCE = 300
    SECRET_PREFIX = "whsec_"
    SECRET_BYTES = (24..64)

    # Checks a webhook delivery and returns its parsed body (a Hash with
    # "type", "created_at" and "data").
    #
    # @param payload [String] the request body exactly as received, before any
    #   JSON parsing: re-serialised JSON does not verify
    # @param headers [Hash, #each] the request headers; names are matched
    #   case-insensitively (webhook-id, webhook-timestamp, webhook-signature)
    # @param secret [String] the endpoint's signing secret (whsec_...)
    # @param tolerance [Integer] seconds the timestamp may be off the current
    #   time, either way; this bounds replays of a captured delivery
    # @param now [Numeric, nil] the current Unix time, for tests
    # @raise [WebhookVerificationError] a header is missing, the timestamp is
    #   outside the tolerance, no signature matches, or the body is not a JSON object
    # @raise [ArgumentError] +secret+ is not a webhook secret
    def self.verify(payload, headers, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      # A secret read from a file or the environment often ends in a newline.
      key = secret_key(secret.to_s.strip)
      msg_id = header(headers, "webhook-id")
      timestamp = header(headers, "webhook-timestamp")
      signatures = header(headers, "webhook-signature")
      if msg_id.nil? || timestamp.nil? || signatures.nil?
        raise WebhookVerificationError, "Missing webhook-id, webhook-timestamp or webhook-signature"
      end
      raise WebhookVerificationError, "Invalid webhook-timestamp" unless timestamp.match?(/\A[0-9]+\z/)

      current = now || Time.now.to_f
      if (current - Integer(timestamp, 10)).abs > tolerance
        raise WebhookVerificationError, "Webhook timestamp is outside the tolerance"
      end

      body = payload.to_s.b
      expected = OpenSSL::HMAC.digest("SHA256", key, "#{msg_id}.#{timestamp}.".b + body)
      matched = signatures.split(" ").any? do |candidate|
        version, encoded = candidate.split(",", 2)
        next false unless version == "v1" && encoded && !encoded.empty?

        given = decode64(encoded)
        given && given.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(given, expected)
      end
      raise WebhookVerificationError, "No webhook signature matches" unless matched

      begin
        event = JSON.parse(body.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        raise WebhookVerificationError, "Webhook body is not JSON"
      end
      raise WebhookVerificationError, "Webhook body is not a JSON object" unless event.is_a?(Hash)

      event
    end

    # Key bytes of a whsec_ secret: canonical base64 of 24 to 64 bytes, else ArgumentError.
    def self.secret_key(secret)
      raise ArgumentError, "A webhook secret starts with whsec_" unless secret.start_with?(SECRET_PREFIX)

      encoded = secret[SECRET_PREFIX.length..]
      key = decode64(encoded)
      raise ArgumentError, "A webhook secret is whsec_ followed by base64" if key.nil?
      raise ArgumentError, "A webhook secret holds 24 to 64 bytes" unless SECRET_BYTES.cover?(key.bytesize)
      raise ArgumentError, "A webhook secret is whsec_ followed by base64" unless [key].pack("m0") == encoded

      key
    end
    private_class_method :secret_key

    def self.decode64(text)
      text.unpack1("m0")
    rescue ArgumentError
      nil
    end
    private_class_method :decode64

    def self.header(headers, name)
      headers.each do |key, value|
        value = value.first if value.is_a?(Array)
        text = value.to_s.strip
        return text if key.to_s.casecmp?(name) && !text.empty?
      end
      nil
    end
    private_class_method :header
  end

  # Checks a webhook delivery and returns its parsed body; see {Webhooks.verify}.
  def self.verify_webhook(payload, headers, secret, **options)
    Webhooks.verify(payload, headers, secret, **options)
  end
end
