// SPDX-License-Identifier: GPL-3.0-or-later
// kurtos-screensaver — fullscreen SDL3 frontend for the ralleur bar engine.
//
// Launched once per monitor by kurtos' omarchy-launch-screensaver override.
// The window uses Omarchy's screensaver class, so Omarchy's Hyprland window
// rules (fullscreen, special workspace) and the shell idle service treat it
// exactly like the stock terminal screensaver.
//
// usage: kurtos-screensaver [--class org.omarchy.screensaver] [--windowed] [--seed N] [--acts a,b,c]
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine.h"

#define SCREENSAVER_CLASS "org.omarchy.screensaver"
#define INPUT_GRACE_NS SDL_MS_TO_NS(600)      // ignore the key/mouse that started us
#define FOCUS_GRACE_NS SDL_MS_TO_NS(3000)    // the launcher hops focus across monitors first
#define MOTION_THRESHOLD 24.0f                  // pixels of deliberate mouse movement

typedef struct {
    SDL_Texture *tex[K_BODIES];
    int tw[K_BODIES], th[K_BODIES];
    double unit;
} bar_sprites;

/// One white alpha mask per bar, sized to its on-screen pixels with an
/// analytic one-pixel coverage ramp, so linear sampling antialiases the edges
/// even while the bars rotate and squash.
static void build_sprites(SDL_Renderer *r, const engine *e, bar_sprites *bs) {
    for (int i = 0; i < K_BODIES; i++) {
        if (bs->tex[i]) SDL_DestroyTexture(bs->tex[i]);
        double W = e->bodies[i].size.x * e->unit, H = e->bodies[i].size.y * e->unit;
        int tw = (int)ceil(W) + 4, th = (int)ceil(H) + 4;
        Uint32 *px = SDL_malloc((size_t)tw * th * 4);
        for (int y = 0; y < th; y++) {
            double cy = fabs(y + 0.5 - th / 2.0);
            double ay = SDL_clamp(H / 2 - cy + 0.5, 0.0, 1.0);
            for (int x = 0; x < tw; x++) {
                double cx = fabs(x + 0.5 - tw / 2.0);
                double ax = SDL_clamp(W / 2 - cx + 0.5, 0.0, 1.0);
                Uint32 a = (Uint32)lround(ax * ay * 255);
                px[y * tw + x] = (a << 24) | 0xFFFFFF;
            }
        }
        SDL_Texture *t = SDL_CreateTexture(r, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC, tw, th);
        SDL_UpdateTexture(t, NULL, px, tw * 4);
        SDL_SetTextureBlendMode(t, SDL_BLENDMODE_BLEND);
        SDL_SetTextureScaleMode(t, SDL_SCALEMODE_LINEAR);
        SDL_free(px);
        bs->tex[i] = t; bs->tw[i] = tw; bs->th[i] = th;
    }
    bs->unit = e->unit;
}

static void draw(SDL_Renderer *r, const engine *e, const bar_sprites *bs) {
    SDL_SetRenderDrawColor(r, 0, 0, 0, 255);   // true black: idle OLED pixels stay off
    SDL_RenderClear(r);
    for (int i = K_BODIES - 1; i >= 0; i--) {  // index 0 (blue) ends up on top
        const body *b = &e->bodies[i];
        float cx = (float)(b->p.x * e->unit), cy = (float)(b->p.y * e->unit);
        float hx = (float)(bs->tw[i] / 2.0 * b->s.x), hy = (float)(bs->th[i] / 2.0 * b->s.y);
        float c = (float)cos(b->a), s = (float)sin(b->a);
        SDL_FColor col = {((b->rgb >> 16) & 0xFF) / 255.0f, ((b->rgb >> 8) & 0xFF) / 255.0f, (b->rgb & 0xFF) / 255.0f, 1};
        const float lx[4] = {-hx, hx, hx, -hx}, ly[4] = {-hy, -hy, hy, hy};
        const float u[4] = {0, 1, 1, 0}, v[4] = {0, 0, 1, 1};
        SDL_Vertex vert[4];
        for (int k = 0; k < 4; k++) {
            vert[k].position.x = cx + lx[k] * c - ly[k] * s;
            vert[k].position.y = cy + lx[k] * s + ly[k] * c;
            vert[k].color = col;
            vert[k].tex_coord.x = u[k];
            vert[k].tex_coord.y = v[k];
        }
        static const int idx[6] = {0, 1, 2, 0, 2, 3};
        SDL_RenderGeometry(r, bs->tex[i], vert, 4, idx, 6);
    }
    SDL_RenderPresent(r);
}

/// Omarchy ends every screensaver at once (one per monitor) by matching the
/// class in their command lines; ours carry it through --class.
static void quit_all_screensavers(void) {
    int rc = system("pkill -f '[o]rg.omarchy.screensaver' >/dev/null 2>&1");
    (void)rc;
}

/// Like omarchy-screensaver: leave when focus moved to something that is not
/// a screensaver (a notification action, a workspace switch, ...).
static bool screensaver_in_focus(void) {
    FILE *f = popen("hyprctl activewindow -j 2>/dev/null", "r");
    if (!f) return true;
    char buf[8192];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    buf[n] = 0;
    pclose(f);
    if (n == 0) return true;   // hyprctl unavailable: don't guess
    return strstr(buf, "\"class\": \"" SCREENSAVER_CLASS "\"") != NULL;
}

static int parse_acts(const char *list, act_kind *out, int max) {
    char tmp[256];
    SDL_strlcpy(tmp, list, sizeof tmp);
    int n = 0;
    for (char *tok = strtok(tmp, ","); tok && n < max; tok = strtok(NULL, ",")) {
        act_kind k;
        if (act_from_name(tok, &k)) out[n++] = k;
        else fprintf(stderr, "kurtos-screensaver: unknown act '%s'\n", tok);
    }
    return n;
}

int main(int argc, char **argv) {
    bool windowed = false, launched = false;
    Uint64 seed = 0;
    act_kind acts[32];
    int nacts = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--windowed")) windowed = true;
        else if (!strcmp(argv[i], "--class") && i + 1 < argc) { launched = !strcmp(argv[++i], SCREENSAVER_CLASS); }
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--acts") && i + 1 < argc) nacts = parse_acts(argv[++i], acts, 32);
        else { fprintf(stderr, "usage: %s [--class %s] [--windowed] [--seed N] [--acts a,b,c]\n", argv[0], SCREENSAVER_CLASS); return 2; }
    }

    // Wayland app_id = Hyprland window class.
    SDL_SetHint(SDL_HINT_APP_ID, SCREENSAVER_CLASS);
    SDL_SetHint(SDL_HINT_APP_NAME, "KurtOS Screensaver");
    // SDL inhibits idle by default; the screensaver must let the lock and DPMS timers keep running.
    SDL_SetHint(SDL_HINT_VIDEO_ALLOW_SCREENSAVER, "1");

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD)) {
        fprintf(stderr, "kurtos-screensaver: SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    SDL_WindowFlags flags = SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE;
    if (!windowed) flags |= SDL_WINDOW_FULLSCREEN;
    SDL_Window *win;
    SDL_Renderer *ren;
    if (!SDL_CreateWindowAndRenderer("KurtOS Screensaver", 1280, 720, flags, &win, &ren)) {
        fprintf(stderr, "kurtos-screensaver: window failed: %s\n", SDL_GetError());
        return 1;
    }
    SDL_SetRenderVSync(ren, 1);
    if (!windowed) SDL_HideCursor();

    int pw, ph;
    SDL_GetRenderOutputSize(ren, &pw, &ph);
    if (seed == 0) seed = SDL_GetPerformanceCounter() ^ ((Uint64)SDL_GetCurrentThreadID() << 32);
    engine e;
    engine_init(&e, pw, ph, seed);
    if (nacts) engine_force_acts(&e, acts, nacts);

    bar_sprites bs = {0};
    build_sprites(ren, &e, &bs);

    const bool hyprland = SDL_getenv("HYPRLAND_INSTANCE_SIGNATURE") != NULL;
    const Uint64 started = SDL_GetTicksNS();
    Uint64 last = started, last_focus_check = started;
    float motion = 0;
    bool running = true, wake = false;

    while (running) {
        SDL_Event ev;
        const bool armed = SDL_GetTicksNS() - started > INPUT_GRACE_NS;
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_EVENT_QUIT:
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                running = false;
                break;
            case SDL_EVENT_KEY_DOWN:
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
            case SDL_EVENT_MOUSE_WHEEL:
            case SDL_EVENT_FINGER_DOWN:
            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                if (armed) wake = true;
                break;
            case SDL_EVENT_MOUSE_MOTION:
                if (armed) {
                    motion += fabsf(ev.motion.xrel) + fabsf(ev.motion.yrel);
                    if (motion > MOTION_THRESHOLD) wake = true;
                }
                break;
            case SDL_EVENT_GAMEPAD_ADDED:
                SDL_OpenGamepad(ev.gdevice.which);
                break;
            case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                SDL_GetRenderOutputSize(ren, &pw, &ph);
                engine_resize(&e, pw, ph);
                build_sprites(ren, &e, &bs);
                break;
            default:
                break;
            }
        }

        Uint64 now = SDL_GetTicksNS();
        if (hyprland && launched && now - started > FOCUS_GRACE_NS && now - last_focus_check > SDL_NS_PER_SECOND) {
            last_focus_check = now;
            if (!screensaver_in_focus()) wake = true;
        }
        if (wake) break;

        engine_step(&e, (double)(now - last) / SDL_NS_PER_SECOND);
        last = now;
        if (e.unit != bs.unit) build_sprites(ren, &e, &bs);
        draw(ren, &e, &bs);

        // Test hook: KURTOS_SAVER_SNAPSHOT=<file.bmp> saves the frame at 3 s and exits.
        const char *snap = SDL_getenv("KURTOS_SAVER_SNAPSHOT");
        if (snap && now - started > SDL_MS_TO_NS(3000)) {
            SDL_Surface *shot = SDL_RenderReadPixels(ren, NULL);
            if (shot) { SDL_SaveBMP(shot, snap); SDL_DestroySurface(shot); }
            break;
        }
    }

    SDL_ShowCursor();
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    if (wake && launched) quit_all_screensavers();
    return 0;
}
