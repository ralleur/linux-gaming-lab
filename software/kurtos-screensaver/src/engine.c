// SPDX-License-Identifier: GPL-3.0-or-later
// C port of ralleur-website/screensaver/Sources/Engine.swift (bars only).
// Keep the choreography in step with the Swift original when either changes.
#include "engine.h"

#include <math.h>
#include <string.h>

#define PI 3.14159265358979323846

// ---------------------------------------------------------------- vector math

static inline vec V(double x, double y) { return (vec){x, y}; }
static inline vec vadd(vec a, vec b) { return V(a.x + b.x, a.y + b.y); }
static inline vec vsub(vec a, vec b) { return V(a.x - b.x, a.y - b.y); }
static inline vec vmul(vec a, double k) { return V(a.x * k, a.y * k); }
static inline double vlen(vec a) { return sqrt(a.x * a.x + a.y * a.y); }
static inline vec vnorm(vec a) { double l = vlen(a); return l > 1e-9 ? vmul(a, 1 / l) : V(1, 0); }
static inline vec vperp(vec a) { return V(-a.y, a.x); }
static inline double lerp(double a, double b, double t) { return a + (b - a) * t; }
static inline vec vlerp(vec a, vec b, double t) { return vadd(a, vmul(vsub(b, a), t)); }
static inline double clamp01(double t) { return t < 0 ? 0 : (t > 1 ? 1 : t); }
static inline double smooth(double t) { t = clamp01(t); return t * t * (3 - 2 * t); }
static inline double ease_in_out(double t) {
    t = clamp01(t);
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;
}
/// Angle wrapped into (-period/2, period/2].
static inline double wrap(double a, double period) { return a - period * round(a / period); }
static inline double dmin(double a, double b) { return a < b ? a : b; }
static inline double dmax(double a, double b) { return a > b ? a : b; }

// ---------------------------------------------------------------- random

static uint64_t splitmix(uint64_t *state) {
    *state += 0x9E3779B97F4A7C15ull;
    uint64_t z = *state;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static double rand_unit(engine *e) { return (double)(splitmix(&e->rng) >> 11) * (1.0 / 9007199254740992.0); }
static double rnd(engine *e, double a, double b) { double lo = dmin(a, b), hi = dmax(a, b); return lo + (hi - lo) * rand_unit(e); }
static int rand_int(engine *e, int n) { return (int)(splitmix(&e->rng) % (uint64_t)n); }
static bool chance(engine *e, double p) { return rnd(e, 0, 1) < p; }
static void shuffle(engine *e, int *a, int n) {
    for (int i = n - 1; i > 0; i--) { int j = rand_int(e, i + 1); int t = a[i]; a[i] = a[j]; a[j] = t; }
}

// ---------------------------------------------------------------- logo

typedef struct { double x, y, w, h; uint32_t rgb; } bar_def;

// Geometry of the ralleur Version 03 mark, 1:1 from ralleur/logo/*.svg (136 × 168 units).
static const bar_def BARS[K_BODIES] = {
    {0, 0, 58, 22, 0x2563C9},   // blue
    {66, 0, 70, 22, 0xDF493F},  // red
    {4, 34, 22, 62, 0xDED6C8},  // cream
    {38, 34, 22, 62, 0xE4AD22}, // yellow
    {72, 34, 22, 62, 0x278F8B}, // teal
    {4, 106, 22, 62, 0xE56D2F}, // orange
    {38, 106, 22, 62, 0x3F7D44},// green
    {72, 106, 22, 62, 0x8F5B40},// brown
};

// ---------------------------------------------------------------- bodies

static double radius(const body *b) { return vlen(vmul(b->size, 0.5)); }
static vec half(const body *b) { return vmul(b->size, 0.5); }

static void set_spring(body *b, double k, double zeta, double ak, double azeta) {
    b->mode = M_SPRING;
    b->k = k; b->zeta = zeta;
    b->ak = ak; b->azeta = azeta;
}
static void spring(body *b, double k, double zeta) { set_spring(b, k, zeta, k, zeta); }

/// Place the body at an animated pose; velocity is derived so a later
/// hand-off to the spring/ballistic modes is seamless.
static void script(body *b, vec np, double angle, const vec *scale, double dt) {
    if (b->mode == M_SCRIPTED && dt > 0) {
        b->v = vmul(vsub(np, b->p), 1 / dt);
        b->av = (angle - b->a) / dt;
    }
    b->mode = M_SCRIPTED;
    b->p = np; b->a = angle;
    b->has_scale_override = scale != NULL;
    if (scale) b->scale_override = *scale;
}

/// Bars are symmetric under a half turn.
static const double SYMMETRY = PI;
static void normalize_angle(body *b) { b->a = wrap(b->a, SYMMETRY); }

// ---------------------------------------------------------------- engine helpers

static vec home_world(const engine *e, const body *b) { return vadd(e->origin, b->home); }
static vec home_world_at(const body *b, vec o) { return vadd(o, b->home); }
static double diag(const engine *e) { return vlen(e->world); }

static vec idle_target_at(const engine *e, const body *b, vec o) {
    return vadd(home_world_at(b, o), V(0, 1.1 * sin(1.7 * e->time + b->phase)));
}
static vec idle_target(const engine *e, const body *b) { return idle_target_at(e, b, e->origin); }

static vec pick_new_origin(engine *e, double min_distance) {
    const double m = 30;
    vec lo = vadd(e->logo_half, V(m, m)), hi = vsub(vsub(e->world, e->logo_half), V(m, m));
    if (!(lo.x < hi.x && lo.y < hi.y)) return vmul(e->world, 0.5);
    vec best = e->origin; double best_d = -1;
    for (int i = 0; i < 40; i++) {
        vec c = V(rnd(e, lo.x, hi.x), rnd(e, lo.y, hi.y));
        double d = vlen(vsub(c, e->origin));
        if (d >= min_distance) return c;
        if (d > best_d) { best = c; best_d = d; }
    }
    return best;
}

/// A single cartoon hop from a to b with anticipation squash, stretch in the
/// air and a landing squash; `lift` is the arc direction.
static void hop_pose(vec a, vec b, double u, double height, vec lift, double half_h, vec *out_p, vec *out_s) {
    const double crouch = 0.16, land = 0.84;
    double sy = 1;
    vec p;
    if (u < crouch) {
        sy = 1 - 0.26 * sin(PI * u / crouch * 0.5);          // sink into the ground
        p = a;
    } else if (u < land) {
        double w = (u - crouch) / (land - crouch);
        p = vadd(vlerp(a, b, ease_in_out(w)), vmul(lift, height * sin(PI * w)));
        sy = 1 + 0.2 * sin(PI * w) * (1 - 0.6 * w);          // stretch while flying
    } else {
        double w = (u - land) / (1 - land);
        sy = 1 - 0.24 * sin(PI * w);                         // splat & recover
        p = b;
    }
    double sx = 1 + (1 - sy) * 0.7;
    if (lift.y < 0) p.y += half_h * (1 - sy);                // keep the "feet" on the ground
    *out_p = p; *out_s = V(sx, sy);
}

// ---------------------------------------------------------------- acts

static bool moves_logo(act_kind k) { return k == ACT_RAIN || k == ACT_MIGRATE || k == ACT_SNAKE; }

const char *act_name(act_kind k) {
    switch (k) {
    case ACT_HOLD: return "hold";
    case ACT_ARRIVAL: return "arrival";
    case ACT_BURST: return "burst";
    case ACT_RAIN: return "rain";
    case ACT_SHUFFLE: return "shuffle";
    case ACT_WAVE: return "wave";
    case ACT_MIGRATE: return "migrate";
    case ACT_SNAKE: return "snake";
    }
    return "?";
}

bool act_from_name(const char *name, act_kind *out) {
    for (int k = ACT_HOLD; k <= ACT_SNAKE; k++) {
        if (strcmp(name, act_name((act_kind)k)) == 0) { *out = (act_kind)k; return true; }
    }
    return false;
}

// Everything hangs around, breathing, with the occasional fidget.
static void hold_start(engine *e, act_state *s) {
    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        spring(b, 140, 0.6);
        b->has_scale_override = false;
        normalize_angle(b);
        b->target_a = 0;
    }
    s->next_fidget = rnd(e, 1.0, 2.2);
}

static void hold_update(engine *e, act_state *s, double dt) {
    (void)dt;
    for (int i = 0; i < K_BODIES; i++) e->bodies[i].target = idle_target(e, &e->bodies[i]);
    if (s->t >= s->next_fidget) {
        body *b = &e->bodies[rand_int(e, K_BODIES)];
        switch (rand_int(e, 4)) {
        case 0: b->v.y -= 150; b->sv = vadd(b->sv, V(-2.5, 3.5)); break;              // little hop
        case 1: b->av += (chance(e, 0.5) ? 1 : -1) * rnd(e, 4, 7); break;              // wiggle
        case 2: b->sv = vadd(b->sv, V(4.5, -5.5)); break;                              // squish
        default: b->av += (chance(e, 0.5) ? 1 : -1) * 2 * PI * 3.2; b->v.y -= 120; break; // the show-off flip
        }
        s->next_fidget = s->t + rnd(e, 1.4, 3.0);
    }
    if (s->t >= s->duration) s->done = true;
}

// Opening: the bars swoop in from all sides.
static void arrival_start(engine *e, act_state *s) {
    int order[K_BODIES];
    for (int i = 0; i < K_BODIES; i++) order[i] = i;
    shuffle(e, order, K_BODIES);
    for (int n = 0; n < K_BODIES; n++) {
        body *b = &e->bodies[order[n]];
        double ang = rnd(e, 0, 2 * PI);
        b->p = vadd(e->origin, vmul(V(cos(ang), sin(ang)), diag(e) * 0.5 + 140));
        b->a = rnd(e, -3, 3) * PI;
        b->mode = M_PARKED;
        s->launch[order[n]] = 0.35 + n * 0.14;
    }
}

static void arrival_update(engine *e, act_state *s, double dt) {
    (void)dt;
    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        b->target = idle_target(e, b); b->target_a = 0;
        if (b->mode == M_PARKED && s->t >= s->launch[i]) {
            set_spring(b, 36, 0.42, 28, 0.4);
            vec toward = vnorm(vsub(b->target, b->p));
            b->v = vmul(vperp(toward), rnd(e, 250, 520) * (chance(e, 0.5) ? 1 : -1));
        }
        if (b->mode != M_PARKED && !b->flag && vlen(vsub(b->p, b->target)) < 4) {
            b->flag = true;
            double impact = dmin(1, vlen(b->v) / 260);
            b->sv = vadd(b->sv, vmul(V(5, -7), impact));
        }
    }
    if (s->t > 4.6) s->done = true;
}

// Tension, then a burst into zero-g; the pieces drift, bounce off the
// screen edges and finally snap back like rubber bands.
static void burst_start(engine *e, act_state *s) {
    for (int i = 0; i < K_BODIES; i++) { spring(&e->bodies[i], 260, 0.7); e->bodies[i].flag = false; }
    int order[K_BODIES];
    for (int i = 0; i < K_BODIES; i++) order[i] = i;
    shuffle(e, order, K_BODIES);
    for (int n = 0; n < K_BODIES; n++) s->launch[order[n]] = 3.0 + n * 0.06;   // return times
}

static void burst_update(engine *e, act_state *s, double dt) {
    (void)dt;
    if (s->t < 0.55) {
        double squeeze = smooth(s->t / 0.55);
        for (int i = 0; i < K_BODIES; i++) {
            body *b = &e->bodies[i];
            b->target = vadd(e->origin, vmul(b->home, 1 - 0.14 * squeeze));
            b->target_a = 0;
            b->has_scale_override = true;
            b->scale_override = V(1 + 0.05 * squeeze, 1 - 0.12 * squeeze);
        }
    } else if (!s->released) {
        s->released = true;
        for (int i = 0; i < K_BODIES; i++) {
            body *b = &e->bodies[i];
            b->has_scale_override = false;
            b->sv = V(-3, 5);
            b->mode = M_BALLISTIC;
            b->gravity = 0; b->drag = 1.1; b->ang_drag = 0.6; b->bounce_walls = true;
            vec out = vnorm(vsub(b->p, e->origin));
            b->v = vadd(vmul(out, rnd(e, 520, 900)), V(rnd(e, -90, 90), rnd(e, -90, 90)));
            b->av = rnd(e, -9, 9);
        }
    } else {
        for (int i = 0; i < K_BODIES; i++) {
            body *b = &e->bodies[i];
            if (s->t < s->launch[i]) continue;
            if (!b->flag) {
                b->flag = true;
                normalize_angle(b);
                b->bounce_walls = false;
                set_spring(b, 55, 0.4, 45, 0.45);
            }
            b->target = idle_target(e, b); b->target_a = 0;
        }
    }
    if (s->t > 6.2) s->done = true;
}

// Everything tumbles out of the screen, then the logo is re-stacked
// somewhere else, row by row, like heavy blocks.
static void rain_start(engine *e, act_state *s) {
    for (int i = 0; i < K_BODIES; i++) { e->bodies[i].flag = false; e->bodies[i].t0 = rnd(e, 0, 0.45); }
    s->new_origin = pick_new_origin(e, e->world.x * 0.22);
}

static void rain_update(engine *e, act_state *s, double dt) {
    (void)dt;
    if (s->phase == 0) {
        bool all_gone = true;
        for (int i = 0; i < K_BODIES; i++) {
            body *b = &e->bodies[i];
            if (b->mode != M_BALLISTIC) {
                b->target = idle_target(e, b);
                if (s->t >= b->t0) {
                    b->mode = M_BALLISTIC;
                    b->gravity = 2200; b->drag = 0; b->ang_drag = 0; b->bounce_walls = false;
                    b->v = V(rnd(e, -110, 110), rnd(e, -420, -160));
                    b->av = rnd(e, -6, 6);
                    b->sv = vadd(b->sv, V(-2, 4));
                }
            }
            if (!(b->mode == M_BALLISTIC && b->p.y > e->world.y + radius(b) + 10)) all_gone = false;
        }
        if (all_gone || s->t > 4) {
            s->phase = 1;
            s->phase1_start = s->t;
            e->origin = s->new_origin;
            static const int rows[3][3] = {{5, 6, 7}, {2, 3, 4}, {0, 1, -1}};
            double at = 0.25;
            for (int r = 0; r < 3; r++) {
                int row[3], n = 0;
                for (int j = 0; j < 3; j++) if (rows[r][j] >= 0) row[n++] = rows[r][j];
                shuffle(e, row, n);
                for (int j = 0; j < n; j++) s->launch[row[j]] = at + j * 0.11;   // drop times
                at += 0.62;
            }
            for (int i = 0; i < K_BODIES; i++) {
                body *b = &e->bodies[i];
                b->mode = M_PARKED;
                b->a = 0; b->av = 0; b->v = V(0, 0);
                b->p = V(home_world(e, b).x, -radius(b) - 20);
                b->flag = false;
            }
        }
    } else {
        double lt = s->t - s->phase1_start, last = 0;
        for (int i = 0; i < K_BODIES; i++) {
            body *b = &e->bodies[i];
            vec home = home_world(e, b);
            if (s->launch[i] > last) last = s->launch[i];
            if (b->mode == M_PARKED && lt >= s->launch[i]) {
                b->mode = M_BALLISTIC;
                b->gravity = 3200; b->drag = 0; b->ang_drag = 0;
                b->v = V(0, 250);
                b->has_scale_override = true;
                b->scale_override = V(0.86, 1.18);   // stretched while falling
            }
            if (b->mode == M_BALLISTIC && !b->flag && b->p.y >= home.y) {
                b->flag = true;
                double impact = dmin(1.3, b->v.y / 1400);
                b->p.y = home.y;
                b->v = V(0, 0);
                b->has_scale_override = false;
                b->s = V(1 + 0.3 * impact, 1 - 0.38 * impact);
                b->sv = V(0, 0);
                spring(b, 260, 0.5);
                // the thud travels into everything that already landed below
                for (int j = 0; j < K_BODIES; j++) {
                    body *o = &e->bodies[j];
                    if (o->flag && o != b && o->home.y > b->home.y) {
                        o->sv = vadd(o->sv, vmul(V(2.2, -3.2), impact));
                        o->v.y += 40 * impact;
                    }
                }
            }
            if (b->flag) { b->target = idle_target(e, b); b->target_a = 0; }
        }
        if (lt > last + 1.6) s->done = true;
    }
}

// Shell game: the six upright bars hop over each other to swap places,
// get properly mixed up, then sort themselves back into order.
// The two top bars watch the action.
#define SCRAMBLE_COUNT 6

static void shuffle_start(engine *e, act_state *s) {
    int p[6];
    for (int i = 0; i < 6; i++) { s->perm[i] = 2 + i; p[i] = 2 + i; s->slot_home[i] = e->bodies[2 + i].home; }
    int last_lo = -1, last_hi = -1;
    s->swap_count = 0;
    for (int n = 0; n < SCRAMBLE_COUNT; n++) {
        int a, b;
        do { a = rand_int(e, 6); b = rand_int(e, 6); }
        while (a == b || ((a < b ? a : b) == last_lo && (a < b ? b : a) == last_hi));
        last_lo = a < b ? a : b; last_hi = a < b ? b : a;
        int t = p[a]; p[a] = p[b]; p[b] = t;
        s->swaps[s->swap_count][0] = a; s->swaps[s->swap_count][1] = b; s->swaps[s->swap_count][2] = chance(e, 0.4);
        s->swap_count++;
    }
    // selection sort back into place
    for (int slot = 0; slot < 6; slot++) {
        if (p[slot] == 2 + slot) continue;
        int from = slot;
        while (p[from] != 2 + slot) from++;
        int t = p[slot]; p[slot] = p[from]; p[from] = t;
        s->swaps[s->swap_count][0] = slot; s->swaps[s->swap_count][1] = from; s->swaps[s->swap_count][2] = chance(e, 0.25);
        s->swap_count++;
    }
    s->current = 0;
    s->swap_start = 0.5;
    for (int i = 0; i < K_BODIES; i++) spring(&e->bodies[i], 160, 0.6);
}

static int slot_of(const act_state *s, int body_index) {
    for (int i = 0; i < 6; i++) if (s->perm[i] == body_index) return i;
    return -1;
}

static void shuffle_update(engine *e, act_state *s, double dt) {
    bool sorting = s->current >= SCRAMBLE_COUNT;
    double dur = sorting ? 0.5 : 0.62;
    int active_a = -1, active_b = -1;
    bool has_focus = false;
    vec focus = V(0, 0);

    if (s->current < s->swap_count && s->t >= s->swap_start) {
        int sa = s->swaps[s->current][0], sb = s->swaps[s->current][1];
        bool flip = s->swaps[s->current][2];
        body *A = &e->bodies[s->perm[sa]], *B = &e->bodies[s->perm[sb]];
        vec pa = vadd(e->origin, s->slot_home[sa]), pb = vadd(e->origin, s->slot_home[sb]);
        double u = (s->t - s->swap_start) / dur;
        if (u < 1) {
            vec lift = vperp(vnorm(vsub(pb, pa)));
            if (lift.y > 0) lift = vmul(lift, -1);              // A always goes over the top
            double d = vlen(vsub(pb, pa));
            vec ra_p, ra_s, rb_p, rb_s;
            hop_pose(pa, pb, u, 26 + d * 0.28, lift, half(A).y, &ra_p, &ra_s);
            hop_pose(pb, pa, u, 10 + d * 0.12, vmul(lift, -1), half(B).y, &rb_p, &rb_s);
            double w = clamp01((u - 0.16) / 0.68);
            script(A, ra_p, flip ? -2 * PI * ease_in_out(w) : 0, &ra_s, dt);
            script(B, rb_p, 0, &rb_s, dt);
            active_a = A->index; active_b = B->index;
            focus = vlerp(pa, pb, 0.5); has_focus = true;
        } else {
            int t = s->perm[sa]; s->perm[sa] = s->perm[sb]; s->perm[sb] = t;
            body *pair[2] = {A, B};
            for (int j = 0; j < 2; j++) {
                body *b = pair[j];
                b->a = 0; b->v = V(0, 0); b->av = 0;
                b->has_scale_override = false;
                b->sv = V(3, -4);
                spring(b, 200, 0.5);
            }
            s->current++;
            s->swap_start = s->t + (s->current == SCRAMBLE_COUNT ? 0.7 : (sorting ? 0.08 : 0.12));
        }
    }

    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        if (i == active_a || i == active_b) continue;
        int slot = slot_of(s, i);
        if (slot >= 0) b->target = vadd(vadd(e->origin, s->slot_home[slot]), V(0, 1.1 * sin(1.7 * e->time + b->phase)));
        else b->target = idle_target(e, b);
        b->target_a = 0;
    }
    // top bars lean towards the action, like spectators
    if (has_focus) {
        for (int i = 0; i < 2; i++) {
            body *b = &e->bodies[i];
            double lean = (focus.x - home_world(e, b).x) * 0.004;
            b->target_a = lean < -0.16 ? -0.16 : (lean > 0.16 ? 0.16 : lean);
            b->target = vadd(idle_target(e, b), V(0, -2));
        }
    }
    if (s->current >= s->swap_count && s->t > s->swap_start + 0.8) s->done = true;
}

// Stadium wave: a hop rolls left→right, then a flip rolls back right→left.
static void wave_start(engine *e, act_state *s) {
    double lo = 1e9, hi = -1e9;
    for (int i = 0; i < K_BODIES; i++) { lo = dmin(lo, e->bodies[i].home.x); hi = dmax(hi, e->bodies[i].home.x); }
    s->min_x = lo; s->width = hi - lo;
    for (int i = 0; i < K_BODIES; i++) spring(&e->bodies[i], 200, 0.55);
}

static void wave_update(engine *e, act_state *s, double dt) {
    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        double nx = (b->home.x - s->min_x) / s->width;
        vec home = home_world(e, b), rp, rs;
        double hop1 = (s->t - (0.2 + nx * 0.85)) / 0.52;
        double hop2 = (s->t - (2.0 + (1 - nx) * 0.85)) / 0.62;
        if (hop1 > 0 && hop1 < 1) {
            hop_pose(home, home, hop1, 30, V(0, -1), half(b).y, &rp, &rs);
            script(b, rp, 0, &rs, dt);
        } else if (hop2 > 0 && hop2 < 1) {
            hop_pose(home, home, hop2, 22, V(0, -1), half(b).y, &rp, &rs);
            double w = clamp01((hop2 - 0.16) / 0.68);
            script(b, rp, 2 * PI * ease_in_out(w), &rs, dt);
        } else {
            if (b->mode == M_SCRIPTED) {
                b->a = 0; b->av = 0; b->v = V(0, 0);
                b->has_scale_override = false;
                spring(b, 200, 0.55);
            }
            b->target = idle_target(e, b); b->target_a = 0;
        }
    }
    if (s->t > 4.3) s->done = true;
}

// The whole troupe hops across the screen to a new spot.
static void migrate_start(engine *e, act_state *s) {
    s->from = e->origin;
    s->to = pick_new_origin(e, e->world.x * 0.3);
    double dist = vlen(vsub(s->to, s->from));
    s->finished_all = 0;
    for (int i = 0; i < K_BODIES; i++) {
        spring(&e->bodies[i], 160, 0.6);
        int hops = (int)round(dist / 64.0);
        s->hop_count[i] = hops < 2 ? 2 : hops;
        s->hop_dur[i] = 0.34;
        s->start_at[i] = rnd(e, 0.2, 0.7);
        s->finished_all = dmax(s->finished_all, s->start_at[i] + s->hop_count[i] * s->hop_dur[i]);
    }
    s->finished_all += 1.4;
}

static void migrate_update(engine *e, act_state *s, double dt) {
    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        vec a = vadd(s->from, b->home), z = vadd(s->to, b->home);
        double lt = s->t - s->start_at[i];
        double total = s->hop_count[i] * s->hop_dur[i];
        if (lt <= 0) {
            b->target = idle_target_at(e, b, s->from); b->target_a = 0;
        } else if (lt < total) {
            int k = (int)(lt / s->hop_dur[i]);
            double u = (lt - k * s->hop_dur[i]) / s->hop_dur[i];
            double n = s->hop_count[i];
            vec p0 = vlerp(a, z, k / n), p1 = vlerp(a, z, (k + 1) / n), rp, rs;
            hop_pose(p0, p1, u, 28, V(0, -1), half(b).y, &rp, &rs);
            double w = clamp01((u - 0.16) / 0.68);
            double tilt = (z.x > a.x ? 1.0 : -1.0) * 0.18 * sin(PI * w);
            script(b, rp, tilt, &rs, dt);
        } else {
            if (b->mode == M_SCRIPTED) {
                b->v = V(0, 0); b->av = 0; b->a = 0;
                b->has_scale_override = false;
                spring(b, 200, 0.55);
            }
            b->target = idle_target_at(e, b, s->to); b->target_a = 0;
        }
    }
    if (s->t > s->finished_all) { e->origin = s->to; s->done = true; }
}

// Conga line: the bars join a train behind the blue bar, snake across the
// screen and coil back into the logo somewhere else.
static void snake_sample(act_state *s, const vec *wps, int nw) {
    // centripetal Catmull-Rom through the waypoints
    vec ctrl[16];
    int nc = 0;
    ctrl[nc++] = vsub(vmul(wps[0], 2), wps[1]);
    for (int i = 0; i < nw; i++) ctrl[nc++] = wps[i];
    ctrl[nc++] = vsub(vmul(wps[nw - 1], 2), wps[nw - 2]);
    s->npts = 0;
    const int steps = 120;
    for (int i = 1; i < nc - 2; i++) {
        vec p0 = ctrl[i - 1], p1 = ctrl[i], p2 = ctrl[i + 1], p3 = ctrl[i + 2];
        double t0 = 0;
        double t1 = t0 + dmax(1e-3, sqrt(vlen(vsub(p1, p0))));
        double t2 = t1 + dmax(1e-3, sqrt(vlen(vsub(p2, p1))));
        double t3 = t2 + dmax(1e-3, sqrt(vlen(vsub(p3, p2))));
        for (int k = 0; k < steps && s->npts < K_SNAKE_PTS - 1; k++) {
            double t = lerp(t1, t2, (double)k / steps);
            vec a1 = vadd(vmul(p0, (t1 - t) / (t1 - t0)), vmul(p1, (t - t0) / (t1 - t0)));
            vec a2 = vadd(vmul(p1, (t2 - t) / (t2 - t1)), vmul(p2, (t - t1) / (t2 - t1)));
            vec a3 = vadd(vmul(p2, (t3 - t) / (t3 - t2)), vmul(p3, (t - t2) / (t3 - t2)));
            vec b1 = vadd(vmul(a1, (t2 - t) / (t2 - t0)), vmul(a2, (t - t0) / (t2 - t0)));
            vec b2 = vadd(vmul(a2, (t3 - t) / (t3 - t1)), vmul(a3, (t - t1) / (t3 - t1)));
            s->pts[s->npts++] = vadd(vmul(b1, (t2 - t) / (t2 - t1)), vmul(b2, (t - t1) / (t2 - t1)));
        }
    }
    s->pts[s->npts++] = wps[nw - 1];
    s->cum[0] = 0;
    for (int i = 1; i < s->npts; i++) s->cum[i] = s->cum[i - 1] + vlen(vsub(s->pts[i], s->pts[i - 1]));
    double prev = 0;
    for (int i = 0; i < s->npts; i++) {
        vec d = vsub(s->pts[i + 1 < s->npts ? i + 1 : s->npts - 1], s->pts[i > 0 ? i - 1 : 0]);
        double a = atan2(d.y, d.x);
        if (i > 0) a = prev + wrap(a - prev, 2 * PI);
        s->ang[i] = a; prev = a;
    }
    s->length = s->cum[s->npts - 1];
}

static void snake_at(const act_state *s, double d, vec *p, double *a) {
    d = dmin(dmax(d, 0), s->length);
    int lo = 0, hi = s->npts - 1;
    while (hi - lo > 1) { int mid = (lo + hi) / 2; if (s->cum[mid] <= d) lo = mid; else hi = mid; }
    double seg = dmax(s->cum[hi] - s->cum[lo], 1e-9);
    double f = (d - s->cum[lo]) / seg;
    *p = vlerp(s->pts[lo], s->pts[hi], f);
    *a = lerp(s->ang[lo], s->ang[hi], f);
}

static void snake_start(engine *e, act_state *s) {
    s->from = e->origin;
    s->to = pick_new_origin(e, e->world.x * 0.25);

    // waypoints swing around the screen centre on a wobbly ellipse,
    // ~1.3 turns, so the train swoops instead of zig-zagging
    vec c = vmul(e->world, 0.5);
    double rx = e->world.x / 2 - 90, ry = e->world.y / 2 - 80;
    vec start = home_world(e, &e->bodies[0]);
    vec wps[8];
    int nw = 0;
    wps[nw++] = start;
    double dir = chance(e, 0.5) ? 1 : -1;
    double theta = atan2((start.y - c.y) / ry, (start.x - c.x) / rx);
    for (int i = 0; i < 6; i++) {
        theta += dir * rnd(e, 1.15, 1.6);
        double r = rnd(e, 0.55, 1.0) * (i % 2 == 0 ? 1 : 0.75);
        wps[nw++] = vadd(c, V(cos(theta) * rx * r, sin(theta) * ry * r));
    }
    wps[nw++] = s->to;
    snake_sample(s, wps, nw);
    s->speed = dmax(380, dmin(620, s->length / 7));

    s->offset[0] = 0;
    for (int j = 1; j < K_BODIES; j++) {
        const body *prev = &e->bodies[j - 1], *cur = &e->bodies[j];
        double ext_prev = dmax(prev->size.x, prev->size.y), ext_cur = dmax(cur->size.x, cur->size.y);
        s->offset[j] = s->offset[j - 1] + ext_prev / 2 + 8.0 + ext_cur / 2;
    }
    for (int i = 0; i < K_BODIES; i++) {
        s->ang_off[i] = 0; s->joined[i] = false; s->join_t[i] = 0; s->rel[i] = false;
        spring(&e->bodies[i], 160, 0.6);
    }
    s->all_released_at = -1;
}

static void snake_update(engine *e, act_state *s, double dt) {
    (void)dt;
    const double ramp = 0.9;
    double tt = dmax(0, s->t - 0.4);
    double lead = tt < ramp ? s->speed * tt * tt / (2 * ramp) : s->speed * (tt - ramp / 2);
    bool all = true;

    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        if (s->rel[i]) {
            b->target = idle_target_at(e, b, s->to); b->target_a = 0;
            continue;
        }
        all = false;
        double d = lead - s->offset[i];
        if (d >= s->length) {
            s->rel[i] = true;
            normalize_angle(b);
            set_spring(b, 70, 0.42, 60, 0.5);
            b->target = idle_target_at(e, b, s->to); b->target_a = 0;
            b->sv = vadd(b->sv, V(3, -4));
        } else if (d > 0) {
            vec qp; double qa;
            snake_at(s, d, &qp, &qa);
            if (!s->joined[i]) {
                s->joined[i] = true;
                s->join_t[i] = s->t;
                double base = b->size.x >= b->size.y ? 0 : PI / 2;
                s->ang_off[i] = base + SYMMETRY * round((b->a - (qa + base)) / SYMMETRY);
                b->sv = vadd(b->sv, V(-3, 4));
            }
            double j = smooth((s->t - s->join_t[i]) / 0.6);
            b->mode = M_SPRING;
            b->k = lerp(40, 900, j); b->zeta = lerp(0.55, 0.85, j);
            b->ak = lerp(40, 700, j); b->azeta = 0.8;
            b->target = qp;
            b->target_a = qa + s->ang_off[i];
        } else {
            b->target = idle_target_at(e, b, s->from); b->target_a = 0;
        }
    }
    if (s->all_released_at < 0 && all) { s->all_released_at = s->t; e->origin = s->to; }
    if (s->all_released_at >= 0 && s->t > s->all_released_at + 2.2) s->done = true;
}

// ---------------------------------------------------------------- dispatch

static void act_begin(engine *e, act_kind kind, double hold_duration) {
    act_state *s = &e->act;
    memset(s, 0, sizeof *s);
    s->kind = kind;
    s->duration = hold_duration;
    for (int i = 0; i < K_BODIES; i++) e->bodies[i].flag = false;
    switch (kind) {
    case ACT_HOLD: hold_start(e, s); break;
    case ACT_ARRIVAL: arrival_start(e, s); break;
    case ACT_BURST: burst_start(e, s); break;
    case ACT_RAIN: rain_start(e, s); break;
    case ACT_SHUFFLE: shuffle_start(e, s); break;
    case ACT_WAVE: wave_start(e, s); break;
    case ACT_MIGRATE: migrate_start(e, s); break;
    case ACT_SNAKE: snake_start(e, s); break;
    }
}

static void act_update(engine *e, double dt) {
    act_state *s = &e->act;
    switch (s->kind) {
    case ACT_HOLD: hold_update(e, s, dt); break;
    case ACT_ARRIVAL: arrival_update(e, s, dt); break;
    case ACT_BURST: burst_update(e, s, dt); break;
    case ACT_RAIN: rain_update(e, s, dt); break;
    case ACT_SHUFFLE: shuffle_update(e, s, dt); break;
    case ACT_WAVE: wave_update(e, s, dt); break;
    case ACT_MIGRATE: migrate_update(e, s, dt); break;
    case ACT_SNAKE: snake_update(e, s, dt); break;
    }
}

static act_kind choose_act(engine *e) {
    if (e->forced_pos < e->forced_len) return e->forced[e->forced_pos++];
    static const act_kind movers[] = {ACT_RAIN, ACT_MIGRATE, ACT_SNAKE};
    static const act_kind all[] = {ACT_RAIN, ACT_MIGRATE, ACT_SNAKE, ACT_BURST, ACT_SHUFFLE, ACT_WAVE};
    const act_kind *pool = e->acts_since_move >= 2 ? movers : all;
    int pool_n = e->acts_since_move >= 2 ? 3 : 6;
    act_kind options[6];
    int n = 0;
    for (int i = 0; i < pool_n; i++) {
        bool recent = false;
        for (int h = e->history_len - 3; h < e->history_len; h++)
            if (h >= 0 && e->history[h % 64] == pool[i]) recent = true;
        if (!recent) options[n++] = pool[i];
    }
    if (n == 0) return pool[rand_int(e, pool_n)];
    return options[rand_int(e, n)];
}

static void next_act(engine *e) {
    act_kind finished = e->act.kind;
    if (moves_logo(finished)) e->acts_since_move = 0;
    else if (finished != ACT_HOLD) e->acts_since_move++;
    if (finished != ACT_HOLD) {
        act_begin(e, ACT_HOLD, e->history_len == 0 ? 5.0 : rnd(e, 5.0, 7.5));
    } else {
        act_kind k = choose_act(e);
        e->history[e->history_len % 64] = k;
        e->history_len++;
        act_begin(e, k, 0);
    }
}

// ---------------------------------------------------------------- simulation

static void integrate(engine *e, double dt) {
    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        switch (b->mode) {
        case M_SPRING: {
            double c = 2 * b->zeta * sqrt(b->k);
            b->v = vadd(b->v, vmul(vsub(vmul(vsub(b->p, b->target), -b->k), vmul(b->v, c)), dt));
            b->p = vadd(b->p, vmul(b->v, dt));
            double ac = 2 * b->azeta * sqrt(b->ak);
            b->av += (-b->ak * (b->a - b->target_a) - ac * b->av) * dt;
            b->a += b->av * dt;
            break;
        }
        case M_BALLISTIC: {
            b->v.y += b->gravity * dt;
            b->v = vmul(b->v, exp(-b->drag * dt));
            b->p = vadd(b->p, vmul(b->v, dt));
            b->av *= exp(-b->ang_drag * dt);
            b->a += b->av * dt;
            if (b->bounce_walls) {
                double r = radius(b) * 0.8;
                if (b->p.x < r) { b->p.x = r; b->v.x = fabs(b->v.x) * 0.85; b->av *= -0.7; }
                if (b->p.x > e->world.x - r) { b->p.x = e->world.x - r; b->v.x = -fabs(b->v.x) * 0.85; b->av *= -0.7; }
                if (b->p.y < r) { b->p.y = r; b->v.y = fabs(b->v.y) * 0.85; b->av *= -0.7; }
                if (b->p.y > e->world.y - r) { b->p.y = e->world.y - r; b->v.y = -fabs(b->v.y) * 0.85; b->av *= -0.7; }
            }
            break;
        }
        case M_SCRIPTED:
        case M_PARKED:
            break;
        }
        if (b->has_scale_override) {
            b->s = b->scale_override; b->sv = V(0, 0);
        } else {
            const double k = 420, c = 2 * 0.28 * sqrt(k);
            b->sv = vadd(b->sv, vmul(vsub(vmul(vsub(b->s, V(1, 1)), -k), vmul(b->sv, c)), dt));
            b->s = vadd(b->s, vmul(b->sv, dt));
        }
    }
}

void engine_step(engine *e, double raw_dt) {
    double dt = dmin(dmax(raw_dt, 0), 1.0 / 15);
    if (dt <= 0) return;
    e->time += dt;
    e->act.t += dt;
    act_update(e, dt);
    if (e->act.done) next_act(e);
    int n = (int)ceil(dt * 240);
    if (n < 1) n = 1;
    double h = dt / n;
    for (int i = 0; i < n; i++) integrate(e, h);
}

void engine_resize(engine *e, double width, double height) {
    double w = dmax(width, 1), h = dmax(height, 1);
    vec full = vmul(e->logo_half, 2);
    e->unit = dmin(h * 0.3 / full.y, w * 0.42 / full.x);
    vec old = e->world;
    e->world = V(w / e->unit, h / e->unit);
    if (old.x != e->world.x || old.y != e->world.y) {
        vec lo = vadd(e->logo_half, V(20, 20)), hi = vsub(vsub(e->world, e->logo_half), V(20, 20));
        if (e->origin.x < lo.x || e->origin.x > hi.x || e->origin.y < lo.y || e->origin.y > hi.y)
            e->origin = vmul(e->world, 0.5);
    }
}

void engine_init(engine *e, double width, double height, uint64_t seed) {
    memset(e, 0, sizeof *e);
    e->rng = seed;
    e->world = V(1000, 600);
    // Re-centre everything on the bounding box of the symbol.
    vec lo = V(1e9, 1e9), hi = V(-1e9, -1e9);
    for (int i = 0; i < K_BODIES; i++) {
        lo = V(dmin(lo.x, BARS[i].x), dmin(lo.y, BARS[i].y));
        hi = V(dmax(hi.x, BARS[i].x + BARS[i].w), dmax(hi.y, BARS[i].y + BARS[i].h));
    }
    vec c = vmul(vadd(lo, hi), 0.5);
    e->logo_half = vmul(vsub(hi, lo), 0.5);
    for (int i = 0; i < K_BODIES; i++) {
        body *b = &e->bodies[i];
        b->index = i;
        b->rgb = BARS[i].rgb;
        b->size = V(BARS[i].w, BARS[i].h);
        b->home = vsub(V(BARS[i].x + BARS[i].w / 2, BARS[i].y + BARS[i].h / 2), c);
        b->s = V(1, 1);
        b->k = 140; b->zeta = 0.6; b->ak = 140; b->azeta = 0.6;
        b->phase = i * 0.7 + b->home.x * 0.02;
    }
    engine_resize(e, width, height);
    e->origin = vmul(e->world, 0.5);
    act_begin(e, ACT_ARRIVAL, 0);
}

void engine_force_acts(engine *e, const act_kind *acts, int n) {
    if (n > 32) n = 32;
    memcpy(e->forced, acts, sizeof(act_kind) * n);
    e->forced_len = n;
    e->forced_pos = 0;
}
