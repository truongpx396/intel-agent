# Contract: Channels — Discord, Slack, WeChat

**Port surface**: [agent-deps.md](./agent-deps.md) | **Host obligations**: [host-integration.md](./host-integration.md) | **Status**: the contract for reaching the runtime from a chat platform. Phase 2 build; the port and its capability model are fixed **now** so adapters are additive and the graph never learns a platform exists.

A channel is **two halves with different owners**:

```
   ┌─ Channel (this repo) ──────────────┐        ┌─ IdentityBinder (host) ──────┐
   │  protocol plumbing:                │        │  platform_user               │
   │    connection, events, rate limits │  ───►  │      ↓                       │
   │    message chunking, formatting    │        │  (tenant, principal, claims) │
   └────────────────────────────────────┘        └──────────────────────────────┘
                                                   this IS obligation H1
```

**Why the split falls there.** Discord's gateway protocol is identical for every domain — writing it twice is the waste this repo exists to prevent. But *"which of my users is Discord snowflake `418...`"* is irreducibly your business logic, and getting it wrong is a privilege escalation. So the plumbing is ours, the identity is yours. It is the same rule as everywhere else: **we own the port, you own the domain decision.**

---

## Capabilities — why this is not "Discord three times"

The three platforms are not variations on one shape. Encoding their differences as *data* is what stops an adapter from silently lying about what it supports.

| | Discord | Slack | WeChat (Official Account) |
|---|---|---|---|
| Transport | Gateway WebSocket | Socket Mode or Events API | HTTP callback |
| **Streaming** | via message edit | via `chat.update` | **none** |
| Edit in place | yes | yes | **no** |
| Max message | 2,000 chars | ~3,000 (Block Kit) | 2,048 bytes |
| **Reply deadline** | none | none | **~5 seconds** |
| Late/async reply | free | free | customer-service API, **48h window only** |
| Identity | snowflake | `U…` + team `T…` | **OpenID, scoped per app** |
| Conversation key | channel / thread id | `thread_ts` | user OpenID |

**WeChat is the one that shapes the port.** It cannot stream and must answer within roughly five seconds, or fall back to a customer-service message that is only permitted inside a 48-hour window from the user's last message. An adapter layer designed around Discord and then "extended" to WeChat produces an integration that works in testing and fails on any query slower than five seconds.

So the port declares capabilities and the runtime **adapts to them**:

```python
class ChannelCapabilities(TypedDict):
    supports_streaming: bool        # False → runtime buffers, emits once
    edit_in_place: bool             # True  → stream by editing one message
    max_message_chars: int          # runtime splits on a safe boundary
    response_deadline_s: float | None   # WeChat: ~5.0
    supports_attachments: bool
```

### What the runtime does with each

- **`supports_streaming: False`** — the `StreamWriter` buffers tokens and emits a single message at completion. No node changes; the graph still streams internally, and the adapter is the only thing that knows.
- **`edit_in_place: True`** — stream by editing one message on an interval (rate-limit aware), rather than posting a message per chunk.
- **`response_deadline_s` set** — the run's wall-clock deadline is clamped to `min(manifest.run_deadline_s, channel.response_deadline_s)`. If the deadline is hit, the adapter emits its **deferral** message and the run continues, delivering via the late-reply path if the platform has one and the window is open. **A run must never be silently truncated to fit a transport.**
- **`max_message_chars`** — split on a paragraph or code-fence boundary, never mid-token. A split must not corrupt a fenced block.

> **Capabilities are declared, not detected.** An adapter that reports `supports_streaming: True` and then cannot stream is a contract violation caught by `ChannelContract`, not a runtime surprise.

---

## The ports

```python
class InboundMessage(TypedDict):
    channel: str                 # "discord" | "slack" | "wechat"
    platform_user: str           # snowflake | U-id | OpenID
    platform_scope: str          # guild+channel | team+channel | app id
    conversation_key: str        # maps to the graph thread_id (see below)
    text: str
    attachments: list[dict]
    received_at: float
    reply_deadline: float | None # absolute; derived from response_deadline_s

class Channel(Protocol):
    name: str
    capabilities: ChannelCapabilities
    def listen(self) -> AsyncIterator[InboundMessage]: ...
    def writer(self, msg: InboundMessage) -> StreamWriter: ...
```

```python
# HOST-SUPPLIED. This is obligation H1 wearing a different hat.
class IdentityBinder(Protocol):
    async def bind(self, msg: InboundMessage) -> SecurityCtx | None: ...
```

### `bind` returning `None` MUST refuse the message

`None` means *"I do not know who this is."* It MUST NOT fall back to an anonymous or default identity. A default identity for an unrecognized Discord user is exactly the privilege escalation obligation H1 exists to prevent — and on a public Discord guild, "unrecognized user" is the normal case, not the edge case.

The runtime refuses and the adapter replies with a non-committal message. It never proceeds with a guessed `ctx`.

### Identity notes per platform

- **WeChat OpenID is scoped to your app.** The same person has different OpenIDs across your Official Account and your Mini Program. A binder keyed on OpenID alone silently splits one user into several — use UnionID if you need identity across your app family.
- **Slack IDs are workspace-scoped**: bind on `(team_id, user_id)`, never `user_id` alone.
- **Discord DMs carry no guild**, so `platform_scope` is the DM channel. A binder that assumes a guild will fail on DMs.

### Conversation continuity

`conversation_key` is what the runner maps to the graph's `thread_id`, giving a channel conversation the same memory and checkpoint continuity a web session gets.

**It must be namespaced by channel and scope** — `discord:guild:channel` — never the bare platform id. Two platforms can issue the same opaque id, and a collision would cross-wire two conversations' memory. Since memory is clearance-filtered per turn this is not a visibility breach, but it is a correctness and privacy defect.

---

## `ChannelRunner` — generic glue

```
listen() ─► IdentityBinder.bind() ─► refuse if None
                    │
                    ▼
        build ctx + thread_id ─► graph.astream_events ─► channel.writer()
```

The runner is generic and ships here. It is where capability adaptation lives — buffering for non-streaming channels, clamping deadlines, splitting long messages. Adapters stay thin protocol shims; the graph never learns a platform exists.

---

## Manifest

```yaml
channels: [discord, slack]        # adapters to attach
```

`channels[]` selects adapters by name, exactly as `retrieval.kind` selects a backend. **Consistent with the invariant that a manifest narrows and never widens**: attaching a channel changes how a principal reaches the agent, never what that principal may see. The floor stays below the agent on every channel.

---

## Packaging

Adapters ship as **extras**, matching how backends already work:

```bash
pip install "intel-agent[discord]"
pip install "intel-agent[slack,wechat]"
```

A channel's SDK is never a base dependency. Installing the runtime must not pull a Discord client into a deployment that has no Discord.

---

## Deployment shape

Discord and Slack Socket Mode are **long-lived stateful connections**, so a channel runs as a persistent worker rather than request/response. The durable compiled form plus the checkpointer already support this; no new deployment primitive is required.

WeChat is the opposite — an **HTTP callback** with a hard deadline, so it deploys behind a normal web server. One reason the capability model is data rather than subclassing: these two shapes share a port without sharing a runtime posture.

---

## Contract test obligations (`ChannelContract`)

- **Capabilities are honest**: an adapter declaring `supports_streaming: True` emits more than one progressive update on a multi-token answer; one declaring `False` emits exactly one message.
- **Unknown identity refuses**: `bind` → `None` produces no graph invocation, no spend, and no tool call.
- **Deadline clamping**: on a channel with `response_deadline_s`, the run deadline is the min of that and the manifest's — and a run exceeding it produces a **deferral**, never a truncated answer presented as complete.
- **Chunking is lossless**: an answer exceeding `max_message_chars` arrives complete across messages, with no fenced code block split mid-fence.
- **Conversation isolation**: two conversations with colliding raw platform ids but different `platform_scope` never share a `thread_id`.
- **Graph is channel-blind**: a golden query produces byte-identical graph output across a fake channel and the web transport — the channel-adapter swap test, extended to real adapters.
- **No SDK leak**: with only `intel-agent[discord]` installed, importing the runtime does not import Slack or WeChat SDKs.
- **Rate-limit backoff**: a `429` from the platform is retried with the platform's own backoff and never drops a delivered answer.

---

## Phase boundary

**Now**: the port, the capability model, and the `IdentityBinder` split are fixed, so adapters are additive.

**Phase 2**: the three adapters, `ChannelRunner`, and the conformance suite (tasks T065–T070).

**Not planned**: inbound *voice*, and any platform whose terms forbid automated replies. Note that WeChat Official Account capabilities differ substantially by account type and verification status — a Phase-2 adapter targets a specific account type and says which, rather than claiming "WeChat support" generally.
