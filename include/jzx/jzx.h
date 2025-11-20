#ifndef JZX_JZX_H
#define JZX_JZX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Error Model -----------------------------------------------------------

typedef enum {
    JZX_OK = 0,
    JZX_ERR_UNKNOWN = -1,
    JZX_ERR_NO_MEMORY = -2,
    JZX_ERR_INVALID_ARG = -3,
    JZX_ERR_LOOP_CLOSED = -4,
    JZX_ERR_NO_SUCH_ACTOR = -5,
    JZX_ERR_MAILBOX_FULL = -7,
    JZX_ERR_TIMER_INVALID = -8,
    JZX_ERR_IO_REG_FAILED = -9,
    JZX_ERR_MAX_ACTORS = -11,
} jzx_err;

// --- Core types ------------------------------------------------------------

typedef uint64_t jzx_actor_id;
typedef uint64_t jzx_timer_id;

typedef struct jzx_loop jzx_loop;

typedef struct {
    void* (*alloc)(void* ctx, size_t size);
    void (*free)(void* ctx, void* ptr);
    void* ctx;
} jzx_allocator;

typedef struct {
    jzx_allocator allocator;
    uint32_t max_actors;
    uint32_t default_mailbox_cap;
    uint32_t max_msgs_per_actor;
    uint32_t max_actors_per_tick;
} jzx_config;

void jzx_config_init(jzx_config* cfg);

// --- Messaging -------------------------------------------------------------

typedef struct {
    void* data;
    size_t len;
    uint32_t tag;
    jzx_actor_id sender;
} jzx_message;

// --- Behavior --------------------------------------------------------------

typedef struct {
    void* state;
    jzx_actor_id self;
    jzx_loop* loop;
} jzx_context;

typedef enum {
    JZX_BEHAVIOR_OK = 0,
    JZX_BEHAVIOR_STOP = 1,
    JZX_BEHAVIOR_FAIL = 2,
} jzx_behavior_result;

typedef jzx_behavior_result (*jzx_behavior_fn)(jzx_context* ctx,
                                               const jzx_message* msg);

// --- Spawning --------------------------------------------------------------

typedef struct {
    jzx_behavior_fn behavior;
    void* state;
    jzx_actor_id supervisor;
    uint32_t mailbox_cap;
} jzx_spawn_opts;

jzx_err jzx_spawn(jzx_loop* loop, const jzx_spawn_opts* opts, jzx_actor_id* out_id);

// --- Loop management -------------------------------------------------------

jzx_loop* jzx_loop_create(const jzx_config* cfg);
void jzx_loop_destroy(jzx_loop* loop);
int jzx_loop_run(jzx_loop* loop);
void jzx_loop_request_stop(jzx_loop* loop);

// --- Messaging API ---------------------------------------------------------

jzx_err jzx_send(jzx_loop* loop,
                 jzx_actor_id target,
                 void* data,
                 size_t len,
                 uint32_t tag);

jzx_err jzx_send_async(jzx_loop* loop,
                       jzx_actor_id target,
                       void* data,
                       size_t len,
                       uint32_t tag);

jzx_err jzx_actor_stop(jzx_loop* loop, jzx_actor_id id);
jzx_err jzx_actor_fail(jzx_loop* loop, jzx_actor_id id);

// --- Timers & IO -----------------------------------------------------------

jzx_err jzx_send_after(jzx_loop* loop,
                       jzx_actor_id target,
                       uint32_t ms,
                       void* data,
                       size_t len,
                       uint32_t tag,
                       jzx_timer_id* out_timer);

jzx_err jzx_cancel_timer(jzx_loop* loop, jzx_timer_id timer);

jzx_err jzx_watch_fd(jzx_loop* loop, int fd, jzx_actor_id owner, uint32_t interest);

#ifdef __cplusplus
}
#endif

#endif // JZX_JZX_H
