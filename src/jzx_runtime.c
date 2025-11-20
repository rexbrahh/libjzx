#include "jzx_internal.h"

#include <poll.h>
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

static uint64_t jzx_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

static jzx_err jzx_send_internal(jzx_loop* loop,
                                 jzx_actor_id target,
                                 void* data,
                                 size_t len,
                                 uint32_t tag,
                                 jzx_actor_id sender);

static void jzx_io_remove_actor(jzx_loop* loop, jzx_actor_id actor);

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
    jzx_io_remove_actor(loop, actor->id);
    jzx_mailbox_deinit(&actor->mailbox, &loop->allocator);
    jzx_actor_table_remove(&loop->actors, actor);
    jzx_free(&loop->allocator, actor);
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

static jzx_err jzx_async_enqueue(jzx_loop* loop,
                                 jzx_actor_id target,
                                 void* data,
                                 size_t len,
                                 uint32_t tag,
                                 jzx_actor_id sender) {
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
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_sec += wait_ms / 1000ull;
            ts.tv_nsec += (wait_ms % 1000ull) * 1000000ull;
            if (ts.tv_nsec >= 1000000000ull) {
                ts.tv_sec += 1;
                ts.tv_nsec -= 1000000000ull;
            }
            pthread_cond_timedwait(&loop->timer_cond, &loop->timer_mutex, &ts);
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
    if (pthread_cond_init(&loop->timer_cond, NULL) != 0) {
        pthread_mutex_destroy(&loop->timer_mutex);
        return JZX_ERR_UNKNOWN;
    }
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
    loop->io_dirty = 1;
    loop->io_watchers = (jzx_io_watch*)jzx_alloc(&loop->allocator, sizeof(jzx_io_watch) * loop->io_capacity);
    if (!loop->io_watchers) {
        return JZX_ERR_NO_MEMORY;
    }
    memset(loop->io_watchers, 0, sizeof(jzx_io_watch) * loop->io_capacity);
    loop->io_pollfds = (struct pollfd*)jzx_alloc(&loop->allocator, sizeof(struct pollfd) * loop->io_capacity);
    if (!loop->io_pollfds) {
        return JZX_ERR_NO_MEMORY;
    }
    memset(loop->io_pollfds, 0, sizeof(struct pollfd) * loop->io_capacity);
    return JZX_OK;
}

static void jzx_io_deinit(jzx_loop* loop) {
    if (loop->io_watchers) {
        jzx_free(&loop->allocator, loop->io_watchers);
        loop->io_watchers = NULL;
    }
    if (loop->io_pollfds) {
        jzx_free(&loop->allocator, loop->io_pollfds);
        loop->io_pollfds = NULL;
    }
    loop->io_capacity = 0;
    loop->io_count = 0;
}

static jzx_err jzx_io_reserve(jzx_loop* loop, uint32_t new_cap) {
    jzx_io_watch* new_watchers = (jzx_io_watch*)jzx_alloc(&loop->allocator, sizeof(jzx_io_watch) * new_cap);
    if (!new_watchers) {
        return JZX_ERR_NO_MEMORY;
    }
    struct pollfd* new_pollfds = (struct pollfd*)jzx_alloc(&loop->allocator, sizeof(struct pollfd) * new_cap);
    if (!new_pollfds) {
        jzx_free(&loop->allocator, new_watchers);
        return JZX_ERR_NO_MEMORY;
    }
    memset(new_watchers, 0, sizeof(jzx_io_watch) * new_cap);
    memset(new_pollfds, 0, sizeof(struct pollfd) * new_cap);
    if (loop->io_watchers) {
        memcpy(new_watchers, loop->io_watchers, sizeof(jzx_io_watch) * loop->io_count);
        jzx_free(&loop->allocator, loop->io_watchers);
    }
    if (loop->io_pollfds) {
        memcpy(new_pollfds, loop->io_pollfds, sizeof(struct pollfd) * loop->io_count);
        jzx_free(&loop->allocator, loop->io_pollfds);
    }
    loop->io_watchers = new_watchers;
    loop->io_pollfds = new_pollfds;
    loop->io_capacity = new_cap;
    loop->io_dirty = 1;
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
    uint32_t last = loop->io_count - 1;
    if (idx != last) {
        loop->io_watchers[idx] = loop->io_watchers[last];
        loop->io_pollfds[idx] = loop->io_pollfds[last];
    }
    loop->io_count--;
    loop->io_dirty = 1;
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

static short jzx_io_interest_to_poll(uint32_t interest) {
    short mask = 0;
    if (interest & JZX_IO_READ) {
        mask |= POLLIN | POLLERR | POLLHUP | POLLNVAL;
    }
    if (interest & JZX_IO_WRITE) {
        mask |= POLLOUT | POLLERR | POLLHUP | POLLNVAL;
    }
    return mask;
}

static uint32_t jzx_io_revents_to_readiness(short revents) {
    uint32_t readiness = 0;
    if (revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)) {
        readiness |= JZX_IO_READ;
    }
    if (revents & (POLLOUT)) {
        readiness |= JZX_IO_WRITE;
    }
    return readiness;
}

static void jzx_io_rebuild_pollfds(jzx_loop* loop) {
    if (!loop->io_dirty) {
        return;
    }
    for (uint32_t i = 0; i < loop->io_count; ++i) {
        loop->io_pollfds[i].fd = loop->io_watchers[i].fd;
        loop->io_pollfds[i].events = jzx_io_interest_to_poll(loop->io_watchers[i].interest);
        loop->io_pollfds[i].revents = 0;
    }
    loop->io_dirty = 0;
}

static void jzx_io_poll(jzx_loop* loop, uint32_t timeout_ms) {
    if (loop->io_count == 0) {
        return;
    }
    jzx_io_rebuild_pollfds(loop);
    int wait_ms = (int)timeout_ms;
    int rv = poll(loop->io_pollfds, loop->io_count, wait_ms);
    if (rv <= 0) {
        return;
    }
    for (uint32_t i = 0; i < loop->io_count; ++i) {
        struct pollfd* pfd = &loop->io_pollfds[i];
        if (!pfd->revents) {
            continue;
        }
        uint32_t readiness = jzx_io_revents_to_readiness(pfd->revents);
        pfd->revents = 0;
        if (readiness == 0) {
            continue;
        }
        jzx_io_watch* watch = &loop->io_watchers[i];
        jzx_io_event* ev = (jzx_io_event*)jzx_alloc(&loop->allocator, sizeof(jzx_io_event));
        if (!ev) {
            continue;
        }
        ev->fd = watch->fd;
        ev->readiness = readiness;
        jzx_err err = jzx_send_internal(loop, watch->owner, ev, sizeof(jzx_io_event), JZX_TAG_SYS_IO, 0);
        if (err != JZX_OK) {
            jzx_free(&loop->allocator, ev);
        }
    }
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
        jzx_io_poll(loop, 0);
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

        if (loop->run_queue.count == 0) {
            if (loop->actors.used == 0 &&
                !jzx_async_has_pending(loop) &&
                !jzx_timer_has_pending(loop) &&
                loop->io_count == 0) {
                break;
            }
            jzx_io_poll(loop, loop->cfg.io_poll_timeout_ms);
            struct timespec ts = {
                .tv_sec = 0,
                .tv_nsec = 1000000,
            };
            nanosleep(&ts, NULL);
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
    if (loop->timer_mutex_initialized) {
        pthread_mutex_lock(&loop->timer_mutex);
        pthread_cond_broadcast(&loop->timer_cond);
        pthread_mutex_unlock(&loop->timer_mutex);
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
// Timers & IO
// -----------------------------------------------------------------------------

jzx_err jzx_send_after(jzx_loop* loop,
                       jzx_actor_id target,
                       uint32_t ms,
                       void* data,
                       size_t len,
                       uint32_t tag,
                       jzx_timer_id* out_timer) {
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
    if (!loop || fd < 0 || interest == 0) {
        return JZX_ERR_INVALID_ARG;
    }
    if (!jzx_actor_table_lookup(&loop->actors, owner)) {
        return JZX_ERR_NO_SUCH_ACTOR;
    }
    jzx_io_watch* existing = jzx_io_find(loop, fd, NULL);
    if (existing) {
        existing->owner = owner;
        existing->interest = interest;
        loop->io_dirty = 1;
        return JZX_OK;
    }
    if (loop->io_count == loop->io_capacity) {
        jzx_err err = jzx_io_reserve(loop, loop->io_capacity * 2);
        if (err != JZX_OK) {
            return err;
        }
    }
    loop->io_watchers[loop->io_count] = (jzx_io_watch){
        .fd = fd,
        .owner = owner,
        .interest = interest,
        .active = 1,
    };
    loop->io_pollfds[loop->io_count] = (struct pollfd){
        .fd = fd,
        .events = jzx_io_interest_to_poll(interest),
        .revents = 0,
    };
    loop->io_count++;
    loop->io_dirty = 1;
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
