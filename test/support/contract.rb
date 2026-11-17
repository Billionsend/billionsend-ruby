# frozen_string_literal: true

require "json"
require "json_schemer"
require "set"
require "uri"

# A contract mock of the BillionSend API built from the OpenAPI snapshot,
# standing in for the client's transport. For every request it:
#
# 1. finds the operation (method + path template) in the snapshot, or fails;
# 2. checks the API key header (absent only where the operation's security is empty);
# 3. checks path, query and header parameters and validates the JSON body
#    against the operation's schema (JSON Schema 2020-12, $ref resolved through
#    the snapshot);
# 4. answers with a queued answer, or else with an instance of the operation's
#    success schema built from the schema itself (and validated against it).
#
# Every hit is recorded, so the coverage test can compare what the SDK called
# with what the snapshot declares.
module Contract
  SNAPSHOT = File.expand_path("../../openapi/api.openapi.json", __dir__)
  SPEC = JSON.parse(File.read(SNAPSHOT))
  HTTP_METHODS = %w[get put post patch delete].freeze
  API_KEY = "bs_test_key"
  BASE_URL = "https://api.test.billionsend.com"
  FORMATS = {
    "uuid" => "0b6f5a2e-7c1d-4e8a-9f3b-2d4c6e8a0b1c",
    "date-time" => "2026-01-01T00:00:00.000Z",
    "date" => "2026-01-01",
    "email" => "user@example.com",
    "uri" => "https://example.com/"
  }.freeze

  Operation = Struct.new(:method, :path, :spec, :regex, keyword_init: true) do
    def key = [method, path]

    def params(where) = spec.fetch("parameters", []).select { |p| p["in"] == where }

    def needs_auth? = spec.fetch("security", SPEC["security"]) != []

    def stream? = success_media == "text/event-stream"

    def success
      code, response = spec["responses"].select { |c, _| c.start_with?("2") }.min_by(&:first)
      raise "#{method} #{path} declares no success response" unless code

      media, body = response.fetch("content", {}).first
      [code.to_i, media || "application/json", body&.fetch("schema", nil)]
    end

    def success_media = success[1]

    def idempotency_key?
      params("header").any? { |p| p["name"].casecmp?("idempotency-key") }
    end
  end

  OPERATIONS = SPEC["paths"].flat_map do |path, item|
    item.select { |m, _| HTTP_METHODS.include?(m) }.map do |m, op|
      pattern = Regexp.escape(path).gsub(/\\\{(\w+)\\\}/) { "(?<#{Regexp.last_match(1)}>[^/]+)" }
      Operation.new(method: m.upcase, path: path, spec: op, regex: /\A#{pattern}\z/)
    end
  end.sort_by { |o| [-o.path.split("/").count { |s| !s.empty? && !s.include?("{") }, o.path] }.freeze
  OPERATION_KEYS = OPERATIONS.map(&:key).to_set.freeze

  def self.find(method, path)
    matched = false
    OPERATIONS.each do |op|
      m = op.regex.match(path)
      next unless m

      matched = true
      return [op, m.named_captures.transform_values { |v| URI.decode_www_form_component(v) }] if op.method == method
    end
    raise Minitest::Assertion, "#{method} #{path}: not an operation of the contract " \
                               "(#{matched ? "method not allowed" : "no such path"})"
  end

  def self.operation(method, path)
    OPERATIONS.find { |o| o.key == [method, path] } or raise "#{method} #{path} is not in the contract"
  end

  def self.resolve(schema)
    schema = SPEC.dig(*schema["$ref"].delete_prefix("#/").split("/")) while schema.is_a?(Hash) && schema.key?("$ref")
    schema || {}
  end

  @validators = {}
  def self.validate!(instance, schema, where)
    validator = (@validators[schema.object_id] ||= JSONSchemer.schema(
      { "components" => SPEC["components"], "allOf" => [schema] }
    ))
    errors = validator.validate(instance).first(5)
    return if errors.empty?

    details = errors.map { |e| "#{e["data_pointer"]}: #{e["type"]} #{e["error"]}" }.join("; ")
    raise Minitest::Assertion, "#{where} does not match the contract: #{details}"
  end

  # A deterministic instance of +schema+: objects get every property when
  # +full+, else only the required ones.
  def self.example(schema, full: true)
    return {} if schema.nil?

    s = resolve(schema)
    return example(s["allOf"][0], full: full) if s.fetch("allOf", []).size == 1
    return {} if (%w[type enum anyOf oneOf properties] & s.keys).empty?

    if s["anyOf"] || s["oneOf"]
      variants = s["anyOf"] || s["oneOf"]
      non_null = variants.reject { |v| resolve(v)["type"] == "null" }
      return example((non_null.empty? ? variants : non_null).first, full: full)
    end
    return s["enum"].compact.first if s.key?("enum")

    types = Array(s.fetch("type", s.key?("properties") ? "object" : nil)).reject { |t| t == "null" }
    case types.first || "null"
    when "string"
      return FORMATS[s["format"]] if FORMATS.key?(s["format"])

      "value".ljust(s.fetch("minLength", 0).to_i, "x")[0, s.fetch("maxLength", 10_000)]
    when "integer" then s.fetch("minimum", s.fetch("maximum", 1) >= 1 ? 1 : 0).to_i
    when "number" then s.fetch("minimum", 1).to_f
    when "boolean" then false
    when "null" then nil
    when "array"
      count = [s.fetch("minItems", 1).to_i, 1].max
      count = [count, s.fetch("maxItems", count).to_i].min
      Array.new(count) { example(s.fetch("items", {}), full: full) }
    when "object"
      required = s.fetch("required", [])
      s.fetch("properties", {}).each_with_object({}) do |(k, v), out|
        out[k] = example(v, full: full) if full || required.include?(k)
      end
    else raise "cannot build an example of #{s.inspect}"
    end
  end

  # A streamed answer served in the given chunks, optionally failing at the end.
  class FakeStream
    attr_reader :status, :headers, :closed

    def initialize(status, headers, chunks, error = nil)
      @status = status
      @headers = headers.transform_keys(&:downcase)
      @chunks = chunks
      @error = error
      @closed = false
    end

    def header(name) = @headers[name.downcase]

    def each_chunk(&)
      @chunks.each(&)
      raise @error if @error
    end

    def read = @chunks.join

    def close
      @closed = true
    end
  end

  Recorded = Struct.new(:operation, :request, :path_params, :query, :body, keyword_init: true) do
    def header(name)
      request.headers.find { |k, _| k.casecmp?(name) }&.last
    end
  end

  # The transport the tests hand to the client.
  class Mock
    attr_reader :calls, :streams

    def initialize
      @calls = []
      @queued = Hash.new { |h, k| h[k] = [] }
      @streams = []
    end

    # Queues one answer for an operation (FIFO), instead of the generated example.
    def respond(method, path, status = 200, json: nil, headers: {}, body: nil, chunks: nil, error: nil)
      op = Contract.operation(method, path)
      if !json.nil? && status >= 400
        Contract.validate!(json, { "$ref" => "#/components/schemas/ErrorResponse" }, "queued error")
      elsif !json.nil?
        schema = op.spec.dig("responses", status.to_s, "content", "application/json", "schema") || op.success[2]
        Contract.validate!(json, schema, "queued #{method} #{path} answer") if schema
      end
      text = body || (json.nil? ? "" : JSON.generate(json))
      headers = { "content-type" => "application/json" }.merge(headers) unless json.nil?
      @queued[op.key] << { status: status, headers: headers, body: text, chunks: chunks, error: error }
    end

    def error(method, path, status, name, message, headers: {})
      respond(method, path, status, json: { "statusCode" => status, "name" => name, "message" => message },
                                    headers: headers)
    end

    # Queues a failure without an answer.
    def fail(method, path, error)
      @queued[Contract.operation(method, path).key] << { raise: error }
    end

    def keys = @calls.map { |c| c.operation.key }

    def call(request)
      answer = handle(request)
      BillionSend::Response.new(status: answer[:status], headers: answer[:headers].transform_keys(&:downcase),
                                body: answer[:body])
    end

    def open_stream(request)
      answer = handle(request)
      chunks = answer[:chunks] || (answer[:body].empty? ? [] : [answer[:body]])
      stream = FakeStream.new(answer[:status], answer[:headers], chunks, answer[:error])
      @streams << stream
      stream
    end

    private

    def handle(request)
      raise Minitest::Assertion, "request outside #{BASE_URL}: #{request.url}" unless request.url.start_with?(BASE_URL)

      uri = URI(request.url)
      op, path_params = Contract.find(request.method, uri.path.delete_prefix(URI(BASE_URL).path))
      query = URI.decode_www_form(uri.query || "").group_by(&:first).transform_values { |v| v.map(&:last) }
      body = request.body && JSON.parse(request.body)
      record = Recorded.new(operation: op, request: request, path_params: path_params, query: query, body: body)
      @calls << record
      check(op, record)
      queued = @queued[op.key].shift
      raise queued[:raise] if queued&.key?(:raise)
      return queued if queued

      generated(op)
    end

    def check(op, record)
      where = "#{op.method} #{op.path}"
      auth = record.header("authorization")
      if op.needs_auth?
        raise Minitest::Assertion, "#{where}: no API key" unless auth == "Bearer #{API_KEY}"
      elsif auth
        raise Minitest::Assertion, "#{where}: sends an API key where none is taken"
      end
      op.params("path").each do |p|
        Contract.validate!(record.path_params.fetch(p["name"]), p.fetch("schema", {}), "#{where} path #{p["name"]}")
      end
      known = op.params("query").to_h { |p| [p["name"], p] }
      record.query.each do |name, values|
        raise Minitest::Assertion, "#{where}: unknown query parameter #{name}" unless known.key?(name)
        raise Minitest::Assertion, "#{where}: query parameter #{name} sent twice" if values.size > 1

        enum = Contract.resolve(known[name].fetch("schema", {}))["enum"]
        if enum && !enum.include?(values.first)
          raise Minitest::Assertion, "#{where}: #{name}=#{values.first} is not one of #{enum}"
        end
      end
      (op.params("query") + op.params("header")).select { |p| p["required"] }.each do |p|
        present = p["in"] == "query" ? record.query.key?(p["name"]) : record.header(p["name"])
        raise Minitest::Assertion, "#{where}: missing required #{p["in"]} #{p["name"]}" unless present
      end
      if op.idempotency_key? && record.header("idempotency-key").nil?
        raise Minitest::Assertion, "#{where}: no Idempotency-Key"
      end
      body = op.spec["requestBody"]
      if body.nil?
        raise Minitest::Assertion, "#{where}: sends a body the operation does not take" unless record.body.nil?
      elsif record.body.nil?
        raise Minitest::Assertion, "#{where}: no body" if body["required"]
      else
        Contract.validate!(record.body, body.dig("content", "application/json", "schema"), "#{where} body")
      end
    end

    def generated(op)
      status, media, schema = op.success
      if media == "text/event-stream"
        return { status: status, headers: { "content-type" => media }, body: "", chunks: [] }
      end

      json = Contract.example(schema)
      Contract.validate!(json, schema, "generated #{op.method} #{op.path} answer") if schema
      { status: status, headers: { "content-type" => "application/json" }, body: schema ? JSON.generate(json) : "" }
    end
  end
end
