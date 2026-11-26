# frozen_string_literal: true

require "json"
require "securerandom"

module BillionSend
  # The +multipart/form-data+ body of an upload (a logo, a contact import's CSV).
  #
  # A file field takes the content as a String (the bytes themselves), anything
  # that answers +read+ (a File, a StringIO, a Pathname, an uploaded file), or a
  # Hash <tt>{ content:, filename:, content_type: }</tt> whose last two keys are
  # optional. Without a +filename+ an object's own name is used, else the
  # field's; without a +content_type+ it follows from the name.
  #
  # In every other field a Hash or Array is sent as JSON, nil is left out and
  # anything else is sent as its text.
  #
  # @api private
  module Multipart
    CONTENT_TYPES = {
      ".csv" => "text/csv",
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".webp" => "image/webp"
    }.freeze
    FILE_KEYS = %i[content filename content_type].freeze

    # The Content-Type header and the body for +form+. The fields named in
    # +files+, and any value that answers +read+, are sent as files. The body is
    # built once, so a retry sends the same bytes without reading a file again.
    def self.encode(form, files: [])
      boundary = "billionsend-#{SecureRandom.hex(16)}"
      body = "".b
      form.each do |key, value|
        next if value.nil?

        name = key.to_s
        file = files.include?(name) || value.respond_to?(:read)
        head, content = file ? file_part(name, value) : ["", text(value)]
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{quoted(name)}\"".b
        body << head.b << "\r\n\r\n" << content.b << "\r\n"
      end
      body << "--#{boundary}--\r\n"
      ["multipart/form-data; boundary=#{boundary}", body]
    end

    # What follows the field's name in a file part's headers, and the file's bytes.
    def self.file_part(field, value)
      options = value.is_a?(Hash) ? value.transform_keys(&:to_sym) : { content: value }
      unless options.key?(:content) && (options.keys - FILE_KEYS).empty?
        raise ArgumentError, "#{field}: a file Hash takes content:, filename: and content_type:"
      end

      content = options[:content]
      filename = (options[:filename] || own_name(content) || field).to_s
      type = options[:content_type] || CONTENT_TYPES.fetch(File.extname(filename).downcase, "application/octet-stream")
      data = if content.is_a?(String) then content
             elsif content.respond_to?(:read) then content.read.to_s
             else raise ArgumentError, "#{field}: a file is a String or answers read"
             end
      ["; filename=\"#{quoted(filename)}\"\r\nContent-Type: #{quoted(type.to_s)}", data]
    end

    # The name an object carries: an uploaded file's original one, else its path's last part.
    def self.own_name(content)
      return content.original_filename if content.respond_to?(:original_filename)

      path = if content.respond_to?(:path) then content.path
             elsif content.respond_to?(:to_path) then content.to_path
             end
      path && File.basename(path.to_s)
    end

    def self.text(value)
      value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
    end

    # A quote or a line break would end the header's value early.
    def self.quoted(text)
      text.b.gsub(/["\r\n]/, "\"" => "%22", "\r" => "%0D", "\n" => "%0A").force_encoding(text.encoding)
    end

    private_class_method :file_part, :own_name, :text, :quoted
  end
end
