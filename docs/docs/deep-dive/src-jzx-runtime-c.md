---
title: Runtime core — src/jzx_runtime.c
sidebar_position: 6
---

# Runtime core — `src/jzx_runtime.c`

This is the primary implementation of the libjzx runtime: actors, mailboxes, scheduling, supervision, timers, and I/O watcher integration.

## Full source (with line numbers)

```c title="src/jzx_runtime.c" showLineNumbers
#include "jzx_internal.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

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

static jzx_supervisor_state* jzx_supervisor_state_create(const jzx_supervisor_init* init,
                                                         jzx_allocator* allocator) {
    if (!init || init->child_count == 0 || !init->children) {
        return NULL;
    }
    jzx_supervisor_state* state =
        (jzx_supervisor_state*)jzx_alloc(allocator, sizeof(jzx_supervisor_state));
    if (!state) {
        return NULL;
    }
    memset(state, 0, sizeof(*state));
    state->config = init->supervisor;
    state->child_count = init->child_count;
    size_t bytes = sizeof(jzx_child_state) * init->child_count;
    state->children = (jzx_child_state*)jzx_alloc(allocator, bytes);
    if (!state->children) {
        jzx_free(allocator, state);
        return NULL;
    }
    memset(state->children, 0, bytes);
    for (size_t i = 0; i < init->child_count; ++i) {
        state->children[i].spec = init->children[i];
        state->children[i].id = 0;
        state->children[i].restart_count = 0;
        state->children[i].last_restart_ms = 0;
    }
    state->intensity_window_count = 0;
    state->intensity_window_start_ms = 0;
    return state;
}

static void jzx_supervisor_state_destroy(jzx_supervisor_state* state, jzx_allocator* allocator) {
    if (!state)
        return;
    if (state->children) {
        jzx_free(allocator, state->children);
    }
    jzx_free(allocator, state);
}

static int jzx_supervisor_allow_restart(jzx_supervisor_state* sup, uint64_t now_ms) {
    if (!sup)
        return 0;
    if (sup->config.intensity == 0 || sup->config.period_ms == 0) {
        return 1;
    }
    if (sup->intensity_window_start_ms == 0 ||
        now_ms - sup->intensity_window_start_ms > sup->config.period_ms) {
        sup->intensity_window_start_ms = now_ms;
        sup->intensity_window_count = 0;
    }
    sup->intensity_window_count += 1;
    if (sup->intensity_window_count > sup->config.intensity) {
        return 0;
    }
    return 1;
}

static uint64_t jzx_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

static uint32_t jzx_sat_add32(uint32_t a, uint32_t b) {
    uint64_t sum = (uint64_t)a + (uint64_t)b;
    if (sum > UINT32_MAX) {
        return UINT32_MAX;
    }
    return (uint32_t)sum;
}

static uint32_t jzx_sat_mul32(uint32_t a, uint32_t b) {
    if (a == 0 || b == 0)
        return 0;
    uint64_t prod = (uint64_t)a * (uint64_t)b;
    if (prod > UINT32_MAX) {
        return UINT32_MAX;
    }
    return (uint32_t)prod;
}

static jzx_err jzx_send_internal(jzx_loop* loop, jzx_actor_id target, void* data, size_t len,
                                 uint32_t tag, jzx_actor_id sender);

static void jzx_io_remove_actor(jzx_loop* loop, jzx_actor_id actor);

// -----------------------------------------------------------------------------
// Wakeup helpers
// -----------------------------------------------------------------------------

static void jzx_wakeup_signal(jzx_loop* loop) {
    if (!loop || !loop->xev) {
        return;
    }
    jzx_xev_wakeup(loop->xev);
}

// -----------------------------------------------------------------------------
// Observer helpers
// -----------------------------------------------------------------------------

static void jzx_obs_actor_start(jzx_loop* loop, jzx_actor_id id, const char* name) {
    if (loop && loop->observer.on_actor_start) {
        loop->observer.on_actor_start(loop->observer_ctx, id, name);
    }
}

static void jzx_obs_actor_stop(jzx_loop* loop, jzx_actor_id id, jzx_exit_reason reason) {
    if (loop && loop->observer.on_actor_stop) {
        loop->observer.on_actor_stop(loop->observer_ctx, id, reason);
    }
}

static void jzx_obs_actor_restart(jzx_loop* loop, jzx_actor_id supervisor, jzx_actor_id child,
                                  uint32_t attempt) {
    if (loop && loop->observer.on_actor_restart) {
        loop->observer.on_actor_restart(loop->observer_ctx, supervisor, child, attempt);
    }
}

static void jzx_obs_supervisor_escalate(jzx_loop* loop, jzx_actor_id supervisor) {
    if (loop && loop->observer.on_supervisor_escalate) {
        loop->observer.on_supervisor_escalate(loop->observer_ctx, supervisor);
    }
}

static void jzx_obs_mailbox_full(jzx_loop* loop, jzx_actor_id target) {
    if (loop && loop->observer.on_mailbox_full) {
        loop->observer.on_mailbox_full(loop->observer_ctx, target);
    }
}

// -----------------------------------------------------------------------------
// Mailbox implementation
// -----------------------------------------------------------------------------

static jzx_err jzx_mailbox_init(jzx_mailbox_impl* box, uint32_t capacity,
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

static jzx_err jzx_actor_table_init(jzx_actor_table* table, uint32_t capacity,
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

static jzx_err jzx_actor_table_insert(jzx_actor_table* table, jzx_actor* actor,
                                      jzx_allocator* allocator, jzx_actor_id* out_id) {
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

static void jzx_actor_table_remove(jzx_actor_table* table, jzx_actor* actor) {
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

static jzx_err jzx_run_queue_init(jzx_run_queue* rq, uint32_t capacity, jzx_allocator* allocator) {
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
    jzx_io_remove_actor(loop, actor->id);
    jzx_exit_reason reason = JZX_EXIT_NORMAL;
    if (actor->status == JZX_ACTOR_FAILED) {
        reason = JZX_EXIT_FAIL;
    }
    jzx_obs_actor_stop(loop, actor->id, reason);
    if (actor->supervisor) {
        jzx_child_exit* ev = (jzx_child_exit*)jzx_alloc(&loop->allocator, sizeof(jzx_child_exit));
        if (ev) {
            ev->child = actor->id;
            ev->status = actor->status;
            jzx_err err = jzx_send_internal(loop, actor->supervisor, ev, sizeof(jzx_child_exit),
                                            JZX_TAG_SYS_CHILD_EXIT, 0);
            if (err != JZX_OK) {
                jzx_free(&loop->allocator, ev);
            }
        }
    }
    jzx_mailbox_deinit(&actor->mailbox, &loop->allocator);
    jzx_actor_table_remove(&loop->actors, actor);
    if (actor->supervisor_state) {
        jzx_supervisor_state_destroy(actor->supervisor_state, &loop->allocator);
    }
    jzx_free(&loop->allocator, actor);
}

// -----------------------------------------------------------------------------
// Supervisor helpers
// -----------------------------------------------------------------------------

static jzx_child_state* jzx_supervisor_find_child(jzx_supervisor_state* sup, jzx_actor_id id,
                                                  size_t* out_idx) {
    if (!sup)
        return NULL;
    for (size_t i = 0; i < sup->child_count; ++i) {
        if (sup->children[i].id == id) {
            if (out_idx) {
                *out_idx = i;
            }
            return &sup->children[i];
        }
    }
    return NULL;
}

static jzx_err jzx_supervisor_spawn_child(jzx_loop* loop, jzx_actor_id supervisor_id,
                                          jzx_child_state* child) {
    jzx_spawn_opts opts = {
        .behavior = child->spec.behavior,
        .state = child->spec.state,
        .supervisor = supervisor_id,
        .mailbox_cap = child->spec.mailbox_cap,
        .name = child->spec.name,
    };
    child->last_restart_ms = jzx_now_ms();
    return jzx_spawn(loop, &opts, &child->id);
}

static void jzx_supervisor_stop_child(jzx_loop* loop, jzx_child_state* child) {
    if (child->id != 0) {
        (void)jzx_actor_stop(loop, child->id);
        child->id = 0;
    }
}

static void jzx_supervisor_schedule_restart(jzx_loop* loop, jzx_actor* sup_actor, size_t child_idx,
                                            uint32_t delay_ms) {
    jzx_supervisor_state* sup = sup_actor->supervisor_state;
    if (!sup || child_idx >= sup->child_count)
        return;
    if (delay_ms == 0) {
        (void)jzx_supervisor_spawn_child(loop, sup_actor->id, &sup->children[child_idx]);
        return;
    }
    jzx_child_restart* payload =
        (jzx_child_restart*)jzx_alloc(&loop->allocator, sizeof(jzx_child_restart));
    if (!payload)
        return;
    payload->child_index = (uint32_t)child_idx;
    jzx_err err = jzx_send_after(loop, sup_actor->id, delay_ms, payload, sizeof(jzx_child_restart),
                                 JZX_TAG_SYS_CHILD_RESTART, NULL);
    if (err != JZX_OK) {
        jzx_free(&loop->allocator, payload);
    }
}

static uint32_t jzx_supervisor_compute_delay(const jzx_supervisor_state* sup,
                                             const jzx_child_state* child) {
    if (!sup || !child)
        return 0;
    uint32_t base = child->spec.restart_delay_ms;
    jzx_backoff_type strategy = child->spec.backoff;
    if (strategy == JZX_BACKOFF_NONE) {
        strategy = sup->config.backoff;
    }
    uint32_t step = sup->config.backoff_delay_ms;
    switch (strategy) {
    case JZX_BACKOFF_NONE:
        return base;
    case JZX_BACKOFF_CONSTANT: {
        uint32_t extra = jzx_sat_mul32(step, child->restart_count);
        return jzx_sat_add32(base, extra);
    }
    case JZX_BACKOFF_EXPONENTIAL: {
        uint32_t factor = 1u;
        uint32_t shifts = child->restart_count;
        if (shifts >= 31) {
            factor = UINT32_MAX;
        } else {
            factor = 1u << shifts;
        }
        uint32_t scaled_base = jzx_sat_mul32(base ? base : step, factor);
        return scaled_base;
    }
    }
    return base;
}

static void jzx_supervisor_restart_strategy(jzx_loop* loop, jzx_actor* supervisor_actor,
                                            size_t failed_idx, jzx_actor_id failed_child_id,
                                            jzx_supervisor_state* sup) {
    uint32_t failed_delay = sup->children[failed_idx].spec.restart_delay_ms;
    switch (sup->config.strategy) {
    case JZX_SUP_ONE_FOR_ONE:
        if (failed_child_id) {
            uint32_t attempt = sup->children[failed_idx].restart_count + 1;
            jzx_obs_actor_restart(loop, supervisor_actor->id, failed_child_id, attempt);
        }
        sup->children[failed_idx].restart_count += 1;
        sup->children[failed_idx].last_restart_ms = jzx_now_ms();
        failed_delay = jzx_supervisor_compute_delay(sup, &sup->children[failed_idx]);
        jzx_supervisor_schedule_restart(loop, supervisor_actor, failed_idx, failed_delay);
        break;
    case JZX_SUP_ONE_FOR_ALL:
        for (size_t i = 0; i < sup->child_count; ++i) {
            jzx_actor_id child_id = sup->children[i].id;
            if (i == failed_idx) {
                child_id = failed_child_id;
            }
            if (child_id) {
                uint32_t attempt = sup->children[i].restart_count + 1;
                jzx_obs_actor_restart(loop, supervisor_actor->id, child_id, attempt);
            }
        }
        for (size_t i = 0; i < sup->child_count; ++i) {
            jzx_supervisor_stop_child(loop, &sup->children[i]);
        }
        for (size_t i = 0; i < sup->child_count; ++i) {
            sup->children[i].restart_count += 1;
            sup->children[i].last_restart_ms = jzx_now_ms();
            uint32_t delay = jzx_supervisor_compute_delay(sup, &sup->children[i]);
            jzx_supervisor_schedule_restart(loop, supervisor_actor, i, delay);
        }
        break;
    case JZX_SUP_REST_FOR_ONE:
        for (size_t i = failed_idx; i < sup->child_count; ++i) {
            jzx_actor_id child_id = sup->children[i].id;
            if (i == failed_idx) {
                child_id = failed_child_id;
            }
            if (child_id) {
                uint32_t attempt = sup->children[i].restart_count + 1;
                jzx_obs_actor_restart(loop, supervisor_actor->id, child_id, attempt);
            }
        }
        for (size_t i = failed_idx; i < sup->child_count; ++i) {
            jzx_supervisor_stop_child(loop, &sup->children[i]);
        }
        for (size_t i = failed_idx; i < sup->child_count; ++i) {
            sup->children[i].restart_count += 1;
            sup->children[i].last_restart_ms = jzx_now_ms();
            uint32_t delay = jzx_supervisor_compute_delay(sup, &sup->children[i]);
            jzx_supervisor_schedule_restart(loop, supervisor_actor, i, delay);
        }
        break;
    }
}

static jzx_behavior_result jzx_supervisor_behavior(jzx_context* ctx, const jzx_message* msg) {
    jzx_actor* sup_actor = jzx_actor_table_lookup(&ctx->loop->actors, ctx->self);
    if (!sup_actor || !sup_actor->supervisor_state) {
        if (msg->data) {
            jzx_free(&ctx->loop->allocator, msg->data);
        }
        return JZX_BEHAVIOR_OK;
    }
    jzx_supervisor_state* sup = sup_actor->supervisor_state;
    if (msg->tag == JZX_TAG_SYS_CHILD_EXIT && msg->data) {
        jzx_child_exit* ev = (jzx_child_exit*)msg->data;
        jzx_actor_id failed_child_id = ev->child;
        size_t idx = 0;
        jzx_child_state* child = jzx_supervisor_find_child(sup, ev->child, &idx);
        jzx_actor_status status = ev->status;
        jzx_free(&ctx->loop->allocator, ev);
        if (!child) {
            return JZX_BEHAVIOR_OK;
        }
        child->id = 0;

        int restart = 0;
        if (child->spec.mode == JZX_CHILD_PERMANENT) {
            restart = 1;
        } else if (child->spec.mode == JZX_CHILD_TRANSIENT && status == JZX_ACTOR_FAILED) {
            restart = 1;
        }

        if (!restart) {
            return JZX_BEHAVIOR_OK;
        }

        uint64_t now = jzx_now_ms();
        if (!jzx_supervisor_allow_restart(sup, now)) {
            jzx_obs_supervisor_escalate(ctx->loop, ctx->self);
            for (size_t i = 0; i < sup->child_count; ++i) {
                jzx_supervisor_stop_child(ctx->loop, &sup->children[i]);
            }
            sup_actor->status = JZX_ACTOR_FAILED;
            return JZX_BEHAVIOR_FAIL;
        }

        jzx_supervisor_restart_strategy(ctx->loop, sup_actor, idx, failed_child_id, sup);
        return JZX_BEHAVIOR_OK;
    }

    if (msg->tag == JZX_TAG_SYS_CHILD_RESTART && msg->data) {
        jzx_child_restart* ev = (jzx_child_restart*)msg->data;
        uint32_t idx = ev->child_index;
        jzx_free(&ctx->loop->allocator, ev);
        if (idx < sup->child_count) {
            (void)jzx_supervisor_spawn_child(ctx->loop, ctx->self, &sup->children[idx]);
        }
        return JZX_BEHAVIOR_OK;
    }

    if (msg->data) {
        jzx_free(&ctx->loop->allocator, msg->data);
    }
    return JZX_BEHAVIOR_OK;
}

// -----------------------------------------------------------------------------
// Async queue
// -----------------------------------------------------------------------------

static jzx_err jzx_async_queue_init(jzx_loop* loop) {
    if (pthread_mutex_init(&loop->async_mutex, NULL) != 0) {
        return JZX_ERR_UNKNOWN;
    }
    loop->async_mutex_initialized = 1;
    loop->async_head = NULL;
    loop->async_tail = NULL;
    return JZX_OK;
}

static void jzx_async_queue_destroy(jzx_loop* loop) {
    if (!loop->async_mutex_initialized) {
        return;
    }
    pthread_mutex_lock(&loop->async_mutex);
    jzx_async_msg* head = loop->async_head;
    loop->async_head = NULL;
    loop->async_tail = NULL;
    pthread_mutex_unlock(&loop->async_mutex);
    pthread_mutex_destroy(&loop->async_mutex);
    loop->async_mutex_initialized = 0;
    while (head) {
        jzx_async_msg* next = head->next;
        jzx_free(&loop->allocator, head);
        head = next;
    }
}

static jzx_err jzx_async_enqueue(jzx_loop* loop, jzx_actor_id target, void* data, size_t len,
                                 uint32_t tag, jzx_actor_id sender) {
    if (!loop || !loop->async_mutex_initialized) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_async_msg* msg = (jzx_async_msg*)jzx_alloc(&loop->allocator, sizeof(jzx_async_msg));
    if (!msg) {
        return JZX_ERR_NO_MEMORY;
    }
    msg->target = target;
    msg->data = data;
    msg->len = len;
    msg->tag = tag;
    msg->sender = sender;
    msg->next = NULL;

    pthread_mutex_lock(&loop->async_mutex);
    if (!loop->async_head) {
        loop->async_head = msg;
        loop->async_tail = msg;
    } else {
        loop->async_tail->next = msg;
        loop->async_tail = msg;
    }
    pthread_mutex_unlock(&loop->async_mutex);
    jzx_wakeup_signal(loop);
    return JZX_OK;
}

static jzx_async_msg* jzx_async_detach(jzx_loop* loop) {
    if (!loop->async_mutex_initialized) {
        return NULL;
    }
    pthread_mutex_lock(&loop->async_mutex);
    jzx_async_msg* head = loop->async_head;
    loop->async_head = NULL;
    loop->async_tail = NULL;
    pthread_mutex_unlock(&loop->async_mutex);
    return head;
}

static void jzx_async_dispatch(jzx_loop* loop, jzx_async_msg* head) {
    jzx_async_msg* msg = head;
    while (msg) {
        jzx_async_msg* next = msg->next;
        (void)jzx_send_internal(loop, msg->target, msg->data, msg->len, msg->tag, msg->sender);
        jzx_free(&loop->allocator, msg);
        msg = next;
    }
}

static void jzx_async_drain(jzx_loop* loop) {
    jzx_async_msg* head = jzx_async_detach(loop);
    if (head) {
        jzx_async_dispatch(loop, head);
    }
}

static int jzx_async_has_pending(jzx_loop* loop) {
    if (!loop->async_mutex_initialized) {
        return 0;
    }
    pthread_mutex_lock(&loop->async_mutex);
    int has = loop->async_head != NULL;
    pthread_mutex_unlock(&loop->async_mutex);
    return has;
}

// -----------------------------------------------------------------------------
// Timer system
// -----------------------------------------------------------------------------

static void jzx_timer_insert_locked(jzx_loop* loop, jzx_timer_entry* entry) {
    if (!loop->timer_head || entry->due_ms < loop->timer_head->due_ms) {
        entry->next = loop->timer_head;
        loop->timer_head = entry;
        return;
    }
    jzx_timer_entry* cur = loop->timer_head;
    while (cur->next && cur->next->due_ms <= entry->due_ms) {
        cur = cur->next;
    }
    entry->next = cur->next;
    cur->next = entry;
}

static void* jzx_timer_thread_main(void* arg) {
    jzx_loop* loop = (jzx_loop*)arg;
    pthread_mutex_lock(&loop->timer_mutex);
    while (!loop->timer_stop) {
        uint64_t now = jzx_now_ms();
        jzx_timer_entry* head = loop->timer_head;
        if (!head) {
            pthread_cond_wait(&loop->timer_cond, &loop->timer_mutex);
            continue;
        }
        if (head->due_ms > now) {
            uint64_t wait_ms = head->due_ms - now;
#if defined(__APPLE__)
            struct timespec rel;
            rel.tv_sec = (time_t)(wait_ms / 1000ull);
            rel.tv_nsec = (long)((wait_ms % 1000ull) * 1000000ull);
            (void)pthread_cond_timedwait_relative_np(&loop->timer_cond, &loop->timer_mutex, &rel);
#else
            struct timespec ts;
#if defined(__linux__)
            clockid_t clock_id = loop->timer_cond_monotonic ? CLOCK_MONOTONIC : CLOCK_REALTIME;
            clock_gettime(clock_id, &ts);
#else
            clock_gettime(CLOCK_REALTIME, &ts);
#endif
            ts.tv_sec += (time_t)(wait_ms / 1000ull);
            ts.tv_nsec += (long)((wait_ms % 1000ull) * 1000000ull);
            if (ts.tv_nsec >= 1000000000l) {
                ts.tv_sec += 1;
                ts.tv_nsec -= 1000000000l;
            }
            (void)pthread_cond_timedwait(&loop->timer_cond, &loop->timer_mutex, &ts);
#endif
            continue;
        }
        loop->timer_head = head->next;
        pthread_mutex_unlock(&loop->timer_mutex);
        jzx_async_enqueue(loop, head->target, head->data, head->len, head->tag, 0);
        jzx_free(&loop->allocator, head);
        pthread_mutex_lock(&loop->timer_mutex);
    }
    pthread_mutex_unlock(&loop->timer_mutex);
    return NULL;
}

static jzx_err jzx_timer_system_init(jzx_loop* loop) {
    if (pthread_mutex_init(&loop->timer_mutex, NULL) != 0) {
        return JZX_ERR_UNKNOWN;
    }
    loop->timer_cond_monotonic = 0;
#if defined(__linux__)
    pthread_condattr_t attr;
    pthread_condattr_t* attr_ptr = NULL;
    if (pthread_condattr_init(&attr) == 0) {
        attr_ptr = &attr;
        if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) == 0) {
            loop->timer_cond_monotonic = 1;
        }
    }
    int cond_rc = pthread_cond_init(&loop->timer_cond, attr_ptr);
    if (attr_ptr) {
        pthread_condattr_destroy(&attr);
    }
    if (cond_rc != 0) {
        pthread_mutex_destroy(&loop->timer_mutex);
        return JZX_ERR_UNKNOWN;
    }
#else
    if (pthread_cond_init(&loop->timer_cond, NULL) != 0) {
        pthread_mutex_destroy(&loop->timer_mutex);
        return JZX_ERR_UNKNOWN;
    }
#endif
    loop->timer_mutex_initialized = 1;
    loop->timer_thread_running = 0;
    loop->timer_stop = 0;
    loop->timer_head = NULL;
    loop->next_timer_id = 1;
    if (pthread_create(&loop->timer_thread, NULL, jzx_timer_thread_main, loop) != 0) {
        pthread_cond_destroy(&loop->timer_cond);
        pthread_mutex_destroy(&loop->timer_mutex);
        loop->timer_mutex_initialized = 0;
        return JZX_ERR_UNKNOWN;
    }
    loop->timer_thread_running = 1;
    return JZX_OK;
}

static void jzx_timer_system_shutdown(jzx_loop* loop) {
    if (!loop->timer_mutex_initialized) {
        return;
    }
    pthread_mutex_lock(&loop->timer_mutex);
    loop->timer_stop = 1;
    pthread_cond_broadcast(&loop->timer_cond);
    pthread_mutex_unlock(&loop->timer_mutex);

    if (loop->timer_thread_running) {
        pthread_join(loop->timer_thread, NULL);
        loop->timer_thread_running = 0;
    }

    pthread_mutex_lock(&loop->timer_mutex);
    jzx_timer_entry* cur = loop->timer_head;
    loop->timer_head = NULL;
    pthread_mutex_unlock(&loop->timer_mutex);

    while (cur) {
        jzx_timer_entry* next = cur->next;
        jzx_free(&loop->allocator, cur);
        cur = next;
    }

    pthread_cond_destroy(&loop->timer_cond);
    pthread_mutex_destroy(&loop->timer_mutex);
    loop->timer_mutex_initialized = 0;
}

static int jzx_timer_has_pending(jzx_loop* loop) {
    if (!loop->timer_mutex_initialized) {
        return 0;
    }
    pthread_mutex_lock(&loop->timer_mutex);
    int has = loop->timer_head != NULL;
    pthread_mutex_unlock(&loop->timer_mutex);
    return has;
}

// -----------------------------------------------------------------------------
// I O watchers
// -----------------------------------------------------------------------------

static jzx_err jzx_io_init(jzx_loop* loop, uint32_t capacity) {
    loop->io_capacity = capacity ? capacity : 1;
    loop->io_count = 0;
    loop->io_watchers =
        (jzx_io_watch*)jzx_alloc(&loop->allocator, sizeof(jzx_io_watch) * loop->io_capacity);
    if (!loop->io_watchers) {
        return JZX_ERR_NO_MEMORY;
    }
    memset(loop->io_watchers, 0, sizeof(jzx_io_watch) * loop->io_capacity);
    return JZX_OK;
}

static void jzx_io_deinit(jzx_loop* loop) {
    if (loop->io_watchers) {
        jzx_free(&loop->allocator, loop->io_watchers);
        loop->io_watchers = NULL;
    }
    loop->io_capacity = 0;
    loop->io_count = 0;
}

static jzx_err jzx_io_reserve(jzx_loop* loop, uint32_t new_cap) {
    jzx_io_watch* new_watchers =
        (jzx_io_watch*)jzx_alloc(&loop->allocator, sizeof(jzx_io_watch) * new_cap);
    if (!new_watchers) {
        return JZX_ERR_NO_MEMORY;
    }
    memset(new_watchers, 0, sizeof(jzx_io_watch) * new_cap);
    if (loop->io_watchers) {
        memcpy(new_watchers, loop->io_watchers, sizeof(jzx_io_watch) * loop->io_count);
        jzx_free(&loop->allocator, loop->io_watchers);
    }
    loop->io_watchers = new_watchers;
    loop->io_capacity = new_cap;
    return JZX_OK;
}

static jzx_io_watch* jzx_io_find(jzx_loop* loop, int fd, uint32_t* idx_out) {
    for (uint32_t i = 0; i < loop->io_count; ++i) {
        if (loop->io_watchers[i].fd == fd) {
            if (idx_out) {
                *idx_out = i;
            }
            return &loop->io_watchers[i];
        }
    }
    return NULL;
}

static void jzx_io_remove_index(jzx_loop* loop, uint32_t idx) {
    if (idx >= loop->io_count) {
        return;
    }
    if (loop->xev) {
        jzx_xev_unwatch_fd(loop->xev, loop->io_watchers[idx].fd);
    }
    uint32_t last = loop->io_count - 1;
    if (idx != last) {
        loop->io_watchers[idx] = loop->io_watchers[last];
    }
    loop->io_count--;
}

static void jzx_io_remove_actor(jzx_loop* loop, jzx_actor_id actor) {
    for (uint32_t i = 0; i < loop->io_count;) {
        if (loop->io_watchers[i].owner == actor) {
            jzx_io_remove_index(loop, i);
            continue;
        }
        ++i;
    }
}

uint8_t jzx_io_xev_notify(jzx_loop* loop, int fd, uint32_t readiness) {
    if (!loop || !loop->running || fd < 0 || readiness == 0) {
        return 0;
    }

    uint32_t idx = 0;
    jzx_io_watch* watch = jzx_io_find(loop, fd, &idx);
    if (!watch) {
        return 0;
    }
    if (!jzx_actor_table_lookup(&loop->actors, watch->owner)) {
        jzx_io_remove_index(loop, idx);
        return 0;
    }

    jzx_io_event* ev = (jzx_io_event*)jzx_alloc(&loop->allocator, sizeof(jzx_io_event));
    if (!ev) {
        return 1;
    }
    ev->fd = fd;
    ev->readiness = readiness;
    jzx_err err =
        jzx_send_internal(loop, watch->owner, ev, sizeof(jzx_io_event), JZX_TAG_SYS_IO, 0);
    if (err != JZX_OK) {
        jzx_free(&loop->allocator, ev);
    }
    return 1;
}

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
    cfg->max_io_watchers = 1024;
    cfg->io_poll_timeout_ms = 10;
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
    if (cfg->max_io_watchers == 0) {
        cfg->max_io_watchers = 1024;
    }
    if (cfg->io_poll_timeout_ms == 0) {
        cfg->io_poll_timeout_ms = 10;
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
    loop->xev = jzx_xev_create();
    if (!loop->xev) {
        jzx_loop_destroy(loop);
        return NULL;
    }

    if (jzx_actor_table_init(&loop->actors, local.max_actors, &loop->allocator) != JZX_OK) {
        jzx_loop_destroy(loop);
        return NULL;
    }
    if (jzx_run_queue_init(&loop->run_queue, local.max_actors, &loop->allocator) != JZX_OK) {
        jzx_loop_destroy(loop);
        return NULL;
    }
    if (jzx_async_queue_init(loop) != JZX_OK) {
        jzx_loop_destroy(loop);
        return NULL;
    }
    if (jzx_timer_system_init(loop) != JZX_OK) {
        jzx_loop_destroy(loop);
        return NULL;
    }
    if (jzx_io_init(loop, local.max_io_watchers) != JZX_OK) {
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
    jzx_timer_system_shutdown(loop);
    jzx_async_queue_destroy(loop);
    if (loop->xev) {
        jzx_xev_destroy(loop->xev);
        loop->xev = NULL;
    }
    jzx_io_deinit(loop);
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
        jzx_async_drain(loop);
        jzx_xev_run(loop->xev, 0);
        uint32_t actors_processed = 0;
        while (actors_processed < loop->cfg.max_actors_per_tick) {
            jzx_actor* actor = jzx_run_queue_pop(&loop->run_queue);
            if (!actor) {
                break;
            }
            actor->in_run_queue = 0;
            if (actor->status == JZX_ACTOR_STOPPING || actor->status == JZX_ACTOR_FAILED) {
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
                    actor->status = JZX_ACTOR_STOPPING;
                    break;
                } else if (result == JZX_BEHAVIOR_FAIL) {
                    actor->status = JZX_ACTOR_FAILED;
                    break;
                }
            }
            if (actor->status == JZX_ACTOR_STOPPING || actor->status == JZX_ACTOR_FAILED) {
                jzx_teardown_actor(loop, actor);
            } else if (jzx_mailbox_has_items(&actor->mailbox)) {
                jzx_schedule_actor(loop, actor);
            }
            actors_processed++;
        }

        if (loop->run_queue.count == 0) {
            if (loop->actors.used == 0 && !jzx_async_has_pending(loop) &&
                !jzx_timer_has_pending(loop) && loop->io_count == 0) {
                for (uint32_t i = 0; i < 64; ++i) {
                    jzx_xev_run(loop->xev, 0);
                }
                break;
            }
            if (jzx_async_has_pending(loop)) {
                continue;
            }
            jzx_xev_run(loop->xev, 1);
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
    jzx_wakeup_signal(loop);
    if (loop->timer_mutex_initialized) {
        pthread_mutex_lock(&loop->timer_mutex);
        pthread_cond_broadcast(&loop->timer_cond);
        pthread_mutex_unlock(&loop->timer_mutex);
    }
}

void jzx_loop_free(jzx_loop* loop, void* ptr) {
    if (!loop || !ptr) {
        return;
    }
    jzx_free(&loop->allocator, ptr);
}

void jzx_loop_set_observer(jzx_loop* loop, const jzx_observer* obs, void* ctx) {
    if (!loop) {
        return;
    }
    if (obs) {
        loop->observer = *obs;
        loop->observer_ctx = ctx;
    } else {
        memset(&loop->observer, 0, sizeof(loop->observer));
        loop->observer_ctx = NULL;
    }
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
    actor->status = JZX_ACTOR_RUNNING;
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
    jzx_obs_actor_start(loop, actor->id, opts->name);
    return JZX_OK;
}

static jzx_err jzx_send_internal(jzx_loop* loop, jzx_actor_id target, void* data, size_t len,
                                 uint32_t tag, jzx_actor_id sender) {
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
        jzx_obs_mailbox_full(loop, target);
        return JZX_ERR_MAILBOX_FULL;
    }
    jzx_schedule_actor(loop, actor);
    return JZX_OK;
}

jzx_err jzx_send(jzx_loop* loop, jzx_actor_id target, void* data, size_t len, uint32_t tag) {
    return jzx_send_internal(loop, target, data, len, tag, 0);
}

jzx_err jzx_send_async(jzx_loop* loop, jzx_actor_id target, void* data, size_t len, uint32_t tag) {
    return jzx_async_enqueue(loop, target, data, len, tag, 0);
}

jzx_err jzx_actor_stop(jzx_loop* loop, jzx_actor_id id) {
    if (!loop) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_actor* actor = jzx_actor_table_lookup(&loop->actors, id);
    if (!actor) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    actor->status = JZX_ACTOR_STOPPING;
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
    actor->status = JZX_ACTOR_FAILED;
    jzx_schedule_actor(loop, actor);
    return JZX_OK;
}

// -----------------------------------------------------------------------------
// Supervisor spawn
// -----------------------------------------------------------------------------

jzx_err jzx_spawn_supervisor(jzx_loop* loop, const jzx_supervisor_init* init, jzx_actor_id parent,
                             jzx_actor_id* out_id) {
    if (!loop || !init || !init->children || init->child_count == 0) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_supervisor_state* state = jzx_supervisor_state_create(init, &loop->allocator);
    if (!state) {
        return JZX_ERR_NO_MEMORY;
    }
    jzx_spawn_opts opts = {
        .behavior = jzx_supervisor_behavior,
        .state = state,
        .supervisor = parent,
        .mailbox_cap = 0,
        .name = NULL,
    };
    jzx_actor_id sup_id = 0;
    jzx_err err = jzx_spawn(loop, &opts, &sup_id);
    if (err != JZX_OK) {
        jzx_supervisor_state_destroy(state, &loop->allocator);
        return err;
    }
    jzx_actor* sup_actor = jzx_actor_table_lookup(&loop->actors, sup_id);
    if (!sup_actor) {
        jzx_supervisor_state_destroy(state, &loop->allocator);
        return JZX_ERR_UNKNOWN;
    }
    sup_actor->supervisor_state = state;

    for (size_t i = 0; i < state->child_count; ++i) {
        err = jzx_supervisor_spawn_child(loop, sup_id, &state->children[i]);
        if (err != JZX_OK) {
            (void)jzx_actor_fail(loop, sup_id);
            return err;
        }
    }

    if (out_id) {
        *out_id = sup_id;
    }
    return JZX_OK;
}

jzx_err jzx_supervisor_child_id(jzx_loop* loop, jzx_actor_id supervisor, size_t index,
                                jzx_actor_id* out_id) {
    if (!loop || !out_id) {
        return JZX_ERR_INVALID_ARG;
    }
    jzx_actor* sup_actor = jzx_actor_table_lookup(&loop->actors, supervisor);
    if (!sup_actor || !sup_actor->supervisor_state) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    if (index >= sup_actor->supervisor_state->child_count) {
        return JZX_ERR_INVALID_ARG;
    }
    *out_id = sup_actor->supervisor_state->children[index].id;
    return JZX_OK;
}

// -----------------------------------------------------------------------------
// Timers & IO
// -----------------------------------------------------------------------------

jzx_err jzx_send_after(jzx_loop* loop, jzx_actor_id target, uint32_t ms, void* data, size_t len,
                       uint32_t tag, jzx_timer_id* out_timer) {
    if (!loop) {
        return JZX_ERR_INVALID_ARG;
    }
    if (!jzx_actor_table_lookup(&loop->actors, target)) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    jzx_timer_entry* entry = (jzx_timer_entry*)jzx_alloc(&loop->allocator, sizeof(jzx_timer_entry));
    if (!entry) {
        return JZX_ERR_NO_MEMORY;
    }
    entry->target = target;
    entry->data = data;
    entry->len = len;
    entry->tag = tag;
    entry->next = NULL;

    pthread_mutex_lock(&loop->timer_mutex);
    entry->id = loop->next_timer_id++;
    entry->due_ms = jzx_now_ms() + (uint64_t)ms;
    jzx_timer_insert_locked(loop, entry);
    pthread_cond_broadcast(&loop->timer_cond);
    pthread_mutex_unlock(&loop->timer_mutex);

    if (out_timer) {
        *out_timer = entry->id;
    }
    return JZX_OK;
}

jzx_err jzx_cancel_timer(jzx_loop* loop, jzx_timer_id timer) {
    if (!loop || !loop->timer_mutex_initialized) {
        return JZX_ERR_INVALID_ARG;
    }
    pthread_mutex_lock(&loop->timer_mutex);
    jzx_timer_entry* prev = NULL;
    jzx_timer_entry* cur = loop->timer_head;
    while (cur) {
        if (cur->id == timer) {
            if (prev) {
                prev->next = cur->next;
            } else {
                loop->timer_head = cur->next;
            }
            pthread_mutex_unlock(&loop->timer_mutex);
            jzx_free(&loop->allocator, cur);
            return JZX_OK;
        }
        prev = cur;
        cur = cur->next;
    }
    pthread_mutex_unlock(&loop->timer_mutex);
    return JZX_ERR_TIMER_INVALID;
}

jzx_err jzx_watch_fd(jzx_loop* loop, int fd, jzx_actor_id owner, uint32_t interest) {
    if (!loop || !loop->xev || fd < 0 || interest == 0) {
        return JZX_ERR_INVALID_ARG;
    }
    if (!jzx_actor_table_lookup(&loop->actors, owner)) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    jzx_io_watch* existing = jzx_io_find(loop, fd, NULL);
    if (existing) {
        jzx_err err = jzx_xev_watch_fd(loop->xev, loop, fd, interest);
        if (err != JZX_OK) {
            return err;
        }
        existing->owner = owner;
        existing->interest = interest;
        return JZX_OK;
    }
    if (loop->io_count == loop->io_capacity) {
        jzx_err err = jzx_io_reserve(loop, loop->io_capacity * 2);
        if (err != JZX_OK) {
            return err;
        }
    }
    uint32_t idx = loop->io_count;
    loop->io_watchers[idx] = (jzx_io_watch){
        .fd = fd,
        .owner = owner,
        .interest = interest,
        .active = 1,
    };
    loop->io_count = idx + 1;
    jzx_err err = jzx_xev_watch_fd(loop->xev, loop, fd, interest);
    if (err != JZX_OK) {
        loop->io_count = idx;
        memset(&loop->io_watchers[idx], 0, sizeof(loop->io_watchers[idx]));
        return err;
    }
    return JZX_OK;
}

jzx_err jzx_unwatch_fd(jzx_loop* loop, int fd) {
    if (!loop || fd < 0) {
        return JZX_ERR_INVALID_ARG;
    }
    uint32_t idx = 0;
    jzx_io_watch* entry = jzx_io_find(loop, fd, &idx);
    if (!entry) {
        return JZX_ERR_IO_NOT_WATCHED;
    }
    jzx_io_remove_index(loop, idx);
    return JZX_OK;
}
```

## High-level map (sections and purpose)

The file is organized with explicit section headers (search for `// ---` blocks). In order:

- **Utility helpers**: id encoding, allocation wrappers, time helpers, saturating math.
- **Wakeup helpers**: wake the event loop when cross-thread work arrives.
- **Observer helpers**: call user-installed hooks for lifecycle, supervision, and mailbox pressure.
- **Mailbox implementation**: per-actor ring-buffer queue (`jzx_mailbox_impl`).
- **Actor table implementation**: id → actor mapping with generation counters (stale id rejection).
- **Run queue implementation**: queue of runnable actors; used for fairness and tick budgeting.
- **Supervisor helpers**: supervisor state, restart strategies, intensity limits, and backoff timing.
- **Async queue**: cross-thread send queue (`jzx_send_async`) and drain logic.
- **Timer system**: timer thread, due-time list, and message delivery.
- **I/O watchers**: fd watch table + glue to xev backend.
- **Config helpers**: default config initialization.
- **Loop lifecycle**: create/destroy/run/stop.
- **Actor APIs**: spawn/send/stop/fail.
- **Supervisor spawn**: supervisor creation + child management.
- **Timers & IO**: public timer and I/O entry points.

### Section boundaries (by line)

| Lines | Section | What’s inside |
| ---: | --- | --- |
| 1–119 | Utility helpers | id encoding, alloc wrappers, time helpers, saturating math, forward decls |
| 120–130 | Wakeup helpers | wake event loop when async work arrives |
| 131–165 | Observer helpers | lifecycle + supervision + mailbox pressure callbacks |
| 166–220 | Mailbox implementation | `jzx_mailbox_impl` ring buffer helpers |
| 221–312 | Actor table implementation | `jzx_actor_id` lookup/insert/remove with generations |
| 313–394 | Run queue implementation | runnable actor queue + scheduling helper |
| 395–608 | Supervisor helpers | child state, restart strategies, intensity and backoff |
| 609–708 | Async queue | cross-thread `send_async` enqueue + drain |
| 709–854 | Timer system | timer thread + due list + wakeups |
| 855–960 | I/O watchers | watch table + xev integration glue |
| 961–1017 | Config helpers | `jzx_config_init` defaults |
| 1018–1197 | Loop lifecycle | `create/destroy/run/stop` |
| 1198–1295 | Actor APIs | spawn, send, stop, fail |
| 1296–1358 | Supervisor spawn | supervisor actor spawn + child lookup |
| 1359–1469 | Timers & IO | public timer + fd APIs |

## Core invariants (critical for understanding “why”)

### Actor ids are (generation, index)

The runtime encodes `jzx_actor_id` as:

- low 32 bits: table index
- high 32 bits: generation counter for that index

This means:

- When a slot is reused, its generation increments.
- Any stale id referencing a prior generation will fail lookup (`JZX_ERR_NO_SUCH_ACTOR`).

Why: this is a simple, fast defense against use-after-free of actor ids.

### Mailboxes are bounded (backpressure)

Each actor has a ring-buffer mailbox with a capacity. When full:

- `jzx_send` / `jzx_send_async` surface `JZX_ERR_MAILBOX_FULL` (or notify observer).

Why: bounded queues make overload visible and force callers to pick a policy.

### Scheduler fairness is explicit

The run loop uses:

- `max_msgs_per_actor` (per-actor work budget)
- `max_actors_per_tick` (global work budget per tick)

Why: prevents a single chatty actor from starving others and keeps tick latency bounded.

### Timers are driven by a separate thread

The timer system maintains a sorted linked list of due timers and uses a thread + condvar to wait for the next due time.

Why: avoids relying on the I/O backend for timer semantics and keeps timer wakeups independent of fd readiness.

### I/O watchers are a contract with the backend

The runtime tracks watchers and asks the xev backend to arm poll operations. On readiness, the backend calls back into C (`jzx_io_xev_notify`) which enqueues a system message to the owning actor.

Why: keeps the actor scheduler in control of message delivery while using xev for OS integration.

## Public entry points (what to read first)

If you’re starting from the ABI:

- `jzx_config_init`
- `jzx_loop_create` / `jzx_loop_run` / `jzx_loop_request_stop` / `jzx_loop_destroy`
- `jzx_spawn`
- `jzx_send` / `jzx_send_async`
- `jzx_send_after` / `jzx_cancel_timer`
- `jzx_watch_fd` / `jzx_unwatch_fd`

### Entry points (by line)

| API | Line | Notes |
| --- | ---: | --- |
| `jzx_config_init` | 974 | Fill defaults into `jzx_config` |
| `jzx_loop_create` | 1021 | Allocate/init `jzx_loop` |
| `jzx_loop_destroy` | 1068 | Shutdown and free loop |
| `jzx_loop_run` | 1092 | Run until stop/idle |
| `jzx_loop_request_stop` | 1164 | Cooperative stop |
| `jzx_loop_free` | 1177 | Free loop-owned allocations |
| `jzx_loop_set_observer` | 1184 | Install observer callbacks |
| `jzx_spawn` | 1220 | Spawn an actor |
| `jzx_send` | 1261 | Enqueue message (loop thread) |
| `jzx_send_async` | 1265 | Enqueue message (cross-thread) |
| `jzx_actor_stop` | 1269 | Stop actor (graceful) |
| `jzx_actor_fail` | 1282 | Fail actor (supervision) |
| `jzx_spawn_supervisor` | 1299 | Spawn supervisor + children |
| `jzx_supervisor_child_id` | 1342 | Map child index → actor id |
| `jzx_send_after` | 1362 | Schedule timer delivery |
| `jzx_cancel_timer` | 1393 | Cancel timer |
| `jzx_watch_fd` | 1418 | Register fd watch |
| `jzx_unwatch_fd` | 1458 | Unregister fd watch |
