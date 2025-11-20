#include "jzx_internal.h"

#include <stdlib.h>
#include <string.h>

// -----------------------------------------------------------------------------
// Utility helpers
// -----------------------------------------------------------------------------

static inline uint32_t jzx_id_index(jzx_actor_id id) {
    return (uint32_t)(id & 0xffffffffu);
}

static inline uint32_t jzx_id_generation(jzx_actor_id id) {
    return (uint32_t)(id >> 32u);
}

static inline jzx_actor_id jzx_make_id(uint32_t gen, uint32_t idx) {
    return ((uint64_t)gen << 32u) | (uint64_t)idx;
}

static void* jzx_alloc(jzx_allocator* alloc, size_t size) {
    return alloc->alloc ? alloc->alloc(alloc->ctx, size) : NULL;
}

static void jzx_free(jzx_allocator* alloc, void* ptr) {
    if (alloc->free) {
        alloc->free(alloc->ctx, ptr);
    }
}

static jzx_err jzx_send_internal(jzx_loop* loop,
                                 jzx_actor_id target,
                                 void* data,
                                 size_t len,
                                 uint32_t tag,
                                 jzx_actor_id sender);

// -----------------------------------------------------------------------------
// Mailbox implementation
// -----------------------------------------------------------------------------

static jzx_err jzx_mailbox_init(jzx_mailbox_impl* box,
                                uint32_t capacity,
                                jzx_allocator* allocator) {
    if (capacity == 0) {
        capacity = 1;
    }
    size_t bytes = sizeof(jzx_message) * capacity;
    jzx_message* buffer = (jzx_message*)jzx_alloc(allocator, bytes);
    if (!buffer) {
        return JZX_ERR_NO_MEMORY;
    }
    memset(buffer, 0, bytes);
    box->buffer = buffer;
    box->capacity = capacity;
    box->head = 0;
    box->tail = 0;
    box->count = 0;
    return JZX_OK;
}

static void jzx_mailbox_deinit(jzx_mailbox_impl* box, jzx_allocator* allocator) {
    if (box->buffer) {
        jzx_free(allocator, box->buffer);
    }
    memset(box, 0, sizeof(*box));
}

static int jzx_mailbox_push(jzx_mailbox_impl* box, const jzx_message* msg) {
    if (box->count == box->capacity) {
        return -1;
    }
    box->buffer[box->tail] = *msg;
    box->tail = (box->tail + 1) % box->capacity;
    box->count++;
    return 0;
}

static int jzx_mailbox_pop(jzx_mailbox_impl* box, jzx_message* out) {
    if (box->count == 0) {
        return -1;
    }
    *out = box->buffer[box->head];
    box->head = (box->head + 1) % box->capacity;
    box->count--;
    return 0;
}

static int jzx_mailbox_has_items(const jzx_mailbox_impl* box) {
    return box->count > 0;
}

// -----------------------------------------------------------------------------
// Actor table implementation
// -----------------------------------------------------------------------------

static jzx_err jzx_actor_table_init(jzx_actor_table* table,
                                    uint32_t capacity,
                                    jzx_allocator* allocator) {
    memset(table, 0, sizeof(*table));
    table->capacity = capacity;
    size_t slot_bytes = sizeof(jzx_actor*) * capacity;
    size_t gen_bytes = sizeof(uint32_t) * capacity;
    size_t stack_bytes = sizeof(uint32_t) * capacity;

    table->slots = (jzx_actor**)jzx_alloc(allocator, slot_bytes);
    table->generations = (uint32_t*)jzx_alloc(allocator, gen_bytes);
    table->free_stack = (uint32_t*)jzx_alloc(allocator, stack_bytes);
    if (!table->slots || !table->generations || !table->free_stack) {
        return JZX_ERR_NO_MEMORY;
    }

    memset(table->slots, 0, slot_bytes);
    for (uint32_t i = 0; i < capacity; ++i) {
        table->generations[i] = 1;
        table->free_stack[i] = capacity - 1 - i;
    }
    table->free_top = capacity;
    table->used = 0;
    return JZX_OK;
}

static void jzx_actor_table_deinit(jzx_actor_table* table, jzx_allocator* allocator) {
    if (!table) {
        return;
    }
    if (table->slots) {
        jzx_free(allocator, table->slots);
    }
    if (table->generations) {
        jzx_free(allocator, table->generations);
    }
    if (table->free_stack) {
        jzx_free(allocator, table->free_stack);
    }
    memset(table, 0, sizeof(*table));
}

static jzx_actor* jzx_actor_table_lookup(jzx_actor_table* table, jzx_actor_id id) {
    uint32_t idx = jzx_id_index(id);
    if (idx >= table->capacity) {
        return NULL;
    }
    if (table->generations[idx] != jzx_id_generation(id)) {
        return NULL;
    }
    return table->slots[idx];
}

static jzx_err jzx_actor_table_insert(jzx_actor_table* table,
                                      jzx_actor* actor,
                                      jzx_allocator* allocator,
                                      jzx_actor_id* out_id) {
    (void)allocator;
    if (table->free_top == 0) {
        return JZX_ERR_MAX_ACTORS;
    }
    uint32_t idx = table->free_stack[--table->free_top];
    uint32_t gen = table->generations[idx];
    actor->id = jzx_make_id(gen, idx);
    table->slots[idx] = actor;
    table->used++;
    if (out_id) {
        *out_id = actor->id;
    }
    return JZX_OK;
}

static void jzx_actor_table_remove(jzx_actor_table* table,
                                   jzx_actor* actor) {
    if (!actor) {
        return;
    }
    uint32_t idx = jzx_id_index(actor->id);
    if (idx >= table->capacity) {
        return;
    }
    if (table->slots[idx] != actor) {
        return;
    }
    table->slots[idx] = NULL;
    table->generations[idx] += 1u;
    table->free_stack[table->free_top++] = idx;
    if (table->used > 0) {
        table->used--;
    }
}

// -----------------------------------------------------------------------------
// Run queue implementation
// -----------------------------------------------------------------------------

static jzx_err jzx_run_queue_init(jzx_run_queue* rq,
                                  uint32_t capacity,
                                  jzx_allocator* allocator) {
    memset(rq, 0, sizeof(*rq));
    rq->capacity = capacity > 0 ? capacity : 1;
    rq->entries = (jzx_actor**)jzx_alloc(allocator, sizeof(jzx_actor*) * rq->capacity);
    if (!rq->entries) {
        return JZX_ERR_NO_MEMORY;
    }
    memset(rq->entries, 0, sizeof(jzx_actor*) * rq->capacity);
    return JZX_OK;
}

static void jzx_run_queue_deinit(jzx_run_queue* rq, jzx_allocator* allocator) {
    if (rq->entries) {
        jzx_free(allocator, rq->entries);
    }
    memset(rq, 0, sizeof(*rq));
}

static int jzx_run_queue_push(jzx_run_queue* rq, jzx_actor* actor) {
    if (rq->count == rq->capacity) {
        return -1;
    }
    rq->entries[rq->tail] = actor;
    rq->tail = (rq->tail + 1) % rq->capacity;
    rq->count++;
    return 0;
}

static jzx_actor* jzx_run_queue_pop(jzx_run_queue* rq) {
    if (rq->count == 0) {
        return NULL;
    }
    jzx_actor* actor = rq->entries[rq->head];
    rq->entries[rq->head] = NULL;
    rq->head = (rq->head + 1) % rq->capacity;
    rq->count--;
    return actor;
}

static void jzx_schedule_actor(jzx_loop* loop, jzx_actor* actor) {
    if (!actor || actor->in_run_queue) {
        return;
    }
    if (jzx_run_queue_push(&loop->run_queue, actor) == 0) {
        actor->in_run_queue = 1;
    }
}

static void jzx_teardown_actor(jzx_loop* loop, jzx_actor* actor) {
    if (!actor) {
        return;
    }
    jzx_mailbox_deinit(&actor->mailbox, &loop->allocator);
    jzx_actor_table_remove(&loop->actors, actor);
    jzx_free(&loop->allocator, actor);
}

// -----------------------------------------------------------------------------
// Async send queue
// -----------------------------------------------------------------------------



// -----------------------------------------------------------------------------
// Config helpers
// -----------------------------------------------------------------------------

static void* default_alloc(void* ctx, size_t size) {
    (void)ctx;
    return malloc(size);
}

static void default_free(void* ctx, void* ptr) {
    (void)ctx;
    free(ptr);
}

void jzx_config_init(jzx_config* cfg) {
    if (!cfg) {
        return;
    }
    memset(cfg, 0, sizeof(*cfg));
    cfg->allocator.alloc = default_alloc;
    cfg->allocator.free = default_free;
    cfg->allocator.ctx = NULL;
    cfg->max_actors = 1024;
    cfg->default_mailbox_cap = 1024;
    cfg->max_msgs_per_actor = 64;
    cfg->max_actors_per_tick = 1024;
}

static void apply_defaults(jzx_config* cfg) {
    if (!cfg->allocator.alloc) {
        cfg->allocator.alloc = default_alloc;
    }
    if (!cfg->allocator.free) {
        cfg->allocator.free = default_free;
    }
    if (cfg->max_actors == 0) {
        cfg->max_actors = 1024;
    }
    if (cfg->default_mailbox_cap == 0) {
        cfg->default_mailbox_cap = 1024;
    }
    if (cfg->max_msgs_per_actor == 0) {
        cfg->max_msgs_per_actor = 64;
    }
    if (cfg->max_actors_per_tick == 0) {
        cfg->max_actors_per_tick = 1024;
    }
}

// -----------------------------------------------------------------------------
// Loop lifecycle
// -----------------------------------------------------------------------------

jzx_loop* jzx_loop_create(const jzx_config* cfg) {
    jzx_config local;
    if (cfg) {
        local = *cfg;
    } else {
        jzx_config_init(&local);
    }
    apply_defaults(&local);

    jzx_loop* loop = (jzx_loop*)jzx_alloc(&local.allocator, sizeof(jzx_loop));
    if (!loop) {
        return NULL;
    }
    memset(loop, 0, sizeof(*loop));
    loop->cfg = local;
    loop->allocator = local.allocator;

    if (jzx_actor_table_init(&loop->actors, local.max_actors, &loop->allocator) != JZX_OK) {
        jzx_loop_destroy(loop);
        return NULL;
    }
    if (jzx_run_queue_init(&loop->run_queue, local.max_actors, &loop->allocator) != JZX_OK) {
        jzx_loop_destroy(loop);
        return NULL;
    }
    loop->running = 0;
    loop->stop_requested = 0;
    return loop;
}

void jzx_loop_destroy(jzx_loop* loop) {
    if (!loop) {
        return;
    }
    // Tear down any remaining actors.
    for (uint32_t i = 0; i < loop->actors.capacity; ++i) {
        jzx_actor* actor = loop->actors.slots ? loop->actors.slots[i] : NULL;
        if (actor) {
            jzx_mailbox_deinit(&actor->mailbox, &loop->allocator);
            jzx_free(&loop->allocator, actor);
            loop->actors.slots[i] = NULL;
        }
    }
    jzx_actor_table_deinit(&loop->actors, &loop->allocator);
    jzx_run_queue_deinit(&loop->run_queue, &loop->allocator);
    jzx_free(&loop->allocator, loop);
}

int jzx_loop_run(jzx_loop* loop) {
    if (!loop) {
        return JZX_ERR_INVALID_ARG;
    }
    if (loop->running) {
        return JZX_ERR_LOOP_CLOSED;
    }
    loop->running = 1;
    int rc = JZX_OK;
    while (!loop->stop_requested) {
        uint32_t actors_processed = 0;
        while (actors_processed < loop->cfg.max_actors_per_tick) {
            jzx_actor* actor = jzx_run_queue_pop(&loop->run_queue);
            if (!actor) {
                break;
            }
            actor->in_run_queue = 0;
            if (actor->status == JZX_ACTOR_STATUS_STOPPING ||
                actor->status == JZX_ACTOR_STATUS_FAILED) {
                jzx_teardown_actor(loop, actor);
                continue;
            }

            uint32_t processed_msgs = 0;
            while (processed_msgs < loop->cfg.max_msgs_per_actor) {
                jzx_message msg;
                if (jzx_mailbox_pop(&actor->mailbox, &msg) != 0) {
                    break;
                }
                jzx_context ctx = {
                    .state = actor->state,
                    .self = actor->id,
                    .loop = loop,
                };
                jzx_behavior_result result = actor->behavior(&ctx, &msg);
                processed_msgs++;
                if (result == JZX_BEHAVIOR_STOP) {
                    actor->status = JZX_ACTOR_STATUS_STOPPING;
                    break;
                } else if (result == JZX_BEHAVIOR_FAIL) {
                    actor->status = JZX_ACTOR_STATUS_FAILED;
                    break;
                }
            }
            if (actor->status == JZX_ACTOR_STATUS_STOPPING ||
                actor->status == JZX_ACTOR_STATUS_FAILED) {
                jzx_teardown_actor(loop, actor);
            } else if (jzx_mailbox_has_items(&actor->mailbox)) {
                jzx_schedule_actor(loop, actor);
            }
            actors_processed++;
        }
        // Exit the loop once there is no more runnable work.
        if (loop->run_queue.count == 0) {
            break;
        }
    }
    loop->running = 0;
    loop->stop_requested = 0;
    return rc;
}

void jzx_loop_request_stop(jzx_loop* loop) {
    if (!loop) {
        return;
    }
    loop->stop_requested = 1;
}

// -----------------------------------------------------------------------------
// Actor APIs
// -----------------------------------------------------------------------------

static jzx_actor* jzx_actor_create(jzx_loop* loop, const jzx_spawn_opts* opts) {
    jzx_actor* actor = (jzx_actor*)jzx_alloc(&loop->allocator, sizeof(jzx_actor));
    if (!actor) {
        return NULL;
    }
    memset(actor, 0, sizeof(*actor));
    actor->status = JZX_ACTOR_STATUS_RUNNING;
    actor->behavior = opts->behavior;
    actor->state = opts->state;
    actor->supervisor = opts->supervisor;
    if (jzx_mailbox_init(&actor->mailbox,
                         opts->mailbox_cap ? opts->mailbox_cap : loop->cfg.default_mailbox_cap,
                         &loop->allocator) != JZX_OK) {
        jzx_free(&loop->allocator, actor);
        return NULL;
    }
    return actor;
}

jzx_err jzx_spawn(jzx_loop* loop, const jzx_spawn_opts* opts, jzx_actor_id* out_id) {
    if (!loop || !opts || !opts->behavior) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_actor* actor = jzx_actor_create(loop, opts);
    if (!actor) {
        return JZX_ERR_NO_MEMORY;
    }
    jzx_err err = jzx_actor_table_insert(&loop->actors, actor, &loop->allocator, out_id);
    if (err != JZX_OK) {
        jzx_mailbox_deinit(&actor->mailbox, &loop->allocator);
        jzx_free(&loop->allocator, actor);
        return err;
    }
    return JZX_OK;
}

static jzx_err jzx_send_internal(jzx_loop* loop,
                                 jzx_actor_id target,
                                 void* data,
                                 size_t len,
                                 uint32_t tag,
                                 jzx_actor_id sender) {
    if (!loop) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_actor* actor = jzx_actor_table_lookup(&loop->actors, target);
    if (!actor) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    jzx_message msg = {
        .data = data,
        .len = len,
        .tag = tag,
        .sender = sender,
    };
    if (jzx_mailbox_push(&actor->mailbox, &msg) != 0) {
        return JZX_ERR_MAILBOX_FULL;
    }
    jzx_schedule_actor(loop, actor);
    return JZX_OK;
}

jzx_err jzx_send(jzx_loop* loop,
                 jzx_actor_id target,
                 void* data,
                 size_t len,
                 uint32_t tag) {
    return jzx_send_internal(loop, target, data, len, tag, 0);
}

jzx_err jzx_send_async(jzx_loop* loop,
                       jzx_actor_id target,
                       void* data,
                       size_t len,
                       uint32_t tag) {
    return jzx_send_internal(loop, target, data, len, tag, 0);
}

jzx_err jzx_actor_stop(jzx_loop* loop, jzx_actor_id id) {
    if (!loop) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_actor* actor = jzx_actor_table_lookup(&loop->actors, id);
    if (!actor) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    actor->status = JZX_ACTOR_STATUS_STOPPING;
    jzx_schedule_actor(loop, actor);
    return JZX_OK;
}

jzx_err jzx_actor_fail(jzx_loop* loop, jzx_actor_id id) {
    if (!loop) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_actor* actor = jzx_actor_table_lookup(&loop->actors, id);
    if (!actor) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    actor->status = JZX_ACTOR_STATUS_FAILED;
    jzx_schedule_actor(loop, actor);
    return JZX_OK;
}

// -----------------------------------------------------------------------------
// Timers & IO (stubs for future work)
// -----------------------------------------------------------------------------

jzx_err jzx_send_after(jzx_loop* loop,
                       jzx_actor_id target,
                       uint32_t ms,
                       void* data,
                       size_t len,
                       uint32_t tag,
                       jzx_timer_id* out_timer) {
    (void)loop;
    (void)target;
    (void)ms;
    (void)data;
    (void)len;
    (void)tag;
    if (out_timer) {
        *out_timer = 0;
    }
    return JZX_ERR_UNKNOWN;
}

jzx_err jzx_cancel_timer(jzx_loop* loop, jzx_timer_id timer) {
    (void)loop;
    (void)timer;
    return JZX_ERR_UNKNOWN;
}

jzx_err jzx_watch_fd(jzx_loop* loop, int fd, jzx_actor_id owner, uint32_t interest) {
    (void)loop;
    (void)fd;
    (void)owner;
    (void)interest;
    return JZX_ERR_UNKNOWN;
}
