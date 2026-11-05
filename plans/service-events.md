# Batched service events

Status: proposed; no implementation yet. Action naming, exact schemas, and batching limits remain to be confirmed.

Goal: let users enable scheduled collection of service events and deliver them in batches to existing Ox conversations, without introducing a router agent.

## Agreed direction

- Each Ox conversation is a worker agent. There is no main/router agent choosing destinations for new events.
- Introduce service events as one kind of conversation input, distinct from user messages and ordinary service-call responses.
- Services opt in through a standard event-collection Action. A user enables collection for a specific service scope and destination conversation.
- Invoke that Action on a schedule without an LLM turn. An empty successful poll does not wake the agent.
- Batch pending events per destination conversation rather than starting one turn per event. Preserve individual event identities and group their presentation by service and external thread/subject.
- Keep service-specific collection in services; Ox owns scheduling, durable queuing, deduplication, and conversation delivery.
- Reuse existing service invocation and scheduling machinery where suitable. This is scheduled Action execution, not a prompt schedule that asks an agent to poll.
- Do not introduce the prototype's Evaluation, Decision, Ticket, or Mandate models for this work.

## Example

```text
User enables watching GitHub issue #42 in a conversation
    ↓
Scheduled GitHub event-collection Action
    → New comment
    → CI failed
    → Another comment
    ↓
Durable pending events for that conversation
    ↓
One bounded batch delivered as conversation input
    ↓
Conversation agent handles the changes together
    ↓
Normal service Actions retain their approval checks
```

Other enabled services targeting the same conversation can contribute to its pending batch. An external thread is a service resource identifier, not an Ox conversation. Events without an enabled destination do not automatically create conversations.

## Standard Action contract

Illustrative shape; not a final public API:

```ts
input: {
  scope: object;
  cursor: string | null;
}
output: {
  events: Array<{
    id: string;
    type: string;
    subject: string;
    occurredAt: string;
    payload: object;
  }>;
  nextCursor: string | null;
}
```

- Ox supplies service/account attribution from invocation context, rather than trusting payload claims.
- The service defines supported scope configuration and translates native changes into typed event payloads. Validate the standard envelope and service-declared scope/payload schemas.
- Event IDs must be stable across retries. Define their namespace before implementation; deduplicate deliveries within a watch while preserving independent delivery to other conversations.
- Cursors are opaque and bound to the service, account, and scope. Never reuse them after those bindings change.
- The first poll normally establishes a baseline without replaying old history. Define an explicit baseline contract rather than silently discarding the first returned page. Historical replay is outside the initial scope.
- Bound event count and payload size. Specify pagination separately from the durable collection checkpoint so a multi-page poll cannot skip changes.
- Authentication, source failures, expired cursors, and incomplete coverage are not successful empty results. Surface recovery needs instead of silently resetting a checkpoint.
- Collection must be read-only with respect to the external service. It must not send replies or perform other user-visible mutations.

## Enabling and scheduling

- Persist the destination conversation, service/account binding, scope, interval, enabled state, and collection checkpoint in the active Profile.
- Require explicit user enablement and show what will be watched, where events will be delivered, and the expected polling frequency.
- Preserve normal service attachment, authentication, validation, execution, and Action policy checks. If approval or authentication is needed, expose that state rather than repeatedly waking the agent or bypassing checks.
- Allow pause/resume and inspectable collection status. Disabling collection stops future polls; define pending-event behavior explicitly rather than silently deleting events.
- Never overlap polls for the same watch. Bound total polling concurrency and retry failures with backoff.
- Treat iOS background timing as best-effort, consistent with existing schedules; do not promise continuous monitoring or exact intervals.

## Batching and delivery

- Save collected events and advance the collection checkpoint atomically. A crash must not advance past events that were never queued.
- Separate collection state from delivery state: collected → durably queued → claimed as a batch → handled.
- When a conversation is idle, claim a bounded snapshot of its pending events and start one turn. Events arriving after the claim belong to a later batch.
- When a conversation is running, retain arrivals until a supported safe input boundary. Do not assume current Ox supports DSH-style next-step steering; confirm the runtime integration before choosing next-step delivery versus a subsequent turn.
- Preserve deterministic queue order and each event's native timestamp. Do not imply a reliable global occurrence order across services.
- Split oversized batches without dropping or silently truncating remaining events. Bound agent-context usage as well as event count.
- A short collection window could combine nearby polls before waking an idle conversation; decide whether this is necessary before adding a delay.
- Persist batch membership and delivery identity so interruption or restart can recover without losing inputs or duplicating conversation messages.
- Define when a batch counts as handled and how cancellation, failed turns, user questions, and approval waits affect it. Starting a turn alone is not completion.
- Do not claim exactly-once external side effects: service writes still require their ordinary approval and idempotency behavior.

## Provenance and lifecycle

- Service event content is untrusted external data, not a user instruction, authorization, or approval.
- Preserve source, actor information where available, event ID/type, external subject, timestamp, and payload through delivery and diagnostics.
- User messages remain distinguishable from service events even when both are inputs to the same conversation.
- Follow-up Actions retain normal policies, including confirmation before destructive actions.
- Bind watches to the owning Profile and conversation. Handle conversation deletion, service removal, account changes, and lost authentication without redirecting events to another destination.
- Keep structured diagnostics for poll outcomes, queue depth, deduplication, batch delivery, retries, and recovery. Avoid logging raw private payloads, credentials, or opaque cursors.

## DSH reference

Reference inspected: `deepseek-ai/dsh-superagent-prototype`, revision `8c32a9d`.

- `src/core/model.ts` and `src/core/intake.ts`: external Triggers are recorded on Threads, fanned out to subscribed Tickets, and queued for evaluation when needed.
- A Thread holds pending Trigger IDs; its Evaluation assesses a batch. Ox borrows the pending-buffer behavior, not the router/evaluation layer.
- `src/app/sessions.ts` and `src/app/delivery.ts`: agent inbox delivery distinguishes next-turn messages, next-step steering, and passive injection, with stable IDs and persisted-history deduplication.
- Ox's batching boundary is the destination conversation. External subjects remain context/grouping keys, not separate router evaluations.

## Implementation and verification

- [ ] Inspect existing service Action standards, schedule execution, conversation input queuing, persistence, and approval handling; reproduce current behavior before changing it.
- [ ] Confirm the standard Action name, scope discovery/configuration, baseline/pagination/checkpoint semantics, and event ID namespace.
- [ ] Confirm batching bounds, wake-up timing, running-conversation input boundary, and handled/recovery semantics.
- [ ] Implement and verify one service end to end before broad adoption; do not add a router or general workflow engine.
- [ ] Verify empty polls, multi-event polls, multiple services targeting one conversation, duplicate/overlapping results, and oversized batches.
- [ ] Verify arrivals during a running turn, user questions, approval waits, cancellation, failures, and restart at collection/claim/delivery boundaries.
- [ ] Verify disable/resume, removed services/accounts/conversations, authentication failure, expired cursors, incomplete coverage, and denied Actions.
- [ ] Use E2E/protocol/storage-upgrade checks as applicable; do not add unit tests. Review predecessor compatibility for persisted state changes.
- [ ] Reference Apple documentation for native scheduling/lifecycle changes and build both affected native app targets before committing shared native changes.
- [ ] Review LOC, file-tree and call-stack diffs, cyclomatic complexity, polling cost, queue growth, storage retention, and agent-context usage. Capture simulator evidence for UI changes.
