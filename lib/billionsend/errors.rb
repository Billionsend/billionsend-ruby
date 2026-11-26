# frozen_string_literal: true

module BillionSend
  # Base class of every error the SDK raises.
  #
  # Every error carries the API's error shape: +status_code+, +name+ and
  # +message+, plus the +request_id+ the API answered with (its +x-request-id+
  # header). A failure that never produced an API answer (a network error, a
  # timeout, an answer that is not JSON) takes the same shape, with +name+
  # +"application_error"+.
  class Error < StandardError
    # @return [Integer, nil] the HTTP status of the answer, nil when there was none
    attr_reader :status_code
    # @return [String] the API's error name, such as "validation_error"
    attr_reader :name
    # @return [String, nil] the API's id of the request (x-request-id), when it sent one
    attr_reader :request_id
    # @return [BillionSend::Response, nil] the HTTP answer, when there was one
    attr_reader :response

    def initialize(message, name: "application_error", status_code: nil, response: nil)
      super(message)
      @api_message = message
      @name = name
      @status_code = status_code
      @response = response
      @request_id = response&.header("x-request-id")
    end

    # @return [String] a human-readable explanation, as the API wrote it
    def message
      @api_message
    end

    # "<status> <name>: <message>"
    def to_s
      status = status_code ? "#{status_code} " : ""
      "#{status}#{name}: #{@api_message}"
    end

    def inspect
      "#<#{self.class.name} status_code=#{status_code.inspect} name=#{name.inspect} " \
        "message=#{message.inspect} request_id=#{request_id.inspect}>"
    end
  end

  # The request never got an answer: DNS, connection, TLS or protocol failure.
  class APIConnectionError < Error
    def initialize(message = "Connection error")
      super(message, name: "application_error")
    end
  end

  # The request timed out.
  class APITimeoutError < APIConnectionError
    def initialize(message = "Request timed out")
      super
    end
  end

  # 400 or 422: the request was refused as invalid.
  class ValidationError < Error; end

  # 401: the API key is missing, malformed or revoked.
  class AuthenticationError < Error; end

  # 403: the key may not do this.
  class PermissionDeniedError < Error; end

  # 404: no such resource.
  class NotFoundError < Error; end

  # 409: the request conflicts with the current state (or an idempotency key).
  class ConflictError < Error; end

  # 429: too many requests; +retry_after+ holds the server's hint in seconds.
  class RateLimitError < Error
    # @return [Float, nil]
    attr_reader :retry_after

    def initialize(message, name: "rate_limit_exceeded", status_code: 429, response: nil, retry_after: nil)
      super(message, name: name, status_code: status_code, response: response)
      @retry_after = retry_after
    end
  end

  # 5xx: the API failed to answer the request; +retry_after+ holds the server's
  # hint in seconds, when it sent one.
  class APIError < Error
    # @return [Float, nil]
    attr_reader :retry_after

    def initialize(message, name: "application_error", status_code: nil, response: nil, retry_after: nil)
      super(message, name: name, status_code: status_code, response: response)
      @retry_after = retry_after
    end
  end

  # A webhook delivery whose signature, timestamp or headers do not check out.
  class WebhookVerificationError < Error
    def initialize(message)
      super(message, name: "webhook_verification_error")
    end
  end

  BY_STATUS = {
    400 => ValidationError,
    401 => AuthenticationError,
    403 => PermissionDeniedError,
    404 => NotFoundError,
    409 => ConflictError,
    422 => ValidationError
  }.freeze
  private_constant :BY_STATUS

  # The error class of an HTTP status.
  def self.error_class(status)
    return BY_STATUS[status] if BY_STATUS.key?(status)
    return RateLimitError if status == 429
    return APIError if status >= 500

    Error
  end
end
