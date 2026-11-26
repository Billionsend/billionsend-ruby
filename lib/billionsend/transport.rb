# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "zlib"

module BillionSend
  # One HTTP request, as the client hands it to a transport.
  Request = Struct.new(:method, :url, :headers, :body, :timeout, keyword_init: true)

  # One HTTP answer. Header names are lower case.
  Response = Struct.new(:status, :headers, :body, keyword_init: true) do
    def header(name)
      headers[name.downcase]
    end

    def success?
      status >= 200 && status < 300
    end
  end

  # The HTTP layer: Net::HTTP, one connection a request.
  #
  # Anything answering +call(request)+ with a {Response} and +open_stream(request)+
  # with an object that has +status+, +headers+, +header(name)+, +read+ (the
  # whole body), +each_chunk+ and +close+ can stand in for it (pass it as the
  # client's +transport:+). Both raise {APIConnectionError} or {APITimeoutError}
  # when no answer comes back.
  class NetHTTPTransport
    METHODS = {
      "GET" => Net::HTTP::Get,
      "POST" => Net::HTTP::Post,
      "PUT" => Net::HTTP::Put,
      "PATCH" => Net::HTTP::Patch,
      "DELETE" => Net::HTTP::Delete
    }.freeze

    # A read that waits far longer than an event stream's 15-second keepalive
    # means the connection is gone.
    STREAM_READ_TIMEOUT = 60

    def call(request)
      uri = URI(request.url)
      guard do
        http = connection(uri, request.timeout, request.timeout)
        http.start do |conn|
          answer = conn.request(build(uri, request))
          Response.new(status: answer.code.to_i, headers: headers_of(answer), body: answer.body.to_s)
        end
      end
    end

    def open_stream(request)
      uri = URI(request.url)
      read_timeout = [request.timeout.to_f, STREAM_READ_TIMEOUT].max
      http = connection(uri, request.timeout, read_timeout)
      stream = OpenStream.new(http, build(uri, request), method(:guard))
      stream.start
      stream
    end

    # Runs the block, turning Net::HTTP's failures into the SDK's.
    def guard
      yield
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise APITimeoutError, "Request timed out: #{e.message}"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, EOFError,
           Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error => e
      raise APIConnectionError, "Connection error: #{e.message}"
    end

    private

    def connection(uri, open_timeout, read_timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.write_timeout = open_timeout
      # The client decides what is retried; Net::HTTP would repeat a GET on its own.
      http.max_retries = 0
      http
    end

    def build(uri, request)
      req = METHODS.fetch(request.method).new(uri)
      request.headers.each { |name, value| req[name] = value }
      req.body = request.body if request.body
      req
    end

    def headers_of(answer)
      answer.each_header.to_h { |name, value| [name.downcase, value] }
    end

    # A streamed answer: the status and headers are read when it opens, the
    # body chunk by chunk as it is iterated. Net::HTTP reads a body only inside
    # the block of #request, so the block runs in a Fiber that hands each piece
    # out as it arrives.
    class OpenStream
      attr_reader :status, :headers

      def initialize(http, request, guard)
        @http = http
        @request = request
        @guard = guard
        @done = false
      end

      def start
        @fiber = Fiber.new do
          @guard.call do
            @http.start do |conn|
              conn.request(@request) do |answer|
                Fiber.yield([:head, answer.code.to_i, answer.each_header.to_h { |k, v| [k.downcase, v] }])
                answer.read_body { |chunk| Fiber.yield([:chunk, chunk]) }
              end
            end
          end
          [:end]
        end
        kind, @status, @headers = resume
        raise APIConnectionError, "Connection closed before an answer" unless kind == :head
      end

      def header(name)
        @headers[name.downcase]
      end

      def each_chunk
        until @done
          kind, chunk = resume
          if kind == :chunk
            yield chunk
          else
            @done = true
          end
        end
      end

      def read
        body = +""
        each_chunk { |chunk| body << chunk }
        body
      end

      def close
        @done = true
        @http.finish if @http.started?
      rescue IOError
        nil
      end

      private

      def resume
        return [:end] if @done || !@fiber.alive?

        @fiber.resume
      end
    end
  end
end
