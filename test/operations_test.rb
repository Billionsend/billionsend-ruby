# frozen_string_literal: true

require "test_helper"

# Each operation added after 0.1.0, called with its arguments: the path (so
# path parameters are in order), the query and the body that reach the API.
# The contract mock checks every request and answer against the snapshot.
class OperationsTest < Minitest::Test
  include ClientHelpers

  A = ClientHelpers::ID
  B = ClientHelpers::ID2
  SCHEMA = { "schema" => { "plan" => "string" } }.freeze

  # [method chain, arguments, keywords, HTTP method, path, query, body]
  CASES = [
    ["api_keys.update", [A, { "name" => "ci" }], {}, "PATCH", "/api-keys/#{A}", {}, { "name" => "ci" }],
    ["automations.create", [{ "name" => "Welcome" }], {}, "POST", "/automations", {}, { "name" => "Welcome" }],
    ["automations.list", [], { status: "enabled", limit: 5 }, "GET", "/automations",
     { "status" => ["enabled"], "limit" => ["5"] }, nil],
    ["automations.get", [A], {}, "GET", "/automations/#{A}", {}, nil],
    ["automations.update", [A, { "name" => "New" }], {}, "PATCH", "/automations/#{A}", {}, { "name" => "New" }],
    ["automations.remove", [A], {}, "DELETE", "/automations/#{A}", {}, nil],
    ["automations.duplicate", [A], {}, "POST", "/automations/#{A}/duplicate", {}, nil],
    ["automations.stop", [A], {}, "POST", "/automations/#{A}/stop", {}, nil],
    ["automations.stop", [A, { "cancel_runs" => true }], {}, "POST", "/automations/#{A}/stop", {},
     { "cancel_runs" => true }],
    ["automations.validate", [{ "steps" => [], "connections" => [] }], {}, "POST", "/automations/validate", {},
     { "steps" => [], "connections" => [] }],
    ["automations.simulate", [A, { "contact" => {} }], {}, "POST", "/automations/#{A}/simulate", {},
     { "contact" => {} }],
    ["automations.metrics", [A], { start_date: "2026-11-01", end_date: "2026-11-02" }, "GET",
     "/automations/#{A}/metrics", { "start_date" => ["2026-11-01"], "end_date" => ["2026-11-02"] }, nil],
    ["automations.runs.list", [A], { status: "running" }, "GET", "/automations/#{A}/runs",
     { "status" => ["running"] }, nil],
    ["automations.runs.get", [A, B], {}, "GET", "/automations/#{A}/runs/#{B}", {}, nil],
    ["automations.runs.cancel", [A, B], {}, "POST", "/automations/#{A}/runs/#{B}/cancel", {}, nil],
    ["brand.get", [], {}, "GET", "/brand", {}, nil],
    ["brand.update", [{ "accent_color" => nil, "font" => "serif" }], {}, "PATCH", "/brand", {},
     { "accent_color" => nil, "font" => "serif" }],
    ["brand.update", [], {}, "PATCH", "/brand", {}, nil],
    ["brand.logo.delete", [], {}, "DELETE", "/brand/logo", {}, nil],
    ["broadcast_groups.create", [{ "name" => "Launch", "domain_ids" => [A, B], "from_local_part" => "news",
                                   "subject" => "Hello", "html" => "<p>Hi</p>" }], {}, "POST",
     "/broadcast-groups", {},
     { "name" => "Launch", "domain_ids" => [A, B], "from_local_part" => "news", "subject" => "Hello",
       "html" => "<p>Hi</p>" }],
    ["broadcast_groups.list", [], { limit: 2 }, "GET", "/broadcast-groups", { "limit" => ["2"] }, nil],
    ["broadcast_groups.get", [A], {}, "GET", "/broadcast-groups/#{A}", {}, nil],
    ["broadcast_groups.update", [A, { "name" => "Launch 2" }], {}, "PATCH", "/broadcast-groups/#{A}", {},
     { "name" => "Launch 2" }],
    ["broadcast_groups.remove", [A], {}, "DELETE", "/broadcast-groups/#{A}", {}, nil],
    ["broadcast_groups.send", [A], {}, "POST", "/broadcast-groups/#{A}/send", {}, nil],
    ["broadcast_groups.send", [A, { "scheduled_at" => "in 1 hour" }], {}, "POST", "/broadcast-groups/#{A}/send", {},
     { "scheduled_at" => "in 1 hour" }],
    ["broadcast_groups.cancel", [A], {}, "POST", "/broadcast-groups/#{A}/cancel", {}, nil],
    ["broadcasts.clicked_links", [A], { limit: 3 }, "GET", "/broadcasts/#{A}/clicked-links",
     { "limit" => ["3"] }, nil],
    ["broadcasts.recipients", [A], { type: "bounced", bounce_type: "permanent", email: "a@example.com" }, "GET",
     "/broadcasts/#{A}/recipients",
     { "type" => ["bounced"], "bounce_type" => ["permanent"], "email" => ["a@example.com"] }, nil],
    ["contacts.imports.list", [], { status: "queued" }, "GET", "/contacts/imports", { "status" => ["queued"] }, nil],
    ["contacts.imports.get", [A], {}, "GET", "/contacts/imports/#{A}", {}, nil],
    ["contacts.segments.list", ["a@example.com"], {}, "GET", "/contacts/a@example.com/segments", {}, nil],
    ["contacts.topics.list", ["a@example.com"], { limit: 2 }, "GET", "/contacts/a@example.com/topics",
     { "limit" => ["2"] }, nil],
    ["domains.claims.create", [{ "name" => "acme.dev" }], {}, "POST", "/domains/claim", {}, { "name" => "acme.dev" }],
    ["domains.claims.get", [A], {}, "GET", "/domains/#{A}/claim", {}, nil],
    ["domains.claims.verify", [A], {}, "POST", "/domains/#{A}/claim/verify", {}, nil],
    ["domains.unsubscribe_page.logo.delete", [A], {}, "DELETE", "/domains/#{A}/unsubscribe-page/logo", {}, nil],
    ["emails.attachments.list", [A], {}, "GET", "/emails/#{A}/attachments", {}, nil],
    ["emails.attachments.get", [A, B], {}, "GET", "/emails/#{A}/attachments/#{B}", {}, nil],
    ["emails.share", [A], {}, "POST", "/emails/#{A}/share", {}, nil],
    ["emails.share", [A, { "expires_in" => "2 hours" }], {}, "POST", "/emails/#{A}/share", {},
     { "expires_in" => "2 hours" }],
    ["emails.unshare", [A], {}, "DELETE", "/emails/#{A}/share", {}, nil],
    ["events.create", [{ "name" => "signed_up" }], {}, "POST", "/events", {}, { "name" => "signed_up" }],
    ["events.list", [], { limit: 2 }, "GET", "/events", { "limit" => ["2"] }, nil],
    ["events.get", ["signed up"], {}, "GET", "/events/signed%20up", {}, nil],
    ["events.update", ["signed_up", SCHEMA], {}, "PATCH", "/events/signed_up", {}, SCHEMA],
    ["events.remove", ["signed_up"], {}, "DELETE", "/events/signed_up", {}, nil],
    ["events.send", [{ "event" => "signed_up", "email" => "a@example.com" }], {}, "POST", "/events/send", {},
     { "event" => "signed_up", "email" => "a@example.com" }],
    ["inboxes.agent.update", ["support@example.com", {}], {}, "PATCH", "/inboxes/support@example.com/agent", {}, {}],
    ["logs.list", [], {}, "GET", "/logs", {}, nil],
    ["logs.get", [A], {}, "GET", "/logs/#{A}", {}, nil],
    ["oauth_grants.list", [], {}, "GET", "/oauth/grants", {}, nil],
    ["oauth_grants.revoke", ["grant_1"], {}, "DELETE", "/oauth/grants/grant_1", {}, nil],
    ["webhooks.events.list", [A], {}, "GET", "/webhooks/#{A}/events", {}, nil],
    ["webhooks.events.get", [A, B], {}, "GET", "/webhooks/#{A}/events/#{B}", {}, nil],
    ["webhooks.events.replay", [A, B], {}, "POST", "/webhooks/#{A}/events/#{B}/replay", {}, nil],
    ["webhooks.events.attempts.list", [A, B], {}, "GET", "/webhooks/#{A}/events/#{B}/attempts", {}, nil],
    ["webhooks.rotate_signing_secret", [A], {}, "POST", "/webhooks/#{A}/signing-secret/rotate", {}, nil],
    ["webhooks.rotate_signing_secret", [A, { "overlap_hours" => 0 }], {}, "POST",
     "/webhooks/#{A}/signing-secret/rotate", {}, { "overlap_hours" => 0 }],
    ["suppressions.list", [], { kind: "domain" }, "GET", "/suppressions", { "kind" => ["domain"] }, nil]
  ].freeze

  CASES.each_with_index do |(chain, args, kwargs, method, path, query, body), index|
    define_method("test_#{chain.tr(".", "_")}_#{index}") do
      *resources, name = chain.split(".")
      target = resources.reduce(client) { |obj, attr| obj.public_send(attr) }
      answer = target.public_send(name, *args, **kwargs)
      call = mock.calls.fetch(0)
      assert_equal method, call.request.method
      assert_equal "#{Contract::BASE_URL}#{path}", call.request.url.split("?").first
      assert_equal query, call.query
      body.nil? ? assert_nil(call.body) : assert_equal(body, call.body)
      assert_kind_of Hash, answer
    end
  end

  def test_an_event_is_sent_once_under_one_idempotency_key
    mock.error("POST", "/events/send", 503, "unavailable", "Try later")
    client.events.send({ "event" => "signed_up", "email" => "a@example.com" })
    keys = mock.calls.map { |c| c.header("idempotency-key") }
    assert_equal 2, keys.size
    assert_equal 1, keys.uniq.size
    client.events.send({ "event" => "signed_up", "email" => "a@example.com" }, idempotency_key: "signup/1")
    assert_equal "signup/1", mock.calls.last.header("idempotency-key")
  end

  # [method chain of the enumerator, path arguments, keywords, path template]
  PAGED = [
    ["automations.list_all", [], {}, "/automations"],
    ["automations.runs.list_all", [A], {}, "/automations/{id}/runs"],
    ["broadcast_groups.list_all", [], {}, "/broadcast-groups"],
    ["broadcasts.recipients_all", [A], { type: "sent" }, "/broadcasts/{id}/recipients"],
    ["broadcasts.clicked_links_all", [A], {}, "/broadcasts/{id}/clicked-links"],
    ["contacts.imports.list_all", [], {}, "/contacts/imports"],
    ["contacts.segments.list_all", [A], {}, "/contacts/{id}/segments"],
    ["contacts.topics.list_all", [A], {}, "/contacts/{id}/topics"],
    ["emails.attachments.list_all", [A], {}, "/emails/{email_id}/attachments"],
    ["events.list_all", [], {}, "/events"],
    ["logs.list_all", [], {}, "/logs"],
    ["oauth_grants.list_all", [], {}, "/oauth/grants"],
    ["topics.list_all", [], {}, "/topics"],
    ["webhooks.events.list_all", [A], {}, "/webhooks/{id}/events"],
    ["webhooks.events.attempts.list_all", [A, B], {}, "/webhooks/{id}/events/{event_id}/attempts"]
  ].freeze

  PAGED.each do |chain, args, kwargs, template|
    define_method("test_#{chain.tr(".", "_")}_follows_the_cursor") do
      schema = Contract.operation("GET", template).success[2]
      first = Contract.example(schema).merge("has_more" => true)
      mock.respond("GET", template, json: first)
      mock.respond("GET", template, json: first.merge("has_more" => false))
      *resources, name = chain.split(".")
      target = resources.reduce(client) { |obj, attr| obj.public_send(attr) }
      assert_equal 2, target.public_send(name, *args, **kwargs).to_a.size
      assert_equal [first["data"].last["id"]], mock.calls.last.query["after"]
      kwargs.each { |key, value| assert_equal [value], mock.calls.last.query[key.to_s] }
    end
  end
end
