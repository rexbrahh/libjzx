---

## 1. Primary purpose

**Objective 1.1** Provide a **single process**, Erlang inspired **actor and supervision runtime** on top of a libxev style event loop, focused on:

- structured concurrency
- fault containment at the actor level
- predictable restart semantics

**Objective 1.2** Be a **first class runtime for your own systems** (SydraDB, trading infra, agents) rather than a universal "actors for all languages" platform.

So: infra you actually use, not a research VM.

---

## 2. Scope and target workloads

**Objective 2.1** Target workloads:

- long lived services with many small actors
- I/O heavy tasks (network, files, timers) integrated with libxev
- background jobs inside a single server (indexers, compaction, ingestion, orchestration)

**Objective 2.2** Target scale:

- tens of thousands of actors per process as a baseline
- hundred thousand as a stretch goal on one scheduler thread

We will keep this in mind for mailbox and scheduling design.

---

## 3. Reliability and failure semantics

**Objective 3.1** Support **supervision trees** similar in spirit to BEAM:

- one_for_one
- one_for_all
- rest_for_one
- child restart modes (permanent, transient, temporary)

**Objective 3.2** When an actor fails, the runtime must:

- tear down that actor cleanly
- notify its supervisor with structured error info
- apply the configured restart policy (including backoff)
- never silently swallow failures

**Objective 3.3** Containment level:

- contain logic errors and explicit failures at the actor level
- acknowledge that memory unsafety or UB can still kill the process (no fake guarantees here)

---

## 4. Performance and resource behavior

**Objective 4.1** No hidden threads. All concurrency that jazz introduces must be explicit:

- one scheduler per libxev loop in the initial version
- later: optional multi scheduler setup, still explicit

**Objective 4.2** Low allocation footprint:

- no per message malloc inside the runtime on the hot path, unless enabled
- allow the user to plug in allocators for state, metadata, and possibly pooled buffers

**Objective 4.3** Latency and fairness:

- never let a single actor starve others in the same scheduler
- explicit fairness rules in the scheduler loop (for example bounded messages per actor per tick)

---

## 5. API and integration goals

**Objective 5.1** Provide a **stable C ABI**:

- simple opaque actor ids
- function pointer based behaviors
- no dependency on Zig in the public header

Zig is the preferred implementation language, but the C ABI stands on its own.

**Objective 5.2** Provide a **thin, idiomatic Zig layer** over the C ABI:

- generics for typed messages if desired
- better error handling
- more ergonomic spawn helpers

**Objective 5.3** Make it straightforward to:

- embed libjzx inside SydraDB
- embed it inside other Zig or C codebases
- later wrap it from Rust or Go if needed

---

## 6. Simplicity and mechanical sympathy

**Objective 6.1** Keep the core small:

- one event loop abstraction
- actors
- mailboxes
- supervisors
- timers
- basic I/O hooks

Everything else (persistence, metrics, higher level workflows) is built on top, not baked into the core.

**Objective 6.2** Be explicit about everything:

- explicit spawn
- explicit supervision specs
- explicit message ownership and freeing
- explicit timeouts
- no hidden futures or async keyword magic

---

## 7. Non goals (important)

**Non goal 7.1** Do not try to guarantee safety against segfaults or UB in host code. If C or unsafe Zig goes wild, the process can die. Jazz does not pretend otherwise.

**Non goal 7.2** Do not build a full distributed system in v1:

- no cross node actor addressing baked into the core
- no automatic consensus or replication

We can add a "remote actor" layer later if needed.

**Non goal 7.3** Do not invent a new programming language or bytecode VM. Jazz is a runtime library, not a language.

**Non goal 7.4** Do not chase fully generic multi language magic. The goal is "good C ABI plus great Zig experience", not "everyone on earth can plug in any runtime".

---

## 8. SydraDB specific intent

Even though this is not hard wired, we should admit this upfront:

**Objective 8.1** Design jazz so it is an excellent fit for:

- SydraDB ingestion heads as actors
- compaction and merge workers as supervised actors
- index builders as actors with backoff and restart
- metrics and health reporting as actors
