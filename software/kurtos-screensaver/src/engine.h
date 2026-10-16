// SPDX-License-Identifier: GPL-3.0-or-later
// KurtOS screensaver engine — C port of ralleur-website/screensaver/Sources/Engine.swift.
// The ralleur Version 03 symbol (eight bars) performs short physical "acts".
// The wordmark is disabled in the original saver, so only the bars are ported.
#ifndef KURTOS_ENGINE_H
#define KURTOS_ENGINE_H

#include <stdint.h>
#include <stdbool.h>

typedef struct { double x, y; } vec;

#define K_BODIES 8
#define K_SNAKE_PTS 1024

typedef enum { M_SPRING, M_BALLISTIC, M_SCRIPTED, M_PARKED } body_mode;

typedef struct {
    int index;
    uint32_t rgb;
    vec size, home;            // unscaled size, centre relative to the logo centre
    vec p, v;
    double a, av;
    vec s, sv;
    bool has_scale_override;
    vec scale_override;
    body_mode mode;
    vec target;
    double target_a;
    double k, zeta, ak, azeta;
    double gravity, drag, ang_drag;
    bool bounce_walls;
    bool flag;
    double t0, phase;
} body;

typedef enum { ACT_HOLD, ACT_ARRIVAL, ACT_BURST, ACT_RAIN, ACT_SHUFFLE, ACT_WAVE, ACT_MIGRATE, ACT_SNAKE } act_kind;

typedef struct {
    act_kind kind;
    double t;
    bool done;
    // hold
    double duration, next_fidget;
    // arrival / burst / rain
    double launch[K_BODIES];
    bool released;
    int phase;
    vec new_origin;
    double phase1_start;
    // shuffle
    int perm[6];
    vec slot_home[6];
    int swaps[16][3];
    int swap_count, current;
    double swap_start;
    // wave
    double min_x, width;
    // migrate / snake
    vec from, to;
    int hop_count[K_BODIES];
    double hop_dur[K_BODIES], start_at[K_BODIES];
    double finished_all;
    int npts;
    vec pts[K_SNAKE_PTS];
    double cum[K_SNAKE_PTS], ang[K_SNAKE_PTS];
    double length, speed;
    double offset[K_BODIES], ang_off[K_BODIES], join_t[K_BODIES];
    bool joined[K_BODIES], rel[K_BODIES];
    double all_released_at;     // < 0 while not all released
} act_state;

typedef struct {
    body bodies[K_BODIES];
    double unit;                // pixels per logo unit
    vec world;                  // screen size in logo units
    vec logo_half;
    vec origin;                 // logo centre in world units
    double time;
    uint64_t rng;
    act_state act;
    act_kind history[64];
    int history_len;
    int acts_since_move;
    act_kind forced[32];
    int forced_len, forced_pos;
} engine;

void engine_init(engine *e, double width, double height, uint64_t seed);
void engine_force_acts(engine *e, const act_kind *acts, int n);
void engine_resize(engine *e, double width, double height);
void engine_step(engine *e, double dt);
const char *act_name(act_kind k);
bool act_from_name(const char *name, act_kind *out);

#endif
