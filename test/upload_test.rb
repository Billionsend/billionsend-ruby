# frozen_string_literal: true

require "test_helper"
require "pathname"
require "stringio"
require "tempfile"

# The multipart uploads: a contact import's CSV and the two logos.
class UploadTest < Minitest::Test
  include ClientHelpers

  PNG = "\x89PNG\r\n\x1a\n\x00\xff".b.freeze
  CSV = "Email,First Name\nada@example.com,Ada\n"
  UPLOADS = [
    ["PUT", "/brand/logo", ->(c, file) { c.brand.logo.upload({ file: file }) }],
    ["PUT", "/domains/{id}/unsubscribe-page/logo",
     ->(c, file) { c.domains.unsubscribe_page.logo.upload(ClientHelpers::ID, { file: file }) }],
    ["POST", "/contacts/imports", ->(c, file) { c.contacts.imports.create({ file: file }) }]
  ].freeze

  def parts
    mock.calls.last.parts.to_h { |part| [part.name, part] }
  end

  def upload_logo(file)
    client.brand.logo.upload({ "file" => file })
    parts.fetch("file")
  end

  def test_every_upload_sends_its_file_as_multipart
    UPLOADS.each do |_, path, call|
      call.call(client, PNG)
      assert_match(%r{\Amultipart/form-data; boundary=\S+\z}, mock.calls.last.header("content-type"))
      assert_equal path.sub("{id}", ID), URI(mock.calls.last.request.url).path
      assert_equal PNG, parts.fetch("file").data
      assert_equal "file", parts.fetch("file").filename
      assert_equal "application/octet-stream", parts.fetch("file").content_type
    end
  end

  def test_a_contact_import_encodes_its_json_fields
    map = { "email" => "Email", "first_name" => "First Name" }
    segments = [{ "id" => ID }]
    client.contacts.imports.create(
      { file: { content: CSV, filename: "contacts.csv" }, column_map: map, segments: segments,
        topics: JSON.generate([]), on_conflict: "skip" }
    )
    assert_equal CSV, parts.fetch("file").data
    assert_equal "contacts.csv", parts.fetch("file").filename
    assert_equal "text/csv", parts.fetch("file").content_type
    assert_equal map, JSON.parse(parts.fetch("column_map").data)
    assert_equal segments, JSON.parse(parts.fetch("segments").data)
    assert_equal "[]", parts.fetch("topics").data
    assert_equal "skip", parts.fetch("on_conflict").data
    assert_nil parts.fetch("column_map").filename
  end

  def test_a_nil_field_is_left_out
    client.contacts.imports.create({ file: CSV, column_map: nil })
    assert_equal ["file"], parts.keys
  end

  def test_an_open_file_and_a_pathname_keep_their_name
    Tempfile.create(["logo", ".webp"]) do |file|
      file.binmode
      file.write(PNG)
      file.flush
      [File.open(file.path, "rb"), Pathname.new(file.path)].each do |source|
        part = upload_logo(source)
        assert_equal File.basename(file.path), part.filename
        assert_equal "image/webp", part.content_type
        assert_equal PNG, part.data
        source.close if source.respond_to?(:close)
      end
    end
  end

  def test_an_io_without_a_name_and_an_uploaded_file
    assert_equal "file", upload_logo(StringIO.new(PNG.dup)).filename
    uploaded = StringIO.new(PNG.dup)
    uploaded.define_singleton_method(:original_filename) { "brand.jpeg" }
    part = upload_logo(uploaded)
    assert_equal "brand.jpeg", part.filename
    assert_equal "image/jpeg", part.content_type
  end

  def test_the_given_name_and_content_type_win
    part = upload_logo({ "content" => StringIO.new(PNG.dup), "filename" => "a.png", "content_type" => "image/x-test" })
    assert_equal "a.png", part.filename
    assert_equal "image/x-test", part.content_type
  end

  def test_a_line_break_or_quote_cannot_end_a_header
    upload_logo({ content: PNG, filename: "a\"\r\nX-Evil: 1.png", content_type: "image/png\r\nX-Evil: 2" })
    body = mock.calls.last.request.body
    assert_includes body, "filename=\"a%22%0D%0AX-Evil: 1.png\"".b
    assert_includes body, "Content-Type: image/png%0D%0AX-Evil: 2\r\n".b
  end

  def test_a_non_ascii_name_is_sent_as_utf8
    upload_logo({ content: PNG, filename: "标志.png" })
    assert_includes mock.calls.last.request.body, "filename=\"标志.png\"".b
  end

  def test_what_is_not_a_file_is_refused_before_sending
    [42, { filename: "a.png" }, { content: PNG, name: "a.png" }].each do |file|
      assert_raises(ArgumentError) { client.brand.logo.upload({ file: file }) }
    end
    assert_empty mock.calls
  end

  def test_an_upload_is_not_repeated_after_a_5xx_or_a_lost_answer
    UPLOADS.each do |method, path, call|
      [BillionSend::APIError, BillionSend::APIConnectionError, BillionSend::APITimeoutError].each do |klass|
        before = mock.calls.size
        if klass == BillionSend::APIError
          mock.error(method, path, 503, "unavailable", "Try later")
        else
          mock.fail(method, path, klass.new)
        end
        assert_raises(klass) { call.call(client, PNG) }
        assert_equal before + 1, mock.calls.size, "#{method} #{path} #{klass}"
      end
    end
    assert_empty sleeps
  end

  def test_an_upload_is_repeated_after_a_429_with_the_same_bytes
    UPLOADS.each do |method, path, call|
      mock.error(method, path, 429, "rate_limit_exceeded", "Slow down", headers: { "retry-after" => "1" })
      before = mock.calls.size
      call.call(client, StringIO.new(PNG.dup))
      first, second = mock.calls[before..]
      assert_equal first.request.body, second.request.body
      assert_equal PNG, second.parts.first.data
    end
    assert_equal [1.0] * UPLOADS.size, sleeps
  end

  def test_a_delete_of_a_logo_is_repeated_after_a_5xx
    mock.error("DELETE", "/brand/logo", 503, "unavailable", "Try later")
    client.brand.logo.delete
    assert_equal 2, mock.calls.size
  end

  def test_a_form_through_request_takes_an_io_as_a_file
    client.request("PUT", "/brand/logo", form: { file: StringIO.new(PNG.dup) })
    assert_equal PNG, parts.fetch("file").data
    assert_equal "file", parts.fetch("file").filename
  end
end
