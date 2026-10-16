// SPDX-License-Identifier: GPL-3.0-or-later
// kurtos-saver-render — headless tool around the bar engine (no SDL needed).
//
//   frames <outdir> <seconds> <fps> <w> <h> [acts] [seed]   PPM frame sequence (for videos)
//   at     <out.ppm> <seconds> <w> <h> [acts] [seed]          one frame at a point in time
//   still  <out.ppm> <w> <h> [scale]                          logo at rest, centred
//   trace  <seconds> <fps> <w> <h> [acts] [seed]              per-frame bar poses, logo units
//                                                             relative to the logo centre
//
// Pixels are drawn with 4×4 supersampled coverage on true black.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine.h"

typedef struct { int w, h; unsigned char *px; } canvas;

static void clear(canvas *c) { memset(c->px, 0, (size_t)c->w * c->h * 3); }

/// Fills a rotated, scaled rectangle centred at (cx, cy) in pixels.
static void fill_bar(canvas *c, double cx, double cy, double hw, double hh, double a, unsigned rgb) {
    double cs = cos(a), sn = sin(a);
    double ex = fabs(hw * cs) + fabs(hh * sn), ey = fabs(hw * sn) + fabs(hh * cs);
    int x0 = (int)floor(cx - ex) - 1, x1 = (int)ceil(cx + ex) + 1;
    int y0 = (int)floor(cy - ey) - 1, y1 = (int)ceil(cy + ey) + 1;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > c->w) x1 = c->w;
    if (y1 > c->h) y1 = c->h;
    const unsigned char col[3] = {(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF};
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            int hits = 0;
            for (int sy = 0; sy < 4; sy++) {
                for (int sx = 0; sx < 4; sx++) {
                    double dx = x + (sx + 0.5) / 4 - cx, dy = y + (sy + 0.5) / 4 - cy;
                    double lx = dx * cs + dy * sn, ly = -dx * sn + dy * cs;   // into bar space
                    if (fabs(lx) <= hw && fabs(ly) <= hh) hits++;
                }
            }
            if (!hits) continue;
            double k = hits / 16.0;
            unsigned char *p = c->px + ((size_t)y * c->w + x) * 3;
            for (int i = 0; i < 3; i++) p[i] = (unsigned char)lround(p[i] * (1 - k) + col[i] * k);
        }
    }
}

static void draw(canvas *c, const engine *e) {
    clear(c);
    for (int i = K_BODIES - 1; i >= 0; i--) {
        const body *b = &e->bodies[i];
        fill_bar(c, b->p.x * e->unit, b->p.y * e->unit,
                 b->size.x / 2 * b->s.x * e->unit, b->size.y / 2 * b->s.y * e->unit, b->a, b->rgb);
    }
}

static int write_ppm(const char *path, const canvas *c) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return 1; }
    fprintf(f, "P6\n%d %d\n255\n", c->w, c->h);
    fwrite(c->px, 3, (size_t)c->w * c->h, f);
    fclose(f);
    return 0;
}

static int parse_acts(const char *list, act_kind *out) {
    char tmp[256];
    snprintf(tmp, sizeof tmp, "%s", list);
    int n = 0;
    for (char *tok = strtok(tmp, ","); tok && n < 32; tok = strtok(NULL, ",")) {
        if (!act_from_name(tok, &out[n])) { fprintf(stderr, "unknown act '%s'\n", tok); exit(2); }
        n++;
    }
    return n;
}

static void setup(engine *e, int w, int h, int argc, char **argv, int acts_at) {
    unsigned long long seed = argc > acts_at + 1 ? strtoull(argv[acts_at + 1], NULL, 10) : 7;
    engine_init(e, w, h, seed);
    if (argc > acts_at && argv[acts_at][0]) {
        act_kind acts[32];
        int n = parse_acts(argv[acts_at], acts);
        engine_force_acts(e, acts, n);
    }
}

int main(int argc, char **argv) {
    if (argc >= 7 && !strcmp(argv[1], "frames")) {
        const char *out = argv[2];
        double seconds = atof(argv[3]), fps = atof(argv[4]);
        int w = atoi(argv[5]), h = atoi(argv[6]);
        engine e;
        setup(&e, w, h, argc, argv, 7);
        canvas c = {w, h, malloc((size_t)w * h * 3)};
        int frames = (int)(seconds * fps);
        char path[1024];
        for (int f = 0; f < frames; f++) {
            for (int s = 0; s < 4; s++) engine_step(&e, 1 / fps / 4);
            draw(&c, &e);
            snprintf(path, sizeof path, "%s/f%05d.ppm", out, f);
            if (write_ppm(path, &c)) return 1;
        }
        fprintf(stderr, "rendered %d frames\n", frames);
        return 0;
    }
    if (argc >= 6 && !strcmp(argv[1], "at")) {
        double seconds = atof(argv[3]);
        int w = atoi(argv[4]), h = atoi(argv[5]);
        engine e;
        setup(&e, w, h, argc, argv, 6);
        for (int f = 0; f < (int)(seconds * 120); f++) engine_step(&e, 1.0 / 120);
        canvas c = {w, h, malloc((size_t)w * h * 3)};
        draw(&c, &e);
        return write_ppm(argv[2], &c);
    }
    if (argc >= 5 && !strcmp(argv[1], "still")) {
        int w = atoi(argv[3]), h = atoi(argv[4]);
        double scale = argc > 5 ? atof(argv[5]) : 1;
        engine e;
        engine_init(&e, w, h, 1);
        e.unit *= scale;
        canvas c = {w, h, malloc((size_t)w * h * 3)};
        clear(&c);
        for (int i = K_BODIES - 1; i >= 0; i--) {
            const body *b = &e.bodies[i];
            fill_bar(&c, w / 2.0 + b->home.x * e.unit, h / 2.0 + b->home.y * e.unit,
                     b->size.x / 2 * e.unit, b->size.y / 2 * e.unit, 0, b->rgb);
        }
        return write_ppm(argv[2], &c);
    }
    if (argc >= 6 && !strcmp(argv[1], "trace")) {
        double seconds = atof(argv[2]), fps = atof(argv[3]);
        int w = atoi(argv[4]), h = atoi(argv[5]);
        engine e;
        setup(&e, w, h, argc, argv, 6);
        int frames = (int)(seconds * fps);
        printf("# frames=%d fps=%g world=%.2fx%.2f; per bar: x y angle sx sy (logo units from logo centre)\n",
               frames, fps, e.world.x, e.world.y);
        for (int f = 0; f < frames; f++) {
            for (int s = 0; s < 4; s++) engine_step(&e, 1 / fps / 4);
            for (int i = 0; i < K_BODIES; i++) {
                const body *b = &e.bodies[i];
                printf("%s%.2f %.2f %.4f %.3f %.3f", i ? " | " : "",
                       b->p.x - e.origin.x, b->p.y - e.origin.y, b->a, b->s.x, b->s.y);
            }
            printf("\n");
        }
        return 0;
    }
    fprintf(stderr,
            "usage:\n  %s frames <outdir> <seconds> <fps> <w> <h> [acts] [seed]\n"
            "  %s at <out.ppm> <seconds> <w> <h> [acts] [seed]\n"
            "  %s still <out.ppm> <w> <h> [scale]\n"
            "  %s trace <seconds> <fps> <w> <h> [acts] [seed]\n", argv[0], argv[0], argv[0], argv[0]);
    return 2;
}
