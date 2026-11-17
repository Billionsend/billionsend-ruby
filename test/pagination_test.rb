# frozen_string_literal: true

require "test_helper"

class PaginationTest < Minitest::Test
  include ClientHelpers

  def page(ids, more)
    item = Contract.example(Contract.operation("GET", "/contacts").success[2])["data"].first
    { "object" => "list", "has_more" => more, "data" => ids.map { |id| item.merge("id" => id) } }
  end

  def test_walks_every_page_forward_by_the_last_id
    first = "00000000-0000-4000-8000-000000000001"
    second = "00000000-0000-4000-8000-000000000002"
    third = "00000000-0000-4000-8000-000000000003"
    mock.respond("GET", "/contacts", json: page([first, second], true))
    mock.respond("GET", "/contacts", json: page([third], false))
    ids = client.contacts.list_all(limit: 2).map { |c| c["id"] }
    assert_equal [first, second, third], ids
    assert_equal [{ "limit" => ["2"] }, { "limit" => ["2"], "after" => [second] }], mock.calls.map(&:query)
  end

  def test_walks_backward_from_before_by_the_first_id
    first = "00000000-0000-4000-8000-000000000001"
    second = "00000000-0000-4000-8000-000000000002"
    mock.respond("GET", "/contacts", json: page([first, second], true))
    mock.respond("GET", "/contacts", json: page([], true))
    ids = client.contacts.list_all(before: "00000000-0000-4000-8000-000000000009").to_a.map { |c| c["id"] }
    assert_equal [first, second], ids
    assert_equal [first], mock.calls.last.query["before"]
  end

  def test_is_lazy
    mock.respond("GET", "/contacts", json: page(["00000000-0000-4000-8000-000000000001"], true))
    enum = client.contacts.list_all
    assert_empty mock.calls
    enum.first
    assert_equal 1, mock.calls.size
  end
end
