# Changelog

## 0.2.0 (2026-11-26)

The OpenAPI snapshot follows the published document (186 operations). Every one of them has a method.

- New operations, named after their `operationId` in snake_case: `automations` (`create`, `list`, `get`, `update`, `remove`, `validate`, `duplicate`, `simulate`, `stop`, `metrics`; `automations.runs.list`, `get`, `cancel`), custom events (`events.create`, `list`, `get`, `update`, `remove`, `send`), `brand.get` and `update`, `brand.logo.upload` and `delete`, `domains.unsubscribe_page.logo.upload` and `delete`, `domains.claims.create`, `get` and `verify`, contact imports (`contacts.imports.create`, `list`, `get`), `contacts.segments.list`, `emails.share` and `unshare`, `emails.attachments.list` and `get`, `broadcasts.recipients` and `clicked_links`, `logs.list` and `get`, `oauth_grants.list` and `revoke`, `webhooks.events.list`, `get`, `replay` and `events.attempts.list`, `webhooks.rotate_signing_secret`, `api_keys.update` and `inboxes.agent.update`. Every new cursor list has its `*_all` enumerator.
- Removed: `unsubscribes.delete` (a recipient's opt-out is permanent) and `webhooks.rotate` (replaced by `webhooks.rotate_signing_secret`).
- `suppressions.list` and `list_all` take `kind:` (`email`, `domain` or `all`).
- `events.send` always sends an `Idempotency-Key`, like the sending methods.
- Multipart uploads (the logos and the contact import's CSV): the `file` field takes a String of bytes, anything that answers `read`, or `{ content:, filename:, content_type: }`; a Hash or Array in another field is sent as JSON. An upload is not repeated after a 5xx, a timeout or a lost connection; a 429 still repeats it. `client.request` takes `form:` and `files:`.
- A 429 is retried for every method, a POST or PATCH without an idempotency key included (the API answers it before it writes anything). 5xx and lost connections are still retried only for requests safe to repeat.
- `APIError` (5xx) carries `retry_after`, like `RateLimitError`.
- A path parameter that is empty, `.` or `..` raises `ArgumentError` before any request.
- An empty list in a query parameter is left out instead of sent as `key=`.
- The API key is read without the whitespace around it, a blank one counts as none, and one with a control character raises `ArgumentError`.
- A header value HTTP cannot carry (non-ASCII or a control character) raises `BillionSend::Error` (`name` `"invalid_header"`, the message names the header and never its value) before any request.
- A success with only whitespace for a body returns `nil`; a body that cannot be decoded (a broken gzip) raises `APIConnectionError` and is retried like a lost answer.
- Event streams: an `id:` line counts only once its block is complete, and the position follows an id sent without data as soon as it is read, so a dropped connection resumes from the right place.
- `BillionSend.verify_webhook` accepts a secret and header values with surrounding whitespace.

## 0.1.0 (2026-11-17)

First release of the BillionSend Ruby SDK.

- `BillionSend::Client` covering every operation of the BillionSend API (139), named after each operation's `operationId` in snake_case and grouped into resources: emails (with metrics, receiving, attachments and their extracted text), domains, API keys, contacts, audiences, contact properties, segments, topics, broadcasts, templates, webhooks, suppressions, unsubscribes, verifications, usage, deliverability, inboxes (agent and safety settings, labels, threads, quarantine, codes, drafts, event streams) and agent signup. An `operationId` that is also the group of others is that group's `call` (`client.emails.metrics.call`).
- Answers returned as parsed JSON: Hashes with string keys.
- Errors raised as `BillionSend::Error` subclasses carrying `status_code`, `name`, `message` and `request_id` (the API's `x-request-id`); a call without an API key raises `AuthenticationError` (`missing_api_key`) before sending.
- Sending methods always send an `Idempotency-Key`: the caller's, or a UUID made up for the call and shared by its retries.
- Retries for requests safe to repeat (GET, PUT, DELETE and keyed requests) on 429, 5xx, failures without an answer and 409 `concurrent_idempotent_requests`, honouring `Retry-After` up to 60 seconds, else exponential backoff with jitter.
- Server-sent event streams yielding `InboxStreamEvent` and `StreamGapEvent` objects, resuming with `Last-Event-ID` after the server closes them or the connection drops, and waiting what a 429 or 5xx's `Retry-After` asks before the next reconnect (over 60 seconds raises that error at once), and after `max_reconnects` reconnects in a row that fail to open raising the API's error for the last one, or `APIConnectionError` when it got no answer (a connection that opens starts the count again, so a quiet inbox keeps its stream); an error the block raises passes through as it is.
- `*_all` methods returning lazy enumerators over every item of a cursor list.
- `BillionSend.verify_webhook` checks a webhook delivery's signature and timestamp and returns the parsed event.
- No runtime dependencies.
