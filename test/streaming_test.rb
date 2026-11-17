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
    assert_raises(BillionSend::APIError) { stream.each { nil } }
    assert_equal [1.0, 1.0, 2.0], sleeps
  end

  def test_without_reconnects_a_dropped_connection_raises
    stream_answer(TEAM, [frame("1", "inbox.email.received")], error: BillionSend::APIConnectionError.new)
    stream = client.inboxes.events.stream(max_reconnects: 0)
    got = []
    assert_raises(BillionSend::APIConnectionError) { stream.each { |e| got << e } }
    assert_equal 1, got.size
  end
end
