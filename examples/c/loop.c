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
