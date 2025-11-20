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
    if (!msg) return NULL;
    msg->tick = tick;
    return msg;
}

static jzx_behavior_result flapping_actor(jzx_context* ctx, const jzx_message* msg) {
    if (!msg->data) return JZX_BEHAVIOR_FAIL;
    tick_msg* t = (tick_msg*)msg->data;
    int next = t->tick + 1;
    printf("[child] tick=%d\n", t->tick);
    free(t);

    if (next > 3) {
        printf("[child] simulating failure\n");
        return JZX_BEHAVIOR_FAIL;
    }

    tick_msg* next_msg = make_tick(next);
    if (!next_msg) return JZX_BEHAVIOR_FAIL;
    if (jzx_send_after(ctx->loop, ctx->self, 100, next_msg, sizeof(tick_msg), 0, NULL) !=
        JZX_OK) {
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
    if (!first) return 1;
    if (jzx_send(loop, child_id, first, sizeof(tick_msg), 0) != JZX_OK) {
        free(first);
        return 1;
    }

    int rc = jzx_loop_run(loop);
    jzx_loop_destroy(loop);
    return rc;
}
