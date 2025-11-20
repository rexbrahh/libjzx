#ifndef JZX_INTERNAL_H
#define JZX_INTERNAL_H

#include "jzx/jzx.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

struct pollfd;
typedef struct jzx_async_msg jzx_async_msg;
typedef struct jzx_timer_entry jzx_timer_entry;
typedef struct jzx_io_watch jzx_io_watch;

typedef struct {
    jzx_message* buffer;
    uint32_t capacity;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} jzx_mailbox_impl;

typedef struct {
    jzx_child_spec spec;
    jzx_actor_id id;
    uint32_t restart_count;
    uint64_t last_restart_ms;
} jzx_child_state;

typedef struct {
    jzx_supervisor_spec config;
    jzx_child_state* children;
    size_t child_count;
    uint32_t intensity_window_count;
    uint64_t intensity_window_start_ms;
} jzx_supervisor_state;

typedef struct jzx_actor {
    jzx_actor_id id;
    jzx_actor_status status;
    jzx_behavior_fn behavior;
    void* state;
    jzx_actor_id supervisor;
    jzx_supervisor_state* supervisor_state;
    jzx_mailbox_impl mailbox;
    uint8_t in_run_queue;
} jzx_actor;

typedef struct {
    jzx_actor** slots;
    uint32_t* generations;
    uint32_t* free_stack;
    uint32_t capacity;
    uint32_t free_top;
    uint32_t used;
} jzx_actor_table;

typedef struct {
    jzx_actor** entries;
    uint32_t capacity;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} jzx_run_queue;

struct jzx_loop {
    jzx_config cfg;
    jzx_allocator allocator;
    jzx_actor_table actors;
    jzx_run_queue run_queue;
    pthread_mutex_t async_mutex;
    uint8_t async_mutex_initialized;
    jzx_async_msg* async_head;
    jzx_async_msg* async_tail;
    pthread_mutex_t timer_mutex;
    pthread_cond_t timer_cond;
    uint8_t timer_mutex_initialized;
    uint8_t timer_thread_running;
    pthread_t timer_thread;
    uint8_t timer_stop;
    jzx_timer_entry* timer_head;
    jzx_timer_id next_timer_id;
    jzx_io_watch* io_watchers;
    uint32_t io_capacity;
    uint32_t io_count;
    struct pollfd* io_pollfds;
    uint8_t io_dirty;
    struct xev_loop* xev;
    int running;
    int stop_requested;
};

struct jzx_async_msg {
    jzx_actor_id target;
    void* data;
    size_t len;
    uint32_t tag;
    jzx_actor_id sender;
    struct jzx_async_msg* next;
};

struct jzx_timer_entry {
    jzx_timer_id id;
    jzx_actor_id target;
    void* data;
    size_t len;
    uint32_t tag;
    uint64_t due_ms;
    struct jzx_timer_entry* next;
};

struct jzx_io_watch {
    int fd;
    jzx_actor_id owner;
    uint32_t interest;
    uint8_t active;
};

#endif
