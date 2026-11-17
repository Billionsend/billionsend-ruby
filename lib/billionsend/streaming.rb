# frozen_string_literal: true

require "json"

module BillionSend
  # One raw event of a +text/event-stream+ answer.
  #
  # +id+ is the stream position to resume from (the last id field seen),
  # +event+ the event name, +data+ the data parsed as JSON (the raw text if it
  # is not JSON).
  ServerSentEvent = Struct.new(:id, :event, :data, keyword_init: true)

  # One inbox event: the webhook event of the same name, wrapped.
  #
  # +id+ is the stream position after this event (resume from it with
  # +last_event_id:+), +event+ the event name (such as "inbox.email.received"),
  # +data+ a Hash with "type", "created_at", "inbox_id" (nil for an
  # email.received that reached no inbox) and the webhook payload's "data".
  InboxStreamEvent = Struct.new(:id, :event, :data, keyword_init: true)

  # Events may have been lost before this point: catch up through the REST
  # lists. +data+ is a Hash whose "reason" says why ("retention": the position
  # is over 24 hours old).
  StreamGapEvent = Struct.new(:data, keyword_init: true) do
    def id = nil
    def event = EventStream::GAP_EVENT
  end

  # Incremental parser of the +text/event-stream+ format.
  #
  # Lines may end in CRLF, LF or CR and may be split anywhere across chunks;
  # comment lines are skipped; several data lines join with newlines.
  class SSEDecoder
    attr_reader :last_event_id, :retry_ms

    def initialize
      @bytes = "".b
      @buffer = +""
      @started = false
      @after_cr = false
      @data = []
      @event = ""
      @last_event_id = nil
      @retry_ms = nil
    end

    # Feeds one chunk of bytes; returns the events it completed.
    def feed(chunk)
      text = decode(chunk)
      if !@started && !text.empty?
        @started = true
        text = text.delete_prefix("﻿")
      end
      if @after_cr && !text.empty?
        # The previous chunk ended in CR: a LF here completes that CRLF.
        @after_cr = false
        text = text.delete_prefix("\n")
      end
      @buffer << text
      events = []
      while (index = @buffer.index(/[\r\n]/))
        finish = index + 1
        if @buffer[index] == "\r"
          if index + 1 == @buffer.length
            @after_cr = true
          elsif @buffer[index + 1] == "\n"
            finish = index + 2
          end
        end
        line = @buffer[0, index]
        @buffer = @buffer[finish..]
        event = line(line)
        events << event if event
      end
      events
    end

    private

    # UTF-8 text of the bytes so far, keeping an incomplete trailing character for the next chunk.
    def decode(chunk)
      @bytes << chunk.b
      cut = @bytes.bytesize
      # Back off over at most 3 continuation bytes to the start of a split character.
      (1..[3, cut].min).each do |back|
        byte = @bytes.getbyte(cut - back)
        next if byte & 0xC0 == 0x80

        width = if byte >= 0xF0 then 4
                elsif byte >= 0xE0 then 3
                elsif byte >= 0xC0 then 2
                else 1
                end
        cut -= back if width > back
        break
      end
      text = @bytes.byteslice(0, cut)
      @bytes = @bytes.byteslice(cut..)
      text.force_encoding(Encoding::UTF_8).scrub("�")
    end

    def line(line)
      return dispatch if line.empty?
      return nil if line.start_with?(":")

      name, value = line.split(":", 2)
      value = value.to_s.delete_prefix(" ")
      case name
      when "data" then @data << value
      when "event" then @event = value
      when "id" then @last_event_id = value unless value.include?("\0")
      when "retry" then @retry_ms = Integer(value, 10) if value.match?(/\A[0-9]+\z/)
      end
      nil
    end

    def dispatch
      if @data.empty?
        @event = ""
        return nil
      end
      raw = @data.join("\n")
      data = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end
      event = ServerSentEvent.new(id: @last_event_id, event: @event.empty? ? "message" : @event, data: data)
      @data = []
      @event = ""
      event
    end
  end

  # A server-sent event stream (+text/event-stream+) of inbox events.
  #
  # The method that returns it opens it, so a refused stream raises at once.
  # Iterating yields {InboxStreamEvent} and {StreamGapEvent} objects; when the
  # server ends the stream (it does so every few minutes) or the connection
  # drops, the stream reconnects with Last-Event-ID set to the last id it saw
  # and resumes without losing events, waiting a second (or the server's retry
  # field) first. A connection that opens starts the count again, however
  # quiet the inbox. A reconnect the API answers with a 429 or 5xx waits what
  # its Retry-After asks (one over 60 seconds raises that error at once). After
  # +max_reconnects+ reconnects in a row that fail to open, iterating raises
  # the API's error for the last one ({RateLimitError}, {APIError}), or
  # {APIConnectionError} when it got no answer; a reconnect the API refuses for
  # good (a revoked key) raises its own error. An error raised by the block
  # passes through as it is.
  #
  # The server replays at most 24 hours of missed events. A stream resumed from
  # an older id first gets a {StreamGapEvent}: events may be missing, so read
  # the REST lists to catch up. It is handed out once per position, although
  # the server repeats it on every reconnect until a newer event arrives.
  #
  # The stream of one inbox ends (iteration stops) after that inbox's
  # inbox.deleted or inbox.expired event. Close the stream when done.
  class EventStream
    include Enumerable

    DEFAULT_RETRY = 1.0
    GAP_EVENT = "stream.gap"
    TEAM_STREAM_PATH = "/inboxes/events"
    # After one of these, the server ends an inbox's own stream for good.
    INBOX_GONE = %w[inbox.deleted inbox.expired].freeze

    # The id of the last event received: pass it as +last_event_id:+ to resume later.
    attr_reader :last_event_id

    def initialize(client, path, query:, last_event_id:, max_reconnects:, extra_headers:, timeout:)
      raise ArgumentError, "max_reconnects must be 0 or more" if max_reconnects.negative?

      @client = client
      @path = path
      @query = query
      @last_event_id = last_event_id
      @max_reconnects = max_reconnects
      @extra_headers = extra_headers
      @timeout = timeout
      @retry = DEFAULT_RETRY
      @closed = false
      @one_inbox = path.sub(%r{/+\z}, "") != TEAM_STREAM_PATH
      # The position a gap was last handed out at; the server repeats it on reconnect.
      @gap_at = nil
      @response = nil
    end

    # @api private
    def open
      @response = @client.open_stream(@path, query: @query, last_event_id: @last_event_id,
                                             extra_headers: @extra_headers, timeout: @timeout)
    end

    def each
      return enum_for(:each) unless block_given?

      # The end of the last open connection, then each reconnect that failed to open.
      failures = 0
      # The API's answer to the last failed reconnect, and the wait it asked for.
      last_error = nil
      wait = nil
      until @closed
        if @response
          failures = 0
          last_error = nil
          response = @response
          decoder = SSEDecoder.new
          # Set while the block runs: its errors are the caller's, not a dropped connection.
          in_block = false
          begin
            response.each_chunk do |chunk|
              decoder.feed(chunk).each do |sse|
                event = saw(sse)
                next unless event

                in_block = true
                yield event
                in_block = false
                break if @closed
              end
              break if @closed
            end
            # Every event was handed out; an id sent without data still moves the position.
            @last_event_id = decoder.last_event_id if !@closed && decoder.last_event_id
          rescue APIConnectionError
            raise if in_block

            nil # the connection dropped: reconnect below
          ensure
            @retry = decoder.retry_ms / 1000.0 if decoder.retry_ms
            response.close
            @response = nil
          end
        end
        return if @closed

        failures += 1
        if failures > @max_reconnects
          raise last_error if last_error

          raise APIConnectionError, "The event stream disconnected; gave up after #{@max_reconnects} reconnects"
        end

        @client.pause(wait || @retry)
        begin
          open
        rescue APIConnectionError
          last_error = wait = nil # no answer: counted on the next turn
        rescue RateLimitError, APIError => e
          wait = e.response && Client.retry_after(e.response)
          raise if wait && wait > Client::MAX_RETRY_DELAY

          last_error = e
        end
      end
    end

    def close
      @closed = true
      @response&.close
      @response = nil
    end

    private

    # The event to hand out for +sse+, or nil for a repeated gap.
    def saw(sse)
      if sse.event == GAP_EVENT
        return nil if @gap_at == [@last_event_id]

        @gap_at = [@last_event_id]
        reason = sse.data.is_a?(Hash) && sse.data["reason"].is_a?(String) ? sse.data["reason"] : "unknown"
        return StreamGapEvent.new(data: { "reason" => reason })
      end
      if sse.id.nil? || !sse.data.is_a?(Hash)
        raise Error, "Malformed #{sse.event.inspect} event in the stream"
      end

      @last_event_id = sse.id
      @closed = true if @one_inbox && INBOX_GONE.include?(sse.event)
      InboxStreamEvent.new(id: sse.id, event: sse.event, data: sse.data)
    end
  end
end
