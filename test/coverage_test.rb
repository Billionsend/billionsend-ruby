# frozen_string_literal: true

require "test_helper"

# Every operation of the snapshot is reachable through the SDK, and nothing else is.
#
# Each operation is called through the contract mock by the method its
# operationId names (snake_case; an operationId that is also the group of
# others is that group's `call`), with its path parameters, an instance of its
# body schema and its required query and header parameters. The operations hit
# are compared with the snapshot, and the public methods of the resources with
# the operations: an operation the SDK does not reach, or a method that is not
# an operation, fails.
class CoverageTest < Minitest::Test
  include ClientHelpers

  IDS = Contract::OPERATIONS.map { |op| op.spec["operationId"] }
  GROUPS = IDS.flat_map { |id| parts = id.split("."); (1...parts.size).map { |i| parts[0, i].join(".") } }.to_set

  def self.snake(text) = text.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase

  # The method chain of an operation: ["emails", "receiving", "attachments", "list"].
  def self.chain(op)
    id = op.spec["operationId"]
    parts = id.split(".").map { |p| snake(p) }
    GROUPS.include?(id) ? parts + ["call"] : parts
  end

  def kwarg(param)
    name = param["name"].delete_prefix("x-")
    name = "batch_validation" if param["name"] == "x-batch-validation"
    self.class.snake(name).tr("-", "_").to_sym
  end

  def invoke(c, op)
    *path, name = self.class.chain(op)
    target = path.reduce(c) { |obj, attr| obj.public_send(attr) }
    args = op.params("path").sort_by { |p| op.path.index("{#{p["name"]}}") }
                            .map { |p| Contract.example(p.fetch("schema", {})).to_s }
    _, schema = op.request_body
    args << Contract.example(schema, full: false) if schema
    kwargs = (op.params("query") + op.params("header")).select { |p| p["required"] }
                                                       .to_h { |p| [kwarg(p), Contract.example(p["schema"])] }
    result = target.public_send(name, *args, **kwargs)
    result.close if result.is_a?(BillionSend::EventStream)
    result
  end

  def test_every_operation_is_reached_and_answers_its_schema
    c = client
    Contract::OPERATIONS.each { |op| invoke(c, op) }
    assert_equal Contract::OPERATION_KEYS, mock.keys.to_set
    assert_equal 193, Contract::OPERATIONS.size
  end

  def test_every_public_resource_method_is_an_operation
    expected = Contract::OPERATIONS.map { |op| self.class.chain(op).join(".") }.to_set
    found = Set.new
    walk = lambda do |obj, prefix|
      obj.class.public_instance_methods(false).each do |m|
        if m.end_with?("_all")
          base = m.to_s.delete_suffix("_all")
          assert_includes expected, (prefix + [base]).join("."), "#{m} pages an operation"
          next
        end
        if obj.method(m).arity.zero? && obj.public_send(m).is_a?(BillionSend::Resources::Base)
          walk.call(obj.public_send(m), prefix + [m.to_s])
        else
          found << (prefix + [m.to_s]).join(".")
        end
      end
    end
    root = client
    BillionSend::Resources::Root.public_instance_methods(false).each do |m|
      walk.call(root.public_send(m), [m.to_s])
    end
    assert_equal expected, found
  end

  def test_sending_operations_always_carry_an_idempotency_key
    keyed = Contract::OPERATIONS.select(&:idempotency_key?)
    assert_equal 9, keyed.size
    c = client
    keyed.each { |op| invoke(c, op) }
    keys = mock.calls.map { |call| call.header("idempotency-key") }
    assert(keys.all? { |k| k.match?(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/) }, keys.inspect)
    assert_equal keys.size, keys.uniq.size
  end
end
