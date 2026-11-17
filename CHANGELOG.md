# Changelog

## 0.1.0 (2026-11-17)

First release of the BillionSend Ruby SDK.

- `BillionSend::Client` covering every operation of the BillionSend API (139), named after each operation's `operationId` in snake_case and grouped into resources: emails (with metrics, receiving, attachments and their extracted text), domains, API keys, contacts, audiences, contact properties, segments, topics, broadcasts, templates, webhooks, suppressions, unsubscribes, verifications, usage, deliverability, inboxes (agent and safety settings, labels, threads, quarantine, codes, drafts, event streams) and agent signup. An `operationId` that is also the group of others is that group's `call` (`client.emails.metrics.call`).
- Answers returned as parsed JSON: Hashes with string keys.
- Errors raised as `BillionSend::Error` subclasses carrying `status_code`, `name`, `message` and `request_id` (the API's `x-request-id`); a call without an API key raises `AuthenticationError` (`missing_api_key`) before sending.
- Sending methods always send an `Idempotency-Key`: the caller's, or a UUID made up for the call and shared by its retries.
- Retries for requests safe to repeat (GET, PUT, DELETE and keyed requests) on 429, 5xx, failures without an answer and 409 `concurrent_idempotent_requests`, honouring `Retry-After` up to 60 seconds, else exponential backoff with jitter.
- Server-sent event streams yielding `InboxStreamEvent` and `StreamGapEvent` objects, resuming with `Last-Event-ID` after the server closes them or the connection drops, and raising `APIConnectionError` after `max_reconnects` reconnects in a row that fail to open (a connection that opens starts the count again, so a quiet inbox keeps its stream); an error the block raises passes through as it is.
- `*_all` methods returning lazy enumerators over every item of a cursor list.
- `BillionSend.verify_webhook` checks a webhook delivery's signature and timestamp and returns the parsed event.
- No runtime dependencies.
