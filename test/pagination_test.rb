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

  def test_a_page_without_a_data_array_raises
    [{ "object" => "list", "has_more" => false }, { "object" => "list", "data" => nil, "has_more" => false },
     { "object" => "list", "data" => {}, "has_more" => false }, [1, 2]].each do |answer|
      m = Contract::Mock.new
      m.respond("GET", "/contacts", body: JSON.generate(answer), headers: { "content-type" => "application/json" })
      c = BillionSend::Client.new(api_key: Contract::API_KEY, base_url: Contract::BASE_URL, transport: m)
      error = assert_raises(BillionSend::Error) { c.contacts.list_all.to_a }
      assert_equal "The list page has no data array", error.message
      assert_equal "application_error", error.name
      assert_nil error.status_code
    end
  end

  def test_a_page_whose_last_item_has_no_id_hands_out_its_items_then_raises
    page = page(["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"], true)
    page["data"].last.delete("id")
    mock.respond("GET", "/contacts", body: JSON.generate(page), headers: { "content-type" => "application/json" })
    got = []
    error = assert_raises(BillionSend::Error) { client.contacts.list_all.each { |c| got << c } }
    assert_equal "The last item of the list page has no id to continue from", error.message
    assert_equal 2, got.size
    assert_equal 1, mock.calls.size
  end
end
