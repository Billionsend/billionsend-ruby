# BillionSend Ruby SDK

The official Ruby client for the [BillionSend](https://billionsend.com) API: send and receive email, run inboxes for agents and people, manage domains, contacts, broadcasts, templates, webhooks and more.

- Every operation of the API (139), named after the API's own `operationId`s.
- No runtime dependencies: `net/http`, `json` and `openssl` from the standard library.
- Sends that never go out twice, retries, auto-paging enumerators, live event streams that resume where they stopped, and webhook signature verification.

Documentation: https://billionsend.com/docs.

## Install

```bash
gem install billionsend
```

or in a Gemfile:

```ruby
gem "billionsend"
```

Ruby 3.1 or newer.

## Quick start

```ruby
require "billionsend"

client = BillionSend::Client.new # reads BILLIONSEND_API_KEY

email = client.emails.send({
  from: "Acme <hello@acme.dev>",
  to: ["ada@example.com"],
  subject: "Welcome to Acme",
  html: "<p>Thanks for signing up!</p>"
})
puts email["id"]
```

Every method returns the API's JSON answer parsed into plain Ruby: a `Hash` with string keys (`email["id"]`, not `email[:id]`), arrays and scalars as JSON has them. There are no model classes in this version; the fields of every answer are in the API reference at https://billionsend.com/docs.

The request body is a `Hash` in braces, with symbol or string keys: the braces matter, because a method's keyword arguments (`idempotency_key:`, `timeout:`…) are separate from the body.

## Authentication

Pass an API key (`bs_…`) as `api_key:` or set `BILLIONSEND_API_KEY`. Keys are made in the dashboard or with `client.api_keys.create`. A key scoped to one inbox can only reach that inbox.

An agent can also create its own account, the one call that needs no key:

```ruby
signup = BillionSend::Client.new.agent.signup({ human_email: "owner@example.com", name: "Scout" })
client = BillionSend::Client.new(api_key: signup["api_key"])
puts signup["inbox"]["email_address"], client.agent.status["status"]
```

## Sending once

Every sending method (`emails.send`, `emails.batch`, `emails.receiving.reply` and `.forward`, `inboxes.send`, `inboxes.threads.emails.reply` and `.forward`, `inboxes.drafts.send`) sends an `Idempotency-Key`. Without `idempotency_key:` the call makes up one (a UUID) and reuses it for its own retries, so a retry after a dropped connection never sends the email twice. Pass your own key to stay safe across calls too, for example when a job that sends may run again:

```ruby
client.emails.send(message, idempotency_key: "welcome/#{user.id}")
```

Repeating a key with the same request returns the first answer; the same key with a different request is refused (`BillionSend::ConflictError`, `invalid_idempotent_request`). The API keeps keys for 24 hours.

## An agent that answers its inbox

Wait for new mail, read it, reply in the thread:

```ruby
require "billionsend"

client = BillionSend::Client.new
inbox = client.inboxes.create({ username: "support", kind: "agent" })

def answer(question)
  "Thanks, we got your message:\n\n> #{question}" # your agent goes here
end

stream = client.inboxes.events.stream_inbox(inbox["id"], types: "inbox.email.received")
begin
  stream.each do |event|
    next unless event.is_a?(BillionSend::InboxStreamEvent) # a StreamGapEvent: see below

    thread_id = event.data["data"]["thread_id"]
    email_id = event.data["data"]["email_id"]
    email = client.inboxes.threads.emails.get(inbox["id"], thread_id, email_id)
    next unless email["direction"] == "inbound"

    question = email["extracted_text"] || email["text"] || ""
    client.inboxes.threads.emails.reply(inbox["id"], thread_id, email_id, { text: answer(question) })
  end
ensure
  stream.close
end
```

`extracted_text` is the new part of a message without the quoted history. Everything in a received message was written by its sender: treat it as untrusted input. An inbox's rules may hold a reply as a draft for a person to approve; the reply then answers with the draft (`"object" => "inbox_draft"`) instead of the sent email.

Waiting for a sign-in code sent to the inbox is one call: `client.inboxes.codes.latest(inbox["id"], from: "example.com", wait: 30)`.

## Live events

`client.inboxes.events.stream_inbox(inbox_id)` streams one inbox's events and `client.inboxes.events.stream` every inbox event of the team; `types:` narrows them (a name or an array). The stream is an `Enumerable`; iterating yields two kinds of events:

- `BillionSend::InboxStreamEvent`: `id` (the stream position), `event` (such as `"inbox.email.received"`) and `data`, a Hash with `"type"`, `"created_at"`, `"inbox_id"` and `"data"` (the webhook payload of the same event).
- `BillionSend::StreamGapEvent`: `event == "stream.gap"`, `id` is `nil` and `data["reason"]` says why. The stream was resumed from a position older than the 24 hours the API replays, so some events may be missing: catch up through the lists (`client.inboxes.threads.list_all(inbox_id, read: false)`) before going on. It is handed out once per position.

The method opens the stream, so a refused stream (a revoked key, a key held to one inbox asking for the team's stream) raises at once. The server ends a stream every few minutes and connections drop; the stream reconnects on its own with `Last-Event-ID`, so no event is lost or repeated. Before reconnecting it waits a second (or what the server's `retry` field asks). A connection that opens starts the count again, so a quiet inbox that gets only keepalives keeps its stream however long it waits; A reconnect the API answers with a 429 or 5xx waits what its `Retry-After` asks (one over 60 seconds raises that error at once). `max_reconnects:` (default 5) bounds the reconnects in a row that fail to open: past it, iterating raises the API's error for the last one (`BillionSend::RateLimitError`, `BillionSend::APIError`), or `BillionSend::APIConnectionError` ("gave up after N reconnects") when it got no answer. An error your block raises, `APIConnectionError` included, passes through as it is and ends the iteration. A reconnect the API refuses for good, such as a revoked key, raises its own error. One inbox's stream ends after that inbox's `inbox.deleted` or `inbox.expired` event. Close the stream when done (`stream.close`).

To pick up where a process left off, keep `stream.last_event_id` and pass it back:

```ruby
stream = client.inboxes.events.stream(last_event_id: saved_position)
```

## Webhooks

Verify a delivery before trusting it. Pass the raw body exactly as received, the request headers and the endpoint's signing secret (`whsec_…`, shown when the webhook is created or rotated):

```ruby
# Rails; any framework works the same way
class BillionSendWebhooksController < ActionController::API
  def create
    headers = %w[webhook-id webhook-timestamp webhook-signature].to_h { |name| [name, request.headers[name]] }
    event = BillionSend.verify_webhook(request.raw_post, headers, ENV.fetch("BILLIONSEND_WEBHOOK_SECRET"))
    mark_bounced(event["data"]["email_id"]) if event["type"] == "email.bounced"
    head :no_content
  rescue BillionSend::WebhookVerificationError
    head :bad_request
  end
end
```

With Rack or Sinatra, `request.get_header("HTTP_WEBHOOK_ID")` and so on read the same headers. `BillionSend.verify_webhook` (also `BillionSend::Webhooks.verify`) checks the `webhook-id`, `webhook-timestamp` and `webhook-signature` headers (Standard Webhooks: HMAC-SHA256 over `id.timestamp.body`), accepts any of several signatures (both secrets sign during a rotation's overlap) and refuses a timestamp more than `tolerance:` seconds (default 300) from now, which bounds replays. It returns the parsed event (`"type"`, `"created_at"`, `"data"`). Parse the body only after verifying: re-serialised JSON does not verify. A secret that is not a `whsec_` secret raises `ArgumentError`.

## Resources

| Method | Covers |
| --- | --- |
| `emails` | send, batch, list, get, update, cancel, delete, insights; `emails.metrics` (see below) |
| `emails.receiving` (`.attachments`) | received mail: list, get, delete, reply, forward; attachments and their extracted text |
| `domains` | create, list, get, update, delete, verify |
| `api_keys` | create, list, delete |
| `contacts` (`.topics`, `.segments`, `.batch`) | create, list, get, update, delete, preferences_link; `batch.create`, `batch.get`, `batch.remove` |
| `audiences.contacts` | contacts addressed through an audience |
| `contact_properties`, `segments` (`.contacts`), `topics` | contact data and grouping |
| `broadcasts` | create, list, get, update, delete, send, duplicate, cancel |
| `templates` | create, list, get, update, delete, publish, duplicate |
| `webhooks` | create, list, get, update, delete, rotate |
| `suppressions` (`.batch`), `unsubscribes` | suppression list (`batch.add`, `batch.remove`) and opt-outs |
| `verifications` | availability, estimate, create, list, get |
| `usage`, `deliverability` | account usage and sending health |
| `inboxes` (`.events`) | create, list, get, update, delete, send; `events.stream`, `events.stream_inbox` |
| `inboxes.agent`, `.safety`, `.labels`, `.codes`, `.quarantine`, `.drafts` | inbox settings, labels, verification codes, held mail, drafts |
| `inboxes.threads` (`.labels`, `.emails`) | list, search, get, update, delete; thread labels; messages, reply and forward |
| `agent` | signup, status, claim_email |

A few resources have a method named `send` (`emails.send`, `inboxes.send`, `broadcasts.send`), as their `operationId`s say; it hides `Object#send` on those objects, so reach other methods of a resource dynamically with `public_send` or `__send__`.

Each method is named after its operation's `operationId` in the API document: `emails.receiving.attachments.list` is `client.emails.receiving.attachments.list`, with camelCase written in snake_case (`agent.claimEmail` is `client.agent.claim_email`). An `operationId` that is also the group of others is that group's `call`: `emails.metrics` (beside `emails.metrics.links`, `.countries` and `.clients`) is `client.emails.metrics.call(metrics: ["sent", "delivered"])`, or `client.emails.metrics.(…)`.

Path parameters are positional (`client.domains.get(domain_id)`), the request body is a Hash (`client.domains.create({ name: "acme.dev" })`) and query parameters are keyword arguments (`client.emails.list(limit: 50)`); a list parameter takes an array. Every method also takes `extra_headers:` and `timeout:`. Anything the methods do not cover goes through `client.request("GET", "/path", query: {…})`.

## Pagination

List methods return one page (`{"object" => "list", "data" => [...], "has_more" => …}`). Every cursor list also has a `*_all` method (`search_all` for thread search) returning a lazy `Enumerator` that fetches the following pages as you go:

```ruby
client.contacts.list_all(limit: 100).each do |contact|
  puts contact["email"]
end

first_ten = client.domains.list_all.first(10) # fetches only the pages it needs
```

An enumerator walks in the list's own order from `after:` (or the first page); start it with `before:` to walk the other way. It raises the same errors as the methods.

## Errors

Every error is a `BillionSend::Error` with the API's error shape, `status_code`, `name` and `message`, plus `request_id`, the API's id of the request (its `x-request-id` header; quote it when asking for support).

```ruby
begin
  client.domains.get("6a1f1d38-3c55-4a4e-9a57-0f2b3c4d5e6f")
rescue BillionSend::NotFoundError
  puts "no such domain"
rescue BillionSend::RateLimitError => e
  puts "retry in #{e.retry_after}"
rescue BillionSend::Error => e
  puts e.status_code, e.name, e.message, e.request_id
end
```

| Status | Error |
| --- | --- |
| 400, 422 | `ValidationError` |
| 401 | `AuthenticationError` |
| 403 | `PermissionDeniedError` |
| 404 | `NotFoundError` |
| 409 | `ConflictError` |
| 429 | `RateLimitError` (`retry_after` in seconds) |
| 5xx | `APIError` |
| no answer | `APIConnectionError`, and `APITimeoutError` (a subclass) for timeouts; `status_code` and `request_id` are `nil` |

An answer that is not JSON keeps the same shape, with `name` set to `"application_error"`. `WebhookVerificationError` (`name` `"webhook_verification_error"`) is a `BillionSend::Error` too. `error.to_s` reads `"404 not_found: Domain not found"`.

## Retries

A request is retried when repeating it is safe: GET, PUT and DELETE, and any request carrying an idempotency key (every send does). It is retried on 429, on 5xx, when no answer came back (connection failure, timeout), and, for a keyed request, on 409 `concurrent_idempotent_requests` (a retry that caught the first attempt still running). The wait is the answer's `Retry-After` when there is one, otherwise exponential backoff with jitter (0.5 s, 1 s, 2 s… up to 8 s). An answer asking to wait more than 60 seconds, such as a used-up daily quota, is raised at once. `max_retries:` (default 2) bounds the retries of one call; `0` turns them off.

## Configuration

| Argument | Environment | Default |
| --- | --- | --- |
| `api_key:` | `BILLIONSEND_API_KEY` | none (only `agent.signup` works without one; any other call raises `AuthenticationError`, `missing_api_key`) |
| `base_url:` | `BILLIONSEND_BASE_URL` | `https://api.billionsend.com` |
| `timeout:` | | `60` seconds per attempt (an event stream waits at least 60 s for each read) |
| `max_retries:` | | `2` |
| `default_headers:` | | none |
| `transport:` | | the HTTP layer: anything with `call(request)` and `open_stream(request)` like `BillionSend::NetHTTPTransport` (proxies, instrumentation, tests) |

A client holds no open connections between calls and is safe to share between threads.

## Development

```bash
bundle install
bundle exec rake        # generate:check, then the tests
script/test.sh          # the same in the pinned Ruby image (podman or docker)
```

The SDK is built from a snapshot of the API's OpenAPI document, `openapi/api.openapi.json`. The snapshot is the contract: `script/generate.rb` writes `lib/billionsend/resources.rb` from it (method names from each `operationId`, idempotency keys where an operation declares the `Idempotency-Key` header, enumerators for cursor lists), and the tests check every request the SDK sends and every answer it reads against it through a contract mock (`test/support/contract.rb`). A coverage test fails when an operation of the snapshot has no SDK method, or when the SDK has a method that is not an operation.

When the API changes:

```bash
ruby script/sync_openapi.rb      # or: --from path/to/api.openapi.json
ruby script/generate.rb
bundle exec rake test
```

Whatever fails is what the SDK has to follow. CI runs `script/generate.rb --check` so the generated code never drifts from the snapshot.

## Releasing

Publishing is manual; nothing is published on push.

1. On RubyGems, the owner of the `billionsend` gem adds a Trusted Publisher (for the first version, a pending one under the account's Trusted Publishers): repository `billionsend/billionsend-ruby`, workflow `release.yml`, environment `rubygems`.
2. Set `VERSION` in `lib/billionsend/version.rb`, turn the changelog's `Unreleased` heading into that version, commit, then tag and push: `git tag v0.1.0 && git push origin main v0.1.0`.
3. Actions → `release` → Run workflow, on the version tag. The workflow refuses a branch or a tag that differs from `BillionSend::VERSION`, runs every check, builds the gem and pushes it with RubyGems Trusted Publishing (no key stored).

Without Trusted Publishing, the same release from a clean checkout of the tag is `gem build billionsend.gemspec && gem push billionsend-0.1.0.gem` with an API key scoped to pushing the `billionsend` gem in `GEM_HOST_API_KEY`.

## License

MIT
