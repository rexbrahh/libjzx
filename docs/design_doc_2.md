---

## 1. Process model and initialization

We commit to this for v1:

- Single thread per `jzx_loop`
- One `jzx_loop` owns:

  - libxev loop
  - actor table
  - run queue
  - timer registry
  - I/O registrations

Later you can add multi loop support, but v1 assumes all actors and sends happen from this thread.

### 1.1 Core types

```c
typedef struct jzx_loop jzx_loop;

typedef struct {
    void* (*alloc)(void* ctx, size_t size);
    void  (*free)(void* ctx, void* ptr);
    void* ctx;
} jzx_allocator;

typedef struct {
    jzx_allocator allocator; // for actor metadata, mailboxes, small structs
    uint32_t max_actors;
    uint32_t max_mailbox_size;   // default per actor
    uint32_t max_msgs_per_actor; // fair scheduling
    uint32_t max_actors_per_tick;
} jzx_config;
```

### 1.2 Create and run

```c
jzx_loop* jzx_loop_create(const jzx_config* cfg);
void      jzx_loop_destroy(jzx_loop* loop);

// blocking, runs forever until stopped
int       jzx_loop_run(jzx_loop* loop);

// request shutdown from inside or outside
void      jzx_loop_request_stop(jzx_loop* loop);
```

Inside `jzx_loop_run` you glue libxev’s polling with the scheduler logic we sketched earlier.

---

## 2. Actor lifecycle in more detail

Let’s make the actor behavior contract and lifecycle precise.

### 2.1 Behavior function signature

```c
typedef struct {
    void*         state;  // user state
    jzx_actor_id  self;
    jzx_loop*     loop;   // to schedule timers, register I O, spawn children
} jzx_context;

typedef enum {
    JZX_BEHAVIOR_OK   = 0, // continue
    JZX_BEHAVIOR_STOP = 1, // normal shutdown
    JZX_BEHAVIOR_FAIL = 2, // abnormal failure, triggers supervision
} jzx_behavior_result;

typedef jzx_behavior_result (*jzx_behavior_fn)(
    jzx_context* ctx,
    const jzx_message* msg
);
```

Rules:

- Behavior is called once per message.
- It should treat `ctx->state` as its private mutable state.
- It must decide whether to continue, stop, or fail.

### 2.2 Actor creation

We split creation into two pieces:

1. A higher level helper for “simple” actors.
2. A lower level primitive used by supervisors and advanced users.

```c
typedef struct {
    jzx_behavior_fn behavior;
    void*           state;         // can be NULL
    jzx_actor_id    supervisor;    // 0 = no supervisor (root)
    uint32_t        mailbox_cap;   // 0 = use default
} jzx_spawn_opts;

jzx_actor_id jzx_spawn(jzx_loop* loop, const jzx_spawn_opts* opts);
```

What happens inside:

- allocate `jzx_actor` and `jzx_mailbox` using the loop allocator
- assign id, initial status, supervisor, mailboxes
- add actor to internal table
- actor is not run until it receives a message or a timer

Optional: later you can add an `init_fn` called once before any message.

### 2.3 Stopping and failing actors

```c
void jzx_actor_stop(jzx_loop* loop, jzx_actor_id id);  // graceful

void jzx_actor_fail(jzx_loop* loop, jzx_actor_id id);  // abnormal
```

From inside behavior you usually just return `JZX_BEHAVIOR_STOP` or `JZX_BEHAVIOR_FAIL`.

From outside, these functions:

- mark actor as stopping or failed
- enqueue a synthetic system message to ensure it is processed soon
- let the scheduler tear it down in a consistent place

---

## 3. Mailbox and run queue details

We need to be explicit about how messages flow.

### 3.1 Run queue

Assume:

- Every actor that has messages and is runnable is in a single FIFO run queue.
- The queue itself is single producer, single consumer since only the scheduler thread pushes and pops.

Data structure:

```c
typedef struct jzx_runq_node {
    struct jzx_actor* actor;
    struct jzx_runq_node* next;
} jzx_runq_node;

typedef struct {
    jzx_runq_node* head;
    jzx_runq_node* tail;
} jzx_run_queue;
```

Actor has `in_run_queue` flag so we only enqueue once until drained.

### 3.2 Mailbox operations

Basic operations:

```c
bool jzx_mailbox_push(jzx_mailbox* m, const jzx_message* msg);
bool jzx_mailbox_pop(jzx_mailbox* m, jzx_message* out);
bool jzx_mailbox_empty(jzx_mailbox* m);
```

For v1 we assume messages are always enqueued from the same thread that runs the scheduler. That simplifies a lot and avoids locks.

Later, if you want sends from foreign threads, we add a secondary “inbound queue” and a thread safe push that gets drained into mailboxes within the loop thread.

### 3.3 Sending a message

Public API:

```c
int jzx_send(
    jzx_loop* loop,
    jzx_actor_id target,
    jzx_actor_id sender, // 0 = system or external
    void* data,
    size_t len,
    uint32_t tag
);
```

Flow:

1. Lookup actor by id.
2. Construct `jzx_message` shell pointing to `data`.
3. Push into mailbox. If mailbox is full:

   - either return error, or
   - drop oldest (optional policy)
4. If actor not in run queue:

   - enqueue actor
   - set `in_run_queue = 1`

Return codes you might want:

- `JZX_ERR_NO_SUCH_ACTOR`
- `JZX_ERR_MAILBOX_FULL`
- `JZX_OK`

Memory rule again: `data` is caller allocated and owned by the receiver after send.

---

## 4. Supervision semantics more concretely

Now we define exactly what the library does when something dies.

### 4.1 Child and supervisor state

Child spec, as before, but make the mode explicit.

```c
typedef enum {
    JZX_CHILD_PERMANENT,
    JZX_CHILD_TRANSIENT,
    JZX_CHILD_TEMPORARY,
} jzx_child_mode;

typedef struct {
    const char*       name;
    jzx_behavior_fn   behavior;
    jzx_init_fn       init;          // optional, may allocate state
    jzx_child_mode    mode;
    uint32_t          mailbox_cap;   // optional override
} jzx_child_spec;
```

Supervisor spec:

```c
typedef enum {
    JZX_SUP_ONE_FOR_ONE,
    JZX_SUP_ONE_FOR_ALL,
    JZX_SUP_REST_FOR_ONE,
} jzx_restart_strategy;

typedef struct {
    jzx_restart_strategy strategy;
    uint8_t              intensity;  // max restarts in period
    uint32_t             period_ms;  // time window
} jzx_supervisor_spec;
```

Internal supervisor state struct (simplified):

```c
typedef struct {
    jzx_supervisor_spec spec;
    size_t              child_count;
    jzx_child_spec*     child_specs; // immutable array
    jzx_actor_id*       child_ids;   // same length as child_specs
    uint32_t*           restart_counts;
    uint64_t*           first_failure_ts;
} jzx_supervisor_state;
```

### 4.2 System messages to supervisor

System tag range: reserve low tags for system.

```c
enum {
    JZX_TAG_SYS_CHILD_EXIT = 1,
    JZX_TAG_SYS_TIMER      = 2,
    // more later
};

typedef enum {
    JZX_EXIT_NORMAL,
    JZX_EXIT_FAIL,
    JZX_EXIT_PANIC,
} jzx_exit_reason;

typedef struct {
    jzx_actor_id child;
    jzx_exit_reason reason;
} jzx_child_exit;
```

When an actor stops or fails, the runtime:

- builds `jzx_child_exit`
- sends it to the supervisor with tag `JZX_TAG_SYS_CHILD_EXIT`
- uses sender id 0 (system)

### 4.3 Supervisor behavior

Supervisor itself is just an actor with a library provided behavior function:

```c
jzx_behavior_result jzx_supervisor_behavior(
    jzx_context* ctx,
    const jzx_message* msg
);
```

This function:

- switches on `msg->tag`
- if `CHILD_EXIT`, updates restart bookkeeping and applies the chosen strategy:

  - decide whether to restart that child or a group of children
  - enforce intensity / period limits
  - if limits exceeded, mark supervisor failed and propagate upward
- if timer, it might handle delayed restarts (backoff)

User does not have to write any of that unless they want custom behavior.

### 4.4 Backoff

We can add per child restart delay:

```c
typedef struct {
    uint32_t initial_delay_ms;
    uint32_t max_delay_ms;
    float    factor; // 2.0 for exponential
} jzx_backoff_spec;
```

Extend `jzx_child_spec` to optionally include `backoff`. On failure:

- compute next delay
- schedule a timer targeting the supervisor
- supervisor on timer fires restarts child

Keeps the core simple but gives you sane restart behavior.

---

## 5. Timers and I O concretely

### 5.1 Timers

Public API:

```c
typedef uint64_t jzx_timer_id;

int jzx_send_after(
    jzx_loop* loop,
    jzx_actor_id target,
    uint32_t ms,
    void* data,
    size_t len,
    uint32_t tag,
    jzx_timer_id* out_id // optional
);
```

Internally:

- allocate a small timer record
- register libxev timer
- when the timer fires, push `data` as a normal message with tag `tag` to `target`
- if the loop is stopped before it fires, the record is cleaned up

You can later add `jzx_cancel_timer(loop, timer_id)`.

### 5.2 I O

For v1, I would scope it to readiness notifications instead of building full protocol helpers.

API:

```c
typedef enum {
    JZX_IO_READ  = 1 << 0,
    JZX_IO_WRITE = 1 << 1,
} jzx_io_interest;

int jzx_watch_fd(
    jzx_loop* loop,
    int fd,
    jzx_actor_id owner,
    uint32_t interest
);
```

When libxev tells you fd is readable/writable, you:

- build a message with a system tag, for example `JZX_TAG_SYS_IO`
- payload is something like:

```c
typedef struct {
    int fd;
    uint32_t readiness; // bitmask of JZX_IO_READ / JZX_IO_WRITE
} jzx_io_event;
```

The owner actor handles that and calls `read` or `write` as appropriate.

Later you can wrap common patterns in helper libraries, but the core stays message based.

---

## 6. Concrete example: TCP echo server

Briefly, to verify the design is sane.

- One root supervisor `SupServer`

  - Has a child `ListenerActor`
- `ListenerActor`:

  - owns the listening socket
  - on `IO_READ` for the listener:

    - accept new connection
    - for each connection spawn `ConnActor` under a child supervisor `SupConn`
- `ConnActor`:

  - owns the client socket
  - watches fd for read
  - on data read, echo back
  - on EOF or error, returns `STOP` or `FAIL`

If `ConnActor` crashes because of a bug, the supervisor for connections applies its rules:

- restart just that connection actor, or
- for a simple echo server, treat it as permanent failure and not restart

We could write this out in more detail later, but nothing in the current design blocks this.

---

## 7. What is still missing from the design

We have:

- process model
- initialization
- actor representation
- mailboxes
- scheduler behavior
- supervision semantics
- timers and I O shape
- spawn and lifecycle APIs

Remaining big pieces to specify:

1. **Error model in detail**

   - global error enum
   - which functions can fail and why

2. **Actor table implementation**

   - how to map `jzx_actor_id` to pointers
   - reuse ids or monotonic ids only

3. **Foreign thread interaction story**

   - do we allow `jzx_send` from other threads in v1 or not

4. **Zig API layer**

   - typed actors
   - safer message handling
   - panic catching

5. **How SydraDB would map onto this concretely**

   - ingestion heads
   - merger actors
   - indexers

next up

- formalize the **C header** (full `jazz/jzx.h` style), or
- design the **actor table and id assignment scheme**, or
- sketch the **Zig wrapper layer** to make this actually pleasant to use in your code.
