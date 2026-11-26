# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include ClientHelpers

  def with_env(values)
    saved = values.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_reads_the_key_and_base_url_from_the_environment
    with_env("BILLIONSEND_API_KEY" => "bs_env", "BILLIONSEND_BASE_URL" => "https://api.example.test/") do
      c = BillionSend::Client.new
      assert_equal "bs_env", c.api_key
      assert_equal "https://api.example.test", c.base_url
    end
  end

  def test_defaults_to_the_public_api
    with_env("BILLIONSEND_API_KEY" => nil, "BILLIONSEND_BASE_URL" => nil) do
      c = BillionSend::Client.new(api_key: "bs_x")
      assert_equal "https://api.billionsend.com", c.base_url
      assert_equal 60, c.timeout
      assert_equal 2, c.max_retries
    end
  end

  def test_a_request_without_a_key_fails_before_sending
    with_env("BILLIONSEND_API_KEY" => nil) do
      c = BillionSend::Client.new(base_url: Contract::BASE_URL, transport: mock)
      error = assert_raises(BillionSend::AuthenticationError) { c.domains.list }
      assert_equal "missing_api_key", error.name
      assert_nil error.status_code
      assert_empty mock.calls
    end
  end

  def test_agent_signup_goes_without_a_key
    with_env("BILLIONSEND_API_KEY" => nil) do
      c = BillionSend::Client.new(base_url: Contract::BASE_URL, transport: mock)
      c.agent.signup({ "human_email" => "owner@example.com", "name" => "Support agent" })
      assert_nil mock.calls.last.header("authorization")
    end
  end

  def test_negative_max_retries_is_refused
    assert_raises(ArgumentError) { BillionSend::Client.new(api_key: "k", max_retries: -1) }
  end

  def test_headers_user_agent_and_overrides
    c = client(default_headers: { "x-team-tag" => "a" })
    c.domains.list(extra_headers: { "X-Team-Tag" => "b" })
    call = mock.calls.last
    assert_equal "billionsend-ruby/#{BillionSend::VERSION}", call.header("user-agent")
    assert_equal "application/json", call.header("accept")
    assert_equal ["b"], call.request.headers.select { |k, _| k.casecmp?("x-team-tag") }.values
  end

  def test_path_segments_are_encoded_and_addresses_keep_their_at
    client.inboxes.get("support@example.com")
    assert_equal "#{Contract::BASE_URL}/inboxes/support@example.com", mock.calls.last.request.url
    assert_equal "a%2Fb%20c", BillionSend::Client.encode_path("a/b c")
  end

  def test_query_lists_and_booleans
    client.emails.metrics.call(metrics: %w[sent delivered])
    assert_equal({ "metrics" => ["sent,delivered"] }, mock.calls.last.query)
    client.emails.receiving.list(unread: true, limit: 5)
    assert_equal({ "unread" => ["true"], "limit" => ["5"] }, mock.calls.last.query)
  end

  def test_answers_are_hashes_with_string_keys
    mock.respond("GET", "/domains/{id}", json: Contract.example(Contract.operation("GET", "/domains/{id}").success[2]))
    domain = client.domains.get(ID)
    assert_kind_of Hash, domain
    assert domain.keys.all?(String)
  end

  def test_a_body_with_symbol_keys_is_sent_as_json
    client.emails.send({ from: "Acme <hello@acme.com>", to: ["user@example.com"], subject: "Hi", text: "Hello" })
    assert_equal "Hi", mock.calls.last.body["subject"]
  end

  def test_the_caller_idempotency_key_is_sent
    client.emails.send({ from: "a@acme.com", to: ["b@example.com"], subject: "s", text: "t" }, idempotency_key: "order-1")
    assert_equal "order-1", mock.calls.last.header("idempotency-key")
  end

  def test_the_key_is_trimmed_and_a_blank_one_counts_as_none
    assert_equal "bs_x", BillionSend::Client.new(api_key: " bs_x\n").api_key
    with_env("BILLIONSEND_API_KEY" => "bs_env\n") do
      assert_equal "bs_env", BillionSend::Client.new(api_key: "  ").api_key
    end
    with_env("BILLIONSEND_API_KEY" => " \n") do
      assert_nil BillionSend::Client.new.api_key
    end
  end

  def test_a_key_with_a_control_character_is_refused_without_showing_it
    error = assert_raises(ArgumentError) { BillionSend::Client.new(api_key: "bs_a\nb") }
    refute_includes error.message, "bs_a"
  end

  def test_a_header_http_cannot_carry_fails_before_sending
    message = { from: "a@acme.com", to: ["b@example.com"], subject: "s", text: "t" }
    ["welcome/订单-1", "a\r\nX-Evil: 1", "\xff"].each do |key|
      error = assert_raises(BillionSend::Error) { client.emails.send(message, idempotency_key: key) }
      assert_equal "invalid_header", error.name
      assert_match(/Idempotency-Key/, error.message)
      refute_includes error.message.b, "welcome"
    end
    assert_raises(BillionSend::Error) { client(default_headers: { "x-tag" => "é" }).domains.list }
    assert_empty mock.calls
    assert_empty sleeps
  end

  def test_an_empty_or_dot_path_parameter_is_refused_before_sending
    [nil, "", ".", ".."].each do |id|
      assert_raises(ArgumentError) { client.emails.get(id) }
      assert_raises(ArgumentError) { client.webhooks.events.get(ID, id) }
    end
    assert_empty mock.calls
    assert_equal "...", BillionSend::Client.encode_path("...")
  end

  def test_an_empty_list_is_left_out_of_the_query
    client.emails.metrics.call(metrics: ["sent"], domain_id: [])
    assert_equal({ "metrics" => ["sent"] }, mock.calls.last.query)
  end

  def test_a_success_without_a_body_is_nil
    ["", " \n"].each do |body|
      mock.respond("DELETE", "/domains/{id}", 200, body: body)
      assert_nil client.domains.delete(ID)
    end
  end

  def test_a_non_json_success_raises
    mock.respond("GET", "/domains", body: "<html>", headers: { "content-type" => "text/html" })
    error = assert_raises(BillionSend::Error) { client.domains.list }
    assert_match(/Expected a JSON answer, got text\/html/, error.message)
  end
end
