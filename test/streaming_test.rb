# frozen_string_literal: true

require "test_helper"

class SSEDecoderTest < Minitest::Test
  def test_parses_events_split_anywhere_and_any_line_ending
    text = "﻿: keepalive\r\nid: 1\r\nevent: inbox.email.received\r\ndata: {\"a\":\r\n\r\n" \
           "id: 2\nevent: x\ndata: line one\ndata: line two\n\n" \
           "id: 3\revent: y\rdata: {\"é\": 1}\r\r"
    bytes = text.b
    decoder = BillionSend::SSEDecoder.new
    events = []
    bytes.each_char.each_slice(3) { |slice| events.concat(decoder.feed(slice.join)) }
    assert_equal %w[1 2 3], events.map(&:id)
    assert_equal ["inbox.email.received", "x", "y"], events.map(&:event)
    assert_equal "{\"a\":", events[0].data
    assert_equal "line one\nline two", events[1].data
    assert_equal({ "é" => 1 }, events[2].data)
  end

  def test_retry_and_default_event_name
    decoder = BillionSend::SSEDecoder.new
    events = decoder.feed("retry: 2500\ndata: {}\n\n")
    assert_equal 2500, decoder.retry_ms
    assert_equal "message", events.first.event
  end
end

class SSEPositionTest < Minitest::Test
  def test_an_id_counts_once_its_block_is_complete
    decoder = BillionSend::SSEDecoder.new
    decoder.feed("id: 1\ndata: {}\n\nid: 2\ndata: {")
    assert_equal "1", decoder.last_event_id
    decoder.feed("}\n\n")
    assert_equal "2", decoder.last_event_id
  end
end

class EventStreamTest < Minitest::Test
  include ClientHelpers

  TEAM = "/inboxes/events"
  INBOX = "/inboxes/{inbox_id}/events"

  def frame(id, event, inbox = "ib_1")
    data = { "type" => event, "created_at" => "2026-11-17T00:00:00.000Z", "inbox_id" => inbox, "data" => {} }
    "id: #{id}\nevent: #{event}\ndata: #{JSON.generate(data)}\n\n"
  end

  def stream_answer(path, chunks, error: nil)
    mock.respond("GET", path, 200, headers: { "content-type" => "text/event-stream" }, body: "", chunks: chunks,
                                   error: error)
  end

  def test_reconnects_with_the_last_event_id_and_resumes
    stream_answer(TEAM, [frame("1", "inbox.email.received"), frame("2", "inbox.thread.created")])
    stream_answer(TEAM, ["retry: 250\n", frame("3", "inbox.email.received")],
                  error: BillionSend::APIConnectionError.new)
    stream_answer(TEAM, [frame("4", "inbox.email.received")])
    stream = client.inboxes.events.stream(types: %w[inbox.email.received inbox.thread.created])
    got = stream.first(4)
    stream.close
    assert_equal %w[1 2 3 4], got.map(&:id)
    assert(got.all?(BillionSend::InboxStreamEvent))
    assert_equal [nil, "2", "3"], mock.calls.map { |c| c.header("last-event-id") }
    assert_equal ["inbox.email.received,inbox.thread.created"], mock.calls.first.query["types"]
    assert_equal [1.0, 0.25], sleeps
    assert_equal "4", stream.last_event_id
    assert(mock.streams.all?(&:closed))
  end

  def test_an_id_without_data_moves_the_position_even_when_the_connection_drops
    stream_answer(TEAM, ["id: 7\n\n"], error: BillionSend::APIConnectionError.new)
    stream_answer(TEAM, [frame("8", "inbox.email.received"), "id: 9\ndata: {"],
                  error: BillionSend::APIConnectionError.new)
    stream_answer(TEAM, [frame("10", "inbox.email.received")])
    stream = client.inboxes.events.stream
    assert_equal %w[8 10], stream.first(2).map(&:id)
    assert_equal [nil, "7", "8"], mock.calls.map { |c| c.header("last-event-id") }
  end

  def test_a_gap_is_handed_out_once_per_position
    gap = "event: stream.gap\ndata: {\"reason\":\"retention\"}\n\n"
    stream_answer(TEAM, [gap])
    stream_answer(TEAM, [gap, frame("9", "inbox.email.received")])
    stream = client.inboxes.events.stream(last_event_id: "old")
    got = stream.first(2)
    stream.close
    assert_instance_of BillionSend::StreamGapEvent, got[0]
    assert_equal "stream.gap", got[0].event
    assert_equal({ "reason" => "retention" }, got[0].data)
    assert_equal "9", got[1].id
  end

  def test_an_inbox_stream_ends_after_the_inbox_is_deleted
    stream_answer(INBOX, [frame("1", "inbox.email.received"), frame("2", "inbox.deleted")])
    events = client.inboxes.events.stream_inbox("support@example.com").to_a
    assert_equal %w[inbox.email.received inbox.deleted], events.map(&:event)
    assert_equal 1, mock.calls.size
  end

  def test_a_refused_stream_raises_when_opened
    mock.error("GET", TEAM, 403, "forbidden", "Needs a team-wide key")
    assert_raises(BillionSend::PermissionDeniedError) { client.inboxes.events.stream }
  end

  def test_reconnect_failures_are_bounded
    stream_answer(TEAM, [frame("1", "inbox.email.received")])
    3.times { mock.error("GET", TEAM, 503, "unavailable", "Try later") }
    stream = client.inboxes.events.stream(max_reconnects: 2)
    error = assert_raises(BillionSend::APIError) { stream.each { nil } }
    assert_equal "Try later", error.message
    assert_equal [1.0, 1.0], sleeps
  end

  def test_a_quiet_inbox_keeps_reconnecting
    # The server ends a stream every ten minutes; a quiet inbox gets only keepalives.
    8.times { stream_answer(TEAM, [": keepalive\n\n"]) }
    stream_answer(TEAM, [frame("1", "inbox.email.received")])
    stream = client.inboxes.events.stream(max_reconnects: 1)
    assert_equal %w[1], stream.first(1).map(&:id)
    assert_equal 9, mock.calls.size
    assert_equal [1.0] * 8, sleeps
  end

  def test_a_connection_that_opens_starts_the_count_again
    # Without the reset, the 3rd failed reconnect would pass max_reconnects 2.
    stream_answer(TEAM, [])
    2.times do
      mock.error("GET", TEAM, 503, "unavailable", "Try later")
      stream_answer(TEAM, [])
    end
    mock.error("GET", TEAM, 503, "unavailable", "Try later")
    stream_answer(TEAM, [frame("1", "inbox.email.received")])
    stream = client.inboxes.events.stream(max_reconnects: 2)
    assert_equal %w[1], stream.first(1).map(&:id)
  end

  def test_the_blocks_connection_error_is_not_a_disconnect
    stream_answer(TEAM, [frame("1", "inbox.email.received"), frame("2", "inbox.email.received")])
    stream = client.inboxes.events.stream
    got = []
    error = assert_raises(BillionSend::APIConnectionError) do
      stream.each do |event|
        got << event.id
        raise BillionSend::APIConnectionError, "the reply failed"
      end
    end
    assert_equal "the reply failed", error.message
    assert_equal %w[1], got
    assert_equal 1, mock.calls.size
    assert(mock.streams.all?(&:closed))
  end

  def test_a_refused_reconnect_waits_its_retry_after_and_raises_the_apis_error
    stream_answer(TEAM, [frame("1", "inbox.email.received")])
    3.times { mock.error("GET", TEAM, 429, "too_many_streams", "Too many open streams", headers: { "retry-after" => "5" }) }
    stream = client.inboxes.events.stream(max_reconnects: 2)
    error = assert_raises(BillionSend::RateLimitError) { stream.each { nil } }
    assert_equal "too_many_streams", error.name
    assert_equal [1.0, 5.0], sleeps
  end

  def test_a_retry_after_over_a_minute_raises_at_once
    stream_answer(TEAM, [frame("1", "inbox.email.received")])
    mock.error("GET", TEAM, 503, "unavailable", "Down for maintenance", headers: { "retry-after" => "120" })
    stream = client.inboxes.events.stream
    assert_raises(BillionSend::APIError) { stream.each { nil } }
    assert_equal [1.0], sleeps
    assert_equal 2, mock.calls.size
  end

  def test_reconnects_that_get_no_answer_raise_a_connection_error
    stream_answer(TEAM, [frame("1", "inbox.email.received")])
    mock.error("GET", TEAM, 429, "too_many_streams", "Too many open streams", headers: { "retry-after" => "2" })
    2.times { mock.fail("GET", TEAM, BillionSend::APIConnectionError.new("Connection refused")) }
    stream = client.inboxes.events.stream(max_reconnects: 2)
    error = assert_raises(BillionSend::APIConnectionError) { stream.each { nil } }
    assert_equal "The event stream disconnected; gave up after 2 reconnects", error.message
    assert_equal [1.0, 2.0], sleeps
  end

  def test_a_refused_reconnect_raises_its_own_error
    stream_answer(TEAM, [frame("1", "inbox.email.received")])
    mock.error("GET", TEAM, 401, "invalid_api_key", "Revoked")
    stream = client.inboxes.events.stream
    assert_raises(BillionSend::AuthenticationError) { stream.each { nil } }
  end

  def test_without_reconnects_a_dropped_connection_raises
    stream_answer(TEAM, [frame("1", "inbox.email.received")], error: BillionSend::APIConnectionError.new)
    stream = client.inboxes.events.stream(max_reconnects: 0)
    got = []
    assert_raises(BillionSend::APIConnectionError) { stream.each { |e| got << e } }
    assert_equal 1, got.size
  end
end
