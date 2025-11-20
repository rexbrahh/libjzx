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
    JZX_ERR_IO_NOT_WATCHED = -10,
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
    uint32_t max_io_watchers;
    uint32_t io_poll_timeout_ms;
} jzx_config;

void jzx_config_init(jzx_config* cfg);

// --- Messaging -------------------------------------------------------------

typedef struct {
    void* data;
    size_t len;
    uint32_t tag;
    jzx_actor_id sender;
} jzx_message;

#define JZX_TAG_SYS_IO 0xFFFF0001u

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

typedef enum {
    JZX_CHILD_PERMANENT,
    JZX_CHILD_TRANSIENT,
    JZX_CHILD_TEMPORARY,
} jzx_child_mode;

typedef enum {
    JZX_SUP_ONE_FOR_ONE,
    JZX_SUP_ONE_FOR_ALL,
    JZX_SUP_REST_FOR_ONE,
} jzx_supervisor_strategy;

typedef enum {
    JZX_BACKOFF_NONE,
    JZX_BACKOFF_CONSTANT,
    JZX_BACKOFF_EXPONENTIAL,
} jzx_backoff_type;

// --- Spawning --------------------------------------------------------------

typedef struct {
    jzx_behavior_fn behavior;
    void* state;
    jzx_actor_id supervisor;
    uint32_t mailbox_cap;
} jzx_spawn_opts;

jzx_err jzx_spawn(jzx_loop* loop, const jzx_spawn_opts* opts, jzx_actor_id* out_id);

typedef struct {
    jzx_behavior_fn behavior;
    void* state;
    jzx_child_mode mode;
    uint32_t mailbox_cap;
    uint32_t restart_delay_ms;
    jzx_backoff_type backoff;
} jzx_child_spec;

typedef struct {
    jzx_supervisor_strategy strategy;
    uint32_t intensity;
    uint32_t period_ms;
    jzx_backoff_type backoff;
    uint32_t backoff_delay_ms;
} jzx_supervisor_spec;

typedef struct {
    const jzx_child_spec* children;
    size_t child_count;
    jzx_supervisor_spec supervisor;
} jzx_supervisor_init;

jzx_err jzx_spawn_supervisor(jzx_loop* loop,
                            const jzx_supervisor_init* init,
                            jzx_actor_id parent,
                            jzx_actor_id* out_id);

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
jzx_err jzx_unwatch_fd(jzx_loop* loop, int fd);

#ifdef __cplusplus
}
#endif

#endif // JZX_JZX_H
typedef struct {
    int fd;
    uint32_t readiness;
} jzx_io_event;

#define JZX_IO_READ  (1u << 0)
#define JZX_IO_WRITE (1u << 1)
