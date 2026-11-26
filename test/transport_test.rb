# frozen_string_literal: true

require "test_helper"
require "socket"

# The Net::HTTP transport against a real socket: requests, answers, streamed
# bodies read chunk by chunk, and failures without an answer.
class TransportTest < Minitest::Test
  def serve(handler)
    server = TCPServer.new("127.0.0.1", 0)
    @requests = []
    thread = Thread.new do
      loop do
        socket = server.accept
        head = "".b
        head << socket.readpartial(4096) until head.include?("\r\n\r\n")
        request_line, *lines = head.split("\r\n\r\n", 2).first.split("\r\n")
        headers = lines.to_h { |l| l.split(": ", 2).then { |k, v| [k.downcase, v] } }
        body = head.split("\r\n\r\n", 2).last
        body << socket.read(headers["content-length"].to_i - body.bytesize) if headers["content-length"]
        @requests << { line: request_line, headers: headers, body: body }
        handler.call(socket, request_line)
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill
  end

  def client(url, **options)
    BillionSend::Client.new(api_key: "bs_socket_test", base_url: url, **options)
  end

  def test_a_json_request_and_answer
    serve(lambda do |socket, _|
      body = '{"object":"list","has_more":false,"data":[]}'
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Request-Id: req_1\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end) do |url|
      assert_equal({ "object" => "list", "has_more" => false, "data" => [] }, client(url).domains.list(limit: 3))
      assert_equal "GET /domains?limit=3 HTTP/1.1", @requests.first[:line]
      assert_equal "Bearer bs_socket_test", @requests.first[:headers]["authorization"]
    end
  end

  def test_an_error_answer_keeps_the_request_id
    serve(lambda do |socket, _|
      body = '{"statusCode":422,"name":"validation_error","message":"Invalid from"}'
      socket.write("HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nX-Request-Id: req_9\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end) do |url|
      error = assert_raises(BillionSend::ValidationError) do
        client(url).emails.send({ from: "x", to: ["y@example.com"], subject: "s", text: "t" })
      end
      assert_equal "req_9", error.request_id
      assert_equal '{"from":"x","to":["y@example.com"],"subject":"s","text":"t"}', @requests.first[:body]
      assert_match(/\A\h{8}-/, @requests.first[:headers]["idempotency-key"])
    end
  end

  def test_an_event_stream_is_read_as_it_arrives
    release = Queue.new
    serve(lambda do |socket, _|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      first = %(id: 1\nevent: inbox.email.received\ndata: {"type":"inbox.email.received","inbox_id":"i","data":{}}\n\n)
      socket.write("#{first.bytesize.to_s(16)}\r\n#{first}\r\n")
      socket.flush
      release.pop
      socket.write("0\r\n\r\n")
    end) do |url|
      stream = client(url).inboxes.events.stream(max_reconnects: 0)
      event = nil
      stream.each do |e|
        event = e
        release << true
        break
      end
      stream.close
      assert_equal "1", event.id
      assert_equal "text/event-stream", @requests.first[:headers]["accept"]
    end
  end

  def test_an_upload_reaches_the_socket_byte_for_byte
    serve(lambda do |socket, _|
      body = '{"object":"logo","logo_url":"https://example.com/l.png"}'
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end) do |url|
      bytes = (0..255).to_a.pack("C*") * 64
      client(url).brand.logo.upload({ file: { content: bytes, filename: "l.png" } })
      request = @requests.first
      assert_equal "PUT /brand/logo HTTP/1.1", request[:line]
      part = Contract.parse_multipart(request[:body], request[:headers]["content-type"]).fetch(0)
      assert_equal bytes, part.data
      assert_equal "image/png", part.content_type
    end
  end

  def test_a_body_that_cannot_be_decoded_is_a_connection_error
    serve(lambda do |socket, _|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\n" \
                   "Content-Length: 8\r\nConnection: close\r\n\r\nnot gzip")
    end) do |url|
      c = client(url, max_retries: 1)
      c.sleeper = ->(_) {}
      assert_raises(BillionSend::APIConnectionError) { c.domains.list }
      assert_equal 2, @requests.size
    end
  end

  def test_no_answer_is_a_connection_error_and_is_retried_for_a_get
    serve(->(socket, _) { socket.close }) do |url|
      c = client(url, max_retries: 1)
      c.sleeper = ->(_) {}
      assert_raises(BillionSend::APIConnectionError) { c.domains.list }
      assert_equal 2, @requests.size
    end
  end

  def test_a_slow_answer_times_out
    serve(->(_socket, _) { sleep 2 }) do |url|
      error = assert_raises(BillionSend::APITimeoutError) { client(url, timeout: 0.3, max_retries: 0).domains.list }
      assert_match(/timed out/, error.message)
    end
  end
end
