---
title: C example — examples/c/supervisor.c
---

# C example — `examples/c/supervisor.c`

This example demonstrates libjzx supervision from plain C:

- define a child actor that “flaps” (runs a bit, then fails)
- define a supervisor that restarts the child
- schedule messages using timers (`jzx_send_after`)

It’s a good “systems thinking” example because it forces you to confront:

- **payload ownership** (who allocates/frees message data?)
- **restart semantics** (when does a child restart?)
- **intensity limits** (how to avoid infinite crash loops)

## Includes

<!-- snippet: examples/c/supervisor.c#L1-L7 -->
```c title="Includes" showLineNumbers=1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "jzx/jzx.h"
```

Why each header exists:

- `stdio.h`: printing to stdout/stderr.
- `stdlib.h`: `malloc`/`free`.
- `string.h`: included by habit; this particular file doesn’t currently use it directly.
- `unistd.h`: included by habit; this particular file doesn’t currently use it directly.
- `jzx/jzx.h`: the libjzx ABI (loop, supervision, timers).

## Message payload type: `tick_msg`

This example sends a small heap-allocated struct as message payload.

<!-- snippet: examples/c/supervisor.c#L8-L10 -->
```c title="tick_msg" showLineNumbers=8
typedef struct {
    int tick;
} tick_msg;
```

What it represents:

- `tick` is a counter value that the child prints and increments.

Why a heap-allocated payload is used here:

- libjzx’s mailbox stores the `void* data` pointer as-is (it does not deep-copy arbitrary payload bytes).
- That means the payload must outlive the call to `jzx_send(...)` / `jzx_send_after(...)`.
- Heap allocation makes the lifetime explicit: the receiver frees it after use.

## Allocating payloads: `make_tick`

<!-- snippet: examples/c/supervisor.c#func=make_tick -->
```c title="make_tick(): allocate a tick payload" showLineNumbers=12
static tick_msg* make_tick(int tick) {
    tick_msg* msg = (tick_msg*)malloc(sizeof(tick_msg));
    if (!msg)
        return NULL;
    msg->tick = tick;
    return msg;
}
```

What this function guarantees:

- Returns a valid `tick_msg*` on success.
- Returns `NULL` on allocation failure.

Why it exists:

- It keeps “message allocation policy” in one place, which makes it easier to change later (e.g., switch to a custom allocator).

## The flapping child actor

The child:

- expects `msg->data` to point to a `tick_msg`
- prints the tick value
- schedules the next tick to itself via `jzx_send_after`
- after a few ticks, returns `FAIL` to simulate a crash

<!-- snippet: examples/c/supervisor.c#func=flapping_actor -->
```c title="flapping_actor(): schedule ticks, then fail" showLineNumbers=20
static jzx_behavior_result flapping_actor(jzx_context* ctx, const jzx_message* msg) {
    if (!msg->data)
        return JZX_BEHAVIOR_FAIL;
    tick_msg* t = (tick_msg*)msg->data;
    int next = t->tick + 1;
    printf("[child] tick=%d\n", t->tick);
    free(t);

    if (next > 3) {
        printf("[child] simulating failure\n");
        return JZX_BEHAVIOR_FAIL;
    }

    tick_msg* next_msg = make_tick(next);
    if (!next_msg)
        return JZX_BEHAVIOR_FAIL;
    if (jzx_send_after(ctx->loop, ctx->self, 100, next_msg, sizeof(tick_msg), 0, NULL) != JZX_OK) {
        free(next_msg);
        return JZX_BEHAVIOR_FAIL;
    }
    return JZX_BEHAVIOR_OK;
}
```

Deep explanation:

- `if (!msg->data) return FAIL;`
  - This is a defensive check and also a “failure injection” mechanism:
    - an empty payload is treated as a fault.
- `tick_msg* t = (tick_msg*)msg->data;`
  - The example assumes the sender is sending a valid `tick_msg`.
- `free(t);`
  - This is the ownership handoff: the receiver (child) frees the payload once consumed.
  - Why it matters: libjzx does not free user payload pointers automatically.
- `if (next > 3) return FAIL;`
  - This is where the child “crashes” to trigger a supervisor restart.
- `jzx_send_after(ctx->loop, ctx->self, 100, next_msg, sizeof(tick_msg), 0, NULL)`
  - Schedules a timer that will deliver `next_msg` back to the same actor after 100ms.
  - If scheduling fails, the code frees `next_msg` to avoid a leak.

## Supervisor configuration

### Loop creation

<!-- snippet: examples/c/supervisor.c#between=int main(void) {|jzx_child_spec children -->
```c title="Create the loop" showLineNumbers=43
int main(void) {
    jzx_config cfg;
    jzx_config_init(&cfg);

    jzx_loop* loop = jzx_loop_create(&cfg);
    if (!loop) {
        fprintf(stderr, "failed to create loop\n");
        return 1;
    }
```

This uses default loop config (`jzx_config_init`) and allocates the loop.

### Child spec

The child spec describes how the supervisor should manage the child.

<!-- snippet: examples/c/supervisor.c#between=jzx_child_spec children[] = {|jzx_supervisor_init sup_init -->
```c title="Child spec: restart policy for flapping_actor" showLineNumbers=53
    jzx_child_spec children[] = {
        {
            .behavior = flapping_actor,
            .state = NULL,
            .mode = JZX_CHILD_PERMANENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 100,
            .backoff = JZX_BACKOFF_EXPONENTIAL,
            .name = NULL,
        },
    };
```

What matters most here:

- `.behavior = flapping_actor`: the child’s behavior function.
- `.mode = JZX_CHILD_PERMANENT`:
  - The supervisor restarts the child on *any* exit (normal or failure).
  - This is a common systems pattern for “must be running” components.
- `.restart_delay_ms = 100`:
  - Adds a delay before restart to avoid hot crash loops.
- `.backoff = JZX_BACKOFF_EXPONENTIAL`:
  - Makes repeated failures increasingly delayed (crash loop damping).

### Supervisor init (strategy + intensity)

<!-- snippet: examples/c/supervisor.c#between=jzx_supervisor_init sup_init = {|jzx_actor_id sup_id -->
```c title="Supervisor init: one_for_one strategy + intensity window" showLineNumbers=65
    jzx_supervisor_init sup_init = {
        .children = children,
        .child_count = 1,
        .supervisor =
            {
                .strategy = JZX_SUP_ONE_FOR_ONE,
                .intensity = 5,
                .period_ms = 2000,
                .backoff = JZX_BACKOFF_EXPONENTIAL,
                .backoff_delay_ms = 100,
            },
    };
```

Interpretation:

- `.strategy = ONE_FOR_ONE`:
  - Only the failing child is restarted.
- `.intensity = 5` and `.period_ms = 2000`:
  - At most 5 restarts per 2 seconds.
  - If the supervisor exceeds this, it escalates (supervisor itself fails).
- `.backoff` and `.backoff_delay_ms`:
  - Supervisor-level backoff settings used to compute restart delays.
  - This compounds with the child’s `restart_delay_ms`.

## Spawning and kicking the system

### Spawn the supervisor and find the child id

<!-- snippet: examples/c/supervisor.c#between=jzx_actor_id sup_id|tick_msg* first -->
```c title="Spawn supervisor and fetch the child actor id" showLineNumbers=78
    jzx_actor_id sup_id = 0;
    if (jzx_spawn_supervisor(loop, &sup_init, 0, &sup_id) != JZX_OK) {
        fprintf(stderr, "failed to spawn supervisor\n");
        return 1;
    }

    jzx_actor_id child_id = 0;
    if (jzx_supervisor_child_id(loop, sup_id, 0, &child_id) != JZX_OK || child_id == 0) {
        fprintf(stderr, "failed to fetch child id\n");
        return 1;
    }
```

Notes:

- `jzx_spawn_supervisor` creates a supervisor actor and immediately spawns its children.
- `jzx_supervisor_child_id(loop, sup_id, 0, &child_id)` queries child index 0.
  - Important subtlety: if the child later restarts, its actor id will change (generation/index scheme).

### Send the initial tick

<!-- snippet: examples/c/supervisor.c#between=tick_msg* first|int rc -->
```c title="Kick the child with tick=0" showLineNumbers=90
    tick_msg* first = make_tick(0);
    if (!first)
        return 1;
    if (jzx_send(loop, child_id, first, sizeof(tick_msg), 0) != JZX_OK) {
        free(first);
        return 1;
    }
```

Why this is necessary:

- Actors run only when they have messages.
- The first tick message is what starts the chain of timer-scheduled ticks.

Ownership note:

- If `jzx_send` fails, the example frees `first` because it will never be delivered.

## Running the loop

<!-- snippet: examples/c/supervisor.c#between=int rc = jzx_loop_run|return rc; -->
```c title="Run the loop (event-loop style)" showLineNumbers=98
    int rc = jzx_loop_run(loop);
    jzx_loop_destroy(loop);
```

Important behavior:

- `jzx_loop_run` is event-loop style: it runs until you explicitly request stop (or the process exits).
- In this example, there is no stop request, so the process is intended to be terminated externally (e.g. Ctrl+C).

If you want a “self-terminating” variant:

- add a timer that calls `jzx_loop_request_stop(loop)`, or
- have a dedicated actor request stop after observing enough restarts.

## Full listing (for reference)

<!-- snippet: examples/c/supervisor.c#all -->
```c title="examples/c/supervisor.c" showLineNumbers=1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "jzx/jzx.h"

typedef struct {
    int tick;
} tick_msg;

static tick_msg* make_tick(int tick) {
    tick_msg* msg = (tick_msg*)malloc(sizeof(tick_msg));
    if (!msg)
        return NULL;
    msg->tick = tick;
    return msg;
}

static jzx_behavior_result flapping_actor(jzx_context* ctx, const jzx_message* msg) {
    if (!msg->data)
        return JZX_BEHAVIOR_FAIL;
    tick_msg* t = (tick_msg*)msg->data;
    int next = t->tick + 1;
    printf("[child] tick=%d\n", t->tick);
    free(t);

    if (next > 3) {
        printf("[child] simulating failure\n");
        return JZX_BEHAVIOR_FAIL;
    }

    tick_msg* next_msg = make_tick(next);
    if (!next_msg)
        return JZX_BEHAVIOR_FAIL;
    if (jzx_send_after(ctx->loop, ctx->self, 100, next_msg, sizeof(tick_msg), 0, NULL) != JZX_OK) {
        free(next_msg);
        return JZX_BEHAVIOR_FAIL;
    }
    return JZX_BEHAVIOR_OK;
}

int main(void) {
    jzx_config cfg;
    jzx_config_init(&cfg);

    jzx_loop* loop = jzx_loop_create(&cfg);
    if (!loop) {
        fprintf(stderr, "failed to create loop\n");
        return 1;
    }

    jzx_child_spec children[] = {
        {
            .behavior = flapping_actor,
            .state = NULL,
            .mode = JZX_CHILD_PERMANENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 100,
            .backoff = JZX_BACKOFF_EXPONENTIAL,
            .name = NULL,
        },
    };

    jzx_supervisor_init sup_init = {
        .children = children,
        .child_count = 1,
        .supervisor =
            {
                .strategy = JZX_SUP_ONE_FOR_ONE,
                .intensity = 5,
                .period_ms = 2000,
                .backoff = JZX_BACKOFF_EXPONENTIAL,
                .backoff_delay_ms = 100,
            },
    };

    jzx_actor_id sup_id = 0;
    if (jzx_spawn_supervisor(loop, &sup_init, 0, &sup_id) != JZX_OK) {
        fprintf(stderr, "failed to spawn supervisor\n");
        return 1;
    }

    jzx_actor_id child_id = 0;
    if (jzx_supervisor_child_id(loop, sup_id, 0, &child_id) != JZX_OK || child_id == 0) {
        fprintf(stderr, "failed to fetch child id\n");
        return 1;
    }

    tick_msg* first = make_tick(0);
    if (!first)
        return 1;
    if (jzx_send(loop, child_id, first, sizeof(tick_msg), 0) != JZX_OK) {
        free(first);
        return 1;
    }

    int rc = jzx_loop_run(loop);
    jzx_loop_destroy(loop);
    return rc;
}
```
