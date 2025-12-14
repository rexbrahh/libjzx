---
title: C example — examples/c/loop.c
---

# C example — `examples/c/loop.c`

This file is the smallest “hello actor” for libjzx in plain C:

- create a loop
- spawn one actor
- send it one message
- run the loop until the actor stops

Because it’s small, it’s a great first place to understand how the C ABI fits together.

## Includes

<!-- snippet: examples/c/loop.c#L1-L3 -->
```c title="Includes" showLineNumbers=1
#include "jzx/jzx.h"

#include <stdio.h>
```

- `jzx/jzx.h` is the public ABI: types (`jzx_loop`, `jzx_actor_id`) and functions (`jzx_spawn`, `jzx_send`, ...).
- `stdio.h` is used for `printf`/`fprintf`.

## The actor behavior

In libjzx, an “actor” is just a callback function (`behavior`) plus a state pointer.

<!-- snippet: examples/c/loop.c#func=print_behavior -->
```c title="print_behavior(): prints and stops" showLineNumbers=5
static jzx_behavior_result print_behavior(jzx_context* ctx, const jzx_message* msg) {
    (void)msg;
    printf("actor %llu received a message\n", (unsigned long long)ctx->self);
    return JZX_BEHAVIOR_STOP;
}
```

What each piece is doing:

- `static`: file-local function (not exported).
- `jzx_behavior_result`: what the runtime expects back from a behavior:
  - `JZX_BEHAVIOR_OK` → keep the actor running
  - `JZX_BEHAVIOR_STOP` → stop normally
  - `JZX_BEHAVIOR_FAIL` → fail (triggers supervision if configured)
- Parameters:
  - `ctx`: execution context (contains `self` id, `loop` pointer, and `state`)
  - `msg`: pointer to the delivered message envelope
- `(void)msg;`: explicitly marks `msg` unused (avoid warnings).
- `ctx->self`: actor id assigned by the runtime.
  - It’s a 64-bit value; the cast to `unsigned long long` is a portable way to print it with `%llu`.
- `return JZX_BEHAVIOR_STOP;`:
  - This makes the example terminate after processing exactly one message.

## Spawning and running the loop

### Config + loop creation

<!-- snippet: examples/c/loop.c#between=int main(void)|jzx_spawn_opts opts -->
```c title="Initialize config and create a loop" showLineNumbers=11
int main(void) {
    jzx_config cfg;
    jzx_config_init(&cfg);
    jzx_loop* loop = jzx_loop_create(&cfg);
    if (!loop) {
        fprintf(stderr, "failed to create loop\n");
        return 1;
    }
```

Key ideas:

- `jzx_config cfg;` is a “knob struct” for runtime caps and budgets.
- `jzx_config_init(&cfg)` fills in safe defaults (allocator, max actors, mailbox cap, etc).
- `jzx_loop_create(&cfg)` allocates and initializes the runtime.
  - It can fail (allocation failure, backend init failure), so the example checks `loop != NULL`.

### Spawn options

<!-- snippet: examples/c/loop.c#between=jzx_spawn_opts opts = {|jzx_actor_id actor_id -->
```c title="jzx_spawn_opts: describe the actor" showLineNumbers=20
    jzx_spawn_opts opts = {
        .behavior = print_behavior,
        .state = NULL,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = NULL,
    };
```

What each field means:

- `.behavior = print_behavior`: the function the runtime calls when a message is delivered.
- `.state = NULL`: the per-actor state pointer (unused in this example).
- `.supervisor = 0`: “no supervisor” (not linked into a supervisor tree).
- `.mailbox_cap = 0`: “use the loop’s default mailbox capacity”.
- `.name = NULL`: optional name used for observability/debug logs.

### Spawn, send, run, destroy

<!-- snippet: examples/c/loop.c#L27-L38 -->
```c title="Create actor, send one message, run" showLineNumbers=27
    jzx_actor_id actor_id = 0;
    if (jzx_spawn(loop, &opts, &actor_id) != JZX_OK) {
        fprintf(stderr, "failed to spawn actor\n");
        jzx_loop_destroy(loop);
        return 1;
    }

    jzx_send(loop, actor_id, NULL, 0, 0);
    jzx_loop_run(loop);
    jzx_loop_destroy(loop);
    return 0;
}
```

The flow:

- `jzx_spawn(...)` allocates the actor (including its mailbox) and inserts it into the actor table.
  - On success, `actor_id` is filled in by the runtime.
- `jzx_send(loop, actor_id, NULL, 0, 0)` enqueues a message:
  - `data=NULL, len=0` is an “empty payload” tick.
  - `tag=0` is an application-defined tag value (unused here).
- `jzx_loop_run(loop)` runs the scheduler until:
  - the loop is requested to stop, or
  - the runtime goes idle (no runnable actors, no timers, no I/O watchers).
- `jzx_loop_destroy(loop)` releases runtime-owned memory.

## Full listing (for reference)

<!-- snippet: examples/c/loop.c#all -->
```c title="examples/c/loop.c" showLineNumbers=1
#include "jzx/jzx.h"

#include <stdio.h>

static jzx_behavior_result print_behavior(jzx_context* ctx, const jzx_message* msg) {
    (void)msg;
    printf("actor %llu received a message\n", (unsigned long long)ctx->self);
    return JZX_BEHAVIOR_STOP;
}

int main(void) {
    jzx_config cfg;
    jzx_config_init(&cfg);
    jzx_loop* loop = jzx_loop_create(&cfg);
    if (!loop) {
        fprintf(stderr, "failed to create loop\n");
        return 1;
    }

    jzx_spawn_opts opts = {
        .behavior = print_behavior,
        .state = NULL,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = NULL,
    };
    jzx_actor_id actor_id = 0;
    if (jzx_spawn(loop, &opts, &actor_id) != JZX_OK) {
        fprintf(stderr, "failed to spawn actor\n");
        jzx_loop_destroy(loop);
        return 1;
    }

    jzx_send(loop, actor_id, NULL, 0, 0);
    jzx_loop_run(loop);
    jzx_loop_destroy(loop);
    return 0;
}
```
