#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates lib/billionsend/resources.rb from the OpenAPI snapshot.
#
# One method per operation, grouped into resource classes. Each method is named
# by its operationId: the dotted path of the method, segments in camelCase
# (emails.receiving.attachments.list is client.emails.receiving.attachments.list),
# written here in snake_case. Lists with after/before cursors also get a
# <name>_all method that pages through every item.
#
# Usage:
#
#   ruby script/generate.rb          # rewrite the generated file
#   ruby script/generate.rb --check  # fail if it differs from the snapshot

require "json"

ROOT = File.expand_path("..", __dir__)
SNAPSHOT = File.join(ROOT, "openapi", "api.openapi.json")
OUT = File.join(ROOT, "lib", "billionsend", "resources.rb")

HTTP_METHODS = %w[get put post patch delete].freeze
IDEMPOTENCY_KEY_HEADER = "idempotency-key"
BODY_MEDIA = %w[application/json multipart/form-data].freeze
# Header parameters -> keyword argument names.
HEADER_KWARGS = { "x-batch-validation" => "batch_validation" }.freeze
RESERVED = %w[params extra_headers timeout idempotency_key max_reconnects].freeze
RUBY_KEYWORDS = %w[
  BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in
  module next nil not or redo rescue retry return self super then true undef unless until when while
  yield
].freeze
WIDTH = 100

Param = Struct.new(:name, :rb, :where, :required, keyword_init: true)
Operation = Struct.new(:method, :path, :resource, :name, :summary, :description, :path_params,
                       :query_params, :header_params, :body, :body_required, :body_omit_when_none,
                       :files, :stream, :idempotency_key, :paginated, :auth, keyword_init: true)

def snake(text)
  text.gsub(/([a-z0-9])([A-Z])/, '\1_\2').gsub(/[^0-9a-zA-Z]+/, "_").gsub(/\A_+|_+\z/, "").downcase
end

def pascal(text)
  text.split(/[^0-9a-zA-Z]+/).reject(&:empty?).map { |p| p[0].upcase + p[1..] }.join
end

def rbname(text)
  name = snake(text)
  RUBY_KEYWORDS.include?(name) || RESERVED.include?(name) ? "#{name}_" : name
end

def resolve(spec, schema)
  schema = spec.dig("components", "schemas", schema["$ref"].split("/").last) while schema&.key?("$ref")
  schema || {}
end

def types_of(schema)
  Array(schema["type"])
end

def has_id?(spec, schema)
  branches = schema["anyOf"] || schema["oneOf"]
  return branches.all? { |b| has_id?(spec, resolve(spec, b)) } if branches

  schema.fetch("properties", {}).key?("id")
end

def build_operations(spec)
  found = spec["paths"].flat_map do |path, item|
    item.select { |m, _| HTTP_METHODS.include?(m) }.map { |m, op| [m.upcase, path, op] }
  end
  ids = found.map { |_, _, op| op["operationId"] }
  abort "every operation needs an operationId, each one different" if ids.include?(nil) || ids.uniq.size != ids.size

  # An operationId that is also the group of others (emails.metrics beside
  # emails.metrics.links) becomes that group's `call`:
  # client.emails.metrics.call(...), or client.emails.metrics.(...).
  groups = ids.flat_map { |id| parts = id.split("."); (1...parts.size).map { |i| parts[0, i].join(".") } }
  found.map do |method, path, op|
    *group, last = op["operationId"].split(".")
    if groups.include?(op["operationId"])
      group << last
      last = "call"
    end
    params = op.fetch("parameters", [])
    o = Operation.new(
      method: method, path: path, resource: group.map { |g| snake(g) }.join("."), name: snake(last),
      summary: op.fetch("summary", ""), description: op.fetch("description", ""),
      path_params: [], query_params: [], header_params: [],
      idempotency_key: params.any? { |p| p["in"] == "header" && p["name"].downcase == IDEMPOTENCY_KEY_HEADER },
      auth: op.fetch("security", spec["security"]) != [], stream: false, paginated: false
    )
    abort "#{op["operationId"]}: an operation needs a group" if group.empty?
    params.each do |p|
      where = p["in"]
      next if where == "header" && p["name"].downcase == IDEMPOTENCY_KEY_HEADER

      rb = case where
           when "header" then HEADER_KWARGS[p["name"].downcase] || rbname(p["name"].delete_prefix("x-"))
           else rbname(p["name"])
           end
      param = Param.new(name: p["name"], rb: rb, where: where, required: p["required"] == true)
      { "path" => o.path_params, "query" => o.query_params, "header" => o.header_params }.fetch(where) << param
    end
    order = path.scan(/\{(\w+)\}/).flatten
    o.path_params.sort_by! { |prm| order.index(prm.name) }
    abort "#{method} #{path}: path parameters do not match the template" if o.path_params.map(&:name) != order

    if (body = op["requestBody"])
      media, content = body.fetch("content").first
      abort "#{op["operationId"]}: no way to send #{media}" unless BODY_MEDIA.include?(media)

      resolved = resolve(spec, content.fetch("schema"))
      if media == "multipart/form-data"
        o.files = resolved.fetch("properties").select { |_, p| resolve(spec, p)["format"] == "binary" }.keys
      end
      o.body = true
      o.body_required = body["required"] == true || !resolved.fetch("required", []).empty? ||
                        types_of(resolved).include?("array")
      o.body_omit_when_none = body["required"] == false
    end

    success = op["responses"].select { |code, _| code.start_with?("2") }.sort
    if success.any? { |_, r| r.fetch("content", {}).key?("text/event-stream") }
      o.stream = true
    else
      names = o.query_params.map(&:name)
      json = success.filter_map { |_, r| r.dig("content", "application/json", "schema") }
      if names.include?("after") && names.include?("before") && json.size == 1
        page = resolve(spec, json.first)
        props = page.fetch("properties", {})
        items = resolve(spec, props.dig("data", "items") || {})
        o.paginated = props.key?("has_more") && has_id?(spec, items)
      end
    end
    o
  end
end

def class_name(resource)
  resource.split(".").map { |part| pascal(part) }.join
end

def comment(text, indent)
  lines = []
  text.strip.split(/\n{2,}/).each_with_index do |para, i|
    lines << "#{indent}#" unless i.zero?
    words = para.split(/\s+/)
    line = +""
    words.each do |word|
      if !line.empty? && indent.length + 2 + line.length + 1 + word.length > WIDTH
        lines << "#{indent}# #{line}"
        line = +""
      end
      line << " " unless line.empty?
      line << word
    end
    lines << "#{indent}# #{line}" unless line.empty?
  end
  lines
end

def path_expr(op)
  expr = op.path.dup
  op.path_params.each { |p| expr = expr.sub("{#{p.name}}", "\#{Client.encode_path(#{p.rb})}") }
  "\"#{expr}\""
end

def signature(op, paginator: false)
  args = op.path_params.map(&:rb)
  if op.body && !paginator
    args << (op.body_required ? "params" : "params = nil")
  end
  op.query_params.each { |p| args << (p.required ? "#{p.rb}:" : "#{p.rb}: nil") }
  op.header_params.each { |p| args << (p.required ? "#{p.rb}:" : "#{p.rb}: nil") }
  args << "idempotency_key: nil" if op.idempotency_key
  args << "max_reconnects: 5" if op.stream
  args << "extra_headers: nil" << "timeout: nil"
  args
end

# A def line, its parameters one a line when it would be longer than WIDTH.
def def_lines(indent, name, params)
  line = "#{indent}def #{name}(#{params.join(", ")})"
  return [line] if line.length <= WIDTH

  ["#{indent}def #{name}(", *params.map { |p| "#{indent}  #{p}," }.tap { |l| l[-1] = l[-1].delete_suffix(",") },
   "#{indent})"]
end

# A hash argument (`label: { ... }`), its pairs one a line when it would be longer than WIDTH.
def hash_arg(label, pairs, indent)
  entries = pairs.map { |k, v| "#{k.inspect} => #{v}" }
  line = "#{label}: { #{entries.join(", ")} }"
  return line if indent.length + line.length + 1 <= WIDTH

  "#{label}: {\n#{entries.map { |e| "#{indent}  #{e}" }.join(",\n")}\n#{indent}}"
end

def call_args(op, indent, after: nil, before: nil)
  query = op.query_params.reject { |p| op.stream && p.name == "last_event_id" }.map do |p|
    value = p.rb
    value = after if after && p.name == "after"
    value = before if before && p.name == "before"
    [p.name, value]
  end
  out = []
  out << hash_arg("query", query, indent) unless query.empty?
  out << hash_arg("headers", op.header_params.map { |p| [p.name, p.rb] }, indent) unless op.header_params.empty?
  out
end

def method_lines(op)
  doc = op.summary.empty? ? "" : "#{op.summary.sub(/\.\z/, "")}."
  doc += "\n\n#{op.description}" unless op.description.empty?
  if op.idempotency_key
    doc += "\n\nSent with an Idempotency-Key: +idempotency_key+ when given, else one made up for this " \
           "call, so that its retries never send twice."
  end
  doc += "\n\n+#{op.method} #{op.path}+"
  lines = comment(doc, "      ")
  lines << "      #"
  lines << (op.stream ? "      # @return [BillionSend::EventStream]" : "      # @return [Hash] the parsed JSON answer")
  lines.concat(def_lines("      ", op.name, signature(op)))
  if op.stream
    last = op.query_params.find { |p| p.name == "last_event_id" }
    call = [path_expr(op), *call_args(op, "          ")]
    call << "last_event_id: #{last ? last.rb : "nil"}"
    call += ["max_reconnects: max_reconnects", "extra_headers: extra_headers", "timeout: timeout"]
    lines << "        @client.stream_events("
    lines += call.map { |c| "          #{c}," }
    lines[-1] = lines[-1].delete_suffix(",")
    lines << "        )"
  else
    call = [op.method.inspect, path_expr(op), *call_args(op, "          ")]
    if op.files
      call << "form: params" << "files: %w[#{op.files.join(" ")}]"
    elsif op.body
      call << (op.body_required || op.body_omit_when_none ? "body: params" : "body: params.nil? ? {} : params")
    end
    call += ["idempotency_key: idempotency_key", "auto_idempotency_key: true"] if op.idempotency_key
    call << "auth: false" unless op.auth
    call += ["extra_headers: extra_headers", "timeout: timeout"]
    lines << "        @client.request("
    lines += call.map { |c| "          #{c}," }
    lines[-1] = lines[-1].delete_suffix(",")
    lines << "        )"
  end
  lines << "      end"
  lines
end

def paginator_lines(op)
  sig = signature(op, paginator: true)
  lines = comment("Every item of +#{op.name}+, as an Enumerator that fetches pages as it goes. Walks in the " \
                  "list's own order, from +after+ (or the first page) on; pass +before+ instead to walk " \
                  "the other way.", "      ")
  lines << "      #"
  lines << "      # @return [Enumerator<Hash>]"
  lines.concat(def_lines("      ", "#{op.name}_all", sig))
  after = op.query_params.find { |p| p.name == "after" }.rb
  before = op.query_params.find { |p| p.name == "before" }.rb
  lines << "        Pagination.each_item(after: #{after}, before: #{before}) do |page_after, page_before|"
  call = [op.method.inspect, path_expr(op),
          *call_args(op, "            ", after: "page_after", before: "page_before"),
          "extra_headers: extra_headers", "timeout: timeout"]
  lines << "          @client.request("
  lines += call.map { |c| "            #{c}," }
  lines[-1] = lines[-1].delete_suffix(",")
  lines << "          )"
  lines << "        end"
  lines << "      end"
  lines
end

def render(ops)
  by_resource = Hash.new { |h, k| h[k] = [] }
  ops.each { |op| by_resource[op.resource] << op }
  by_resource.keys.each do |resource|
    parts = resource.split(".")
    (1...parts.size).each { |i| by_resource[parts[0, i].join(".")] }
  end
  resources = by_resource.keys.sort
  lines = [
    "# frozen_string_literal: true",
    "",
    "# Generated by script/generate.rb from openapi/api.openapi.json. Do not edit.",
    "",
    "module BillionSend",
    "  # The API's operations, one class per group of its operationIds.",
    "  module Resources",
    "    # Shared by every resource: holds the client the requests go through.",
    "    class Base",
    "      def initialize(client)",
    "        @client = client",
    "      end",
    "",
    "      def inspect",
    "        \"#<\#{self.class.name}>\"",
    "      end",
    "    end"
  ]
  resources.each do |resource|
    children = resources.select { |r| r.include?(".") && r.rpartition(".").first == resource }
    methods = by_resource[resource]
    names = methods.map(&:name) + methods.select(&:paginated).map { |o| "#{o.name}_all" }
    children.each do |child|
      attr = child.rpartition(".").last
      abort "#{resource}: #{attr} is both a resource and an operation" if names.include?(attr)
    end
    abort "#{resource}: two methods share a name" if names.uniq.size != names.size
    lines << ""
    lines << "    # Operations on #{resource.tr("._", "  ")}."
    lines << "    class #{class_name(resource)} < Base"
    blocks = children.map do |child|
      attr = child.rpartition(".").last
      ["      # @return [#{class_name(child)}]",
       "      def #{attr}",
       "        @#{attr} ||= #{class_name(child)}.new(@client)",
       "      end"]
    end
    methods.each do |op|
      blocks << method_lines(op)
      blocks << paginator_lines(op) if op.paginated
    end
    blocks.each_with_index do |block, i|
      lines << "" unless i.zero?
      lines.concat(block)
    end
    lines << "    end"
  end
  lines << ""
  lines << "    # The top-level resources, included into BillionSend::Client."
  lines << "    module Root"
  top = resources.reject { |r| r.include?(".") }
  top.each_with_index do |resource, i|
    lines << "" unless i.zero?
    lines << "      # @return [Resources::#{class_name(resource)}]"
    lines << "      def #{resource}"
    lines << "        @#{resource} ||= #{class_name(resource)}.new(self)"
    lines << "      end"
  end
  lines << "    end"
  lines << "  end"
  lines << "end"
  "#{lines.join("\n")}\n"
end

spec = JSON.parse(File.read(SNAPSHOT))
text = render(build_operations(spec))
if ARGV.include?("--check")
  if File.exist?(OUT) && File.read(OUT) == text
    puts "generated file matches the snapshot"
  else
    warn "lib/billionsend/resources.rb is stale: run `ruby script/generate.rb`"
    exit 1
  end
else
  File.write(OUT, text)
  puts "wrote lib/billionsend/resources.rb"
end
