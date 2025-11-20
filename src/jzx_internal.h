#ifndef JZX_INTERNAL_H
#define JZX_INTERNAL_H

#include "jzx/jzx.h"

#include <stddef.h>
#include <stdint.h>

typedef enum {
    JZX_ACTOR_STATUS_INIT = 0,
    JZX_ACTOR_STATUS_RUNNING,
    JZX_ACTOR_STATUS_STOPPING,
    JZX_ACTOR_STATUS_STOPPED,
    JZX_ACTOR_STATUS_FAILED,
} jzx_actor_status;

typedef struct {
    jzx_message* buffer;
    uint32_t capacity;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} jzx_mailbox_impl;

typedef struct jzx_actor {
    jzx_actor_id id;
    jzx_actor_status status;
    jzx_behavior_fn behavior;
    void* state;
    jzx_actor_id supervisor;
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
    int running;
    int stop_requested;
};

#endif
