# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "uri"

module BillionSend
  # The BillionSend API client.
  #
  #   client = BillionSend::Client.new # reads BILLIONSEND_API_KEY
  #   client.emails.send({ from: "Acme <hello@acme.com>", to: ["user@example.com"],
  #                        subject: "Hi", text: "Hello" })
  #
  # Operations are grouped into resources named after each operation's
  # +operationId+ (+emails.receiving.attachments.list+ is
  # +client.emails.receiving.attachments.list+). Every method returns the
  # parsed JSON answer as a Hash with string keys.
  class Client
    include Resources::Root

    DEFAULT_BASE_URL = "https://api.billionsend.com"
    DEFAULT_TIMEOUT = 60
    DEFAULT_MAX_RETRIES = 2
    # A Retry-After longer than this is not waited out: the error is raised at once.
    MAX_RETRY_DELAY = 60.0
    # A retry of a keyed request can meet the first attempt still running on the server.
    CONCURRENT_IDEMPOTENT = "concurrent_idempotent_requests"
    IDEMPOTENT_METHODS = %w[GET HEAD OPTIONS PUT DELETE].freeze
    # A header name or value holds printable ASCII and tabs, nothing else.
    UNSENDABLE_HEADER = /[^\t\x20-\x7e]/n

    attr_reader :api_key, :base_url, :timeout, :max_retries

    # Waits between retries; replace it in tests.
    attr_writer :sleeper

    # @param api_key [String, nil] defaults to BILLIONSEND_API_KEY; surrounding whitespace is
    #   dropped, and a blank key counts as none
    # @param base_url [String, nil] defaults to BILLIONSEND_BASE_URL, else https://api.billionsend.com
    # @param timeout [Numeric] seconds per request (an event stream waits at least 60 s per read)
    # @param max_retries [Integer] retries after the first attempt (see "Retries" in the README)
    # @param default_headers [Hash{String => String}] sent with every request
    # @param transport [#call, #open_stream] the HTTP layer (NetHTTPTransport by default)
    # @raise [ArgumentError] the API key holds a control character, or max_retries is negative
    def initialize(api_key: nil, base_url: nil, timeout: DEFAULT_TIMEOUT, max_retries: DEFAULT_MAX_RETRIES,
                   default_headers: {}, transport: nil)
      raise ArgumentError, "max_retries must be 0 or more" if max_retries.negative?

      @api_key = clean_key(api_key) || clean_key(ENV.fetch("BILLIONSEND_API_KEY", nil))
      resolved = base_url || ENV.fetch("BILLIONSEND_BASE_URL", nil)
      resolved = DEFAULT_BASE_URL if resolved.nil? || resolved.empty?
      @base_url = resolved.sub(%r{/+\z}, "")
      @timeout = timeout
      @max_retries = max_retries
      @default_headers = default_headers.to_h
      @transport = transport || NetHTTPTransport.new
      @sleeper = ->(seconds) { sleep(seconds) }
    end

    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect}>"
    end

    # Sends one request with retries and returns the parsed JSON answer.
    # The generated resource methods call it; use it for anything they do not cover.
    #
    # +body+ is sent as JSON. +form+ is sent as multipart/form-data instead (see
    # {Multipart}): the fields named in +files+ and values that answer +read+ are
    # files. An upload is not repeated after a 5xx or a lost answer unless it
    # carries an idempotency key.
    def request(method, path, query: nil, headers: nil, body: nil, form: nil, files: [], idempotency_key: nil,
                auto_idempotency_key: false, auth: true, extra_headers: nil, timeout: nil)
      content_type = body.nil? ? nil : "application/json"
      payload = body.nil? ? nil : JSON.generate(body)
      content_type, payload = Multipart.encode(form, files: files) unless form.nil?
      all_headers = build_headers(auth: auth, content_type: content_type, idempotency_key: idempotency_key,
                                  headers: headers, extra_headers: extra_headers)
      keyed = all_headers.keys.any? { |k| k.casecmp?("idempotency-key") }
      if auto_idempotency_key && !keyed
        all_headers["Idempotency-Key"] = SecureRandom.uuid
        keyed = true
      end
      req = Request.new(method: method, url: url(path, query), headers: all_headers, body: payload,
                        timeout: timeout || @timeout)
      attempt = 0
      loop do
        begin
          response = @transport.call(req)
          return parse_json(response) if response.success?

          error = Client.error_from(response)
        rescue APIConnectionError => e
          error = e
        end
        delay = retry_delay(attempt, error, method: method, keyed: keyed, upload: !form.nil?)
        raise error if delay.nil?

        @sleeper.call(delay)
        attempt += 1
      end
    end

    # Opens an event stream (see {EventStream}); raises at once when the API refuses it.
    def stream_events(path, query: nil, last_event_id: nil, max_reconnects: 5, extra_headers: nil, timeout: nil)
      stream = EventStream.new(self, path, query: query, last_event_id: last_event_id,
                                           max_reconnects: max_reconnects, extra_headers: extra_headers,
                                           timeout: timeout)
      stream.open
      stream
    end

    # @api private
    def open_stream(path, query:, last_event_id:, extra_headers:, timeout:)
      headers = build_headers(auth: true, accept: "text/event-stream",
                              headers: { "Last-Event-ID" => last_event_id }, extra_headers: extra_headers)
      req = Request.new(method: "GET", url: url(path, query), headers: headers, body: nil,
                        timeout: timeout || @timeout)
      stream = @transport.open_stream(req)
      return stream if stream.status >= 200 && stream.status < 300

      body = begin
        stream.read
      ensure
        stream.close
      end
      raise Client.error_from(Response.new(status: stream.status, headers: stream.headers, body: body))
    end

    # @api private
    def pause(seconds)
      @sleeper.call(seconds)
    end

    # Encodes one path segment (an id, or an inbox address such as support@example.com).
    #
    # An empty value is refused: +/emails/+ is another route, so a missing id
    # would run something else. So are "." and "..", which a URL folds away.
    #
    # @raise [ArgumentError] the value is nil, empty, "." or ".."
    def self.encode_path(value)
      text = value.to_s
      raise ArgumentError, "A path parameter cannot be empty" if text.empty?
      raise ArgumentError, "A path parameter cannot be #{text.inspect}" if [".", ".."].include?(text)

      text.b.gsub(/[^A-Za-z0-9\-._~@]/) { |c| format("%%%02X", c.ord) }
    end

    # Drops unset values and empty lists, writes booleans as true/false and lists
    # comma-separated in one key.
    def self.encode_query(query)
      pairs = (query || {}).filter_map do |key, value|
        # An empty list is no filter: "key=" would be refused as a value.
        next if value.nil? || (value.is_a?(Array) && value.empty?)

        value = value.map { |item| query_text(item) }.join(",") if value.is_a?(Array)
        [key.to_s, query_text(value)]
      end
      URI.encode_www_form(pairs)
    end

    def self.query_text(value)
      case value
      when true then "true"
      when false then "false"
      else value.to_s
      end
    end
    private_class_method :query_text

    # Seconds a Retry-After header asks for, or nil.
    def self.retry_after(response)
      header = response.header("retry-after")
      return nil if header.nil? || header.empty?
      return [Float(header), 0.0].max if header.match?(/\A\s*\d+(\.\d+)?\s*\z/)

      [Time.httpdate(header) - Time.now, 0.0].max
    rescue ArgumentError
      nil
    end

    # Maps an error answer to the matching error, keeping the API's error shape.
    def self.error_from(response)
      status = response.status
      name = "application_error"
      message = "HTTP #{status}"
      begin
        body = JSON.parse(response.body.to_s)
        if body.is_a?(Hash)
          name = body["name"] if body["name"].is_a?(String)
          message = body["message"] if body["message"].is_a?(String)
        end
      rescue JSON::ParserError
        text = response.body.to_s.strip
        message = text[0, 500] unless text.empty?
      end
      klass = BillionSend.error_class(status)
      if [RateLimitError, APIError].include?(klass)
        return klass.new(message, name: name, status_code: status, response: response,
                                  retry_after: retry_after(response))
      end
      klass.new(message, name: name, status_code: status, response: response)
    end

    private

    # The key as it goes into the header: one read from a file ends in a newline.
    def clean_key(key)
      key = key.to_s.scrub.strip
      raise ArgumentError, "The API key must not contain control characters" if key.match?(/[[:cntrl:]]/)

      key.empty? ? nil : key
    end

    def url(path, query)
      encoded = Client.encode_query(query)
      encoded.empty? ? @base_url + path : "#{@base_url}#{path}?#{encoded}"
    end

    def build_headers(auth:, content_type: nil, accept: "application/json", idempotency_key: nil, headers: nil,
                      extra_headers: nil)
      out = { "Accept" => accept, "User-Agent" => "billionsend-ruby/#{VERSION}" }
      if auth
        if @api_key.nil?
          raise AuthenticationError.new("No API key: pass api_key: or set BILLIONSEND_API_KEY",
                                        name: "missing_api_key")
        end

        out["Authorization"] = "Bearer #{@api_key}"
      end
      out["Content-Type"] = content_type unless content_type.nil?
      out["Idempotency-Key"] = idempotency_key.to_s unless idempotency_key.nil?
      merge!(out, @default_headers)
      merge!(out, (headers || {}).compact)
      merge!(out, extra_headers || {})
      check_headers(out)
      out
    end

    # Refuses, before anything is sent, a header HTTP cannot carry. Only its name
    # goes into the message: the value may be a key.
    def check_headers(headers)
      headers.each do |name, value|
        next unless name.b.match?(UNSENDABLE_HEADER) || value.b.match?(UNSENDABLE_HEADER)

        raise Error.new("The #{name.inspect} header must be ASCII text without control characters",
                        name: "invalid_header")
      end
    end

    # Sets headers, replacing any already there under another spelling of the name.
    def merge!(headers, more)
      more.each do |name, value|
        headers.delete_if { |existing, _| existing.casecmp?(name.to_s) }
        headers[name.to_s] = value.to_s
      end
    end

    def parse_json(response)
      # A success without a body (a 204, an empty 200) is a call that worked.
      return nil if response.body.nil? || response.body.b.strip.empty?

      JSON.parse(response.body)
    rescue JSON::ParserError
      content_type = response.header("content-type") || "no content type"
      raise Error.new("Expected a JSON answer, got #{content_type}", status_code: response.status,
                                                                      response: response)
    end

    # Seconds to wait before retrying after +error+, or nil to raise it.
    #
    # Retried: a 429 for any request (the API answers it before it writes
    # anything); and, for requests safe to repeat (GET, PUT, DELETE, or any
    # request with an idempotency key), a 5xx or no answer at all, and for a
    # keyed request whose first attempt is still running a 409
    # concurrent_idempotent_requests. An upload without a key is not safe to
    # repeat whatever its method.
    def retry_delay(attempt, error, method:, keyed:, upload:)
      return nil if attempt >= @max_retries

      status = error.status_code
      unless status == 429
        return nil unless keyed || (!upload && IDEMPOTENT_METHODS.include?(method))

        unless error.is_a?(APIConnectionError)
          if status == 409
            return nil unless keyed && error.name == CONCURRENT_IDEMPOTENT
          elsif status.nil? || status < 500
            return nil
          end
        end
      end
      if error.response
        hinted = Client.retry_after(error.response)
        return hinted <= MAX_RETRY_DELAY ? hinted : nil unless hinted.nil?
      end
      base = [0.5 * (2.0**attempt), 8.0].min
      base * (1 - (0.25 * rand))
    end
  end
end
