#include "game_patches.h"
#include <stdint.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ODYSSEY_RENDER_RES=<w>x<h> (16:9, 1600x900 .. 2240x1260): the docked render size (RESOLUTION_RESEARCH.md option B).
   1.3.0 builds its framework and canvas at 1600x900 in code, at three sites, and the game data's docked size does not
   resize the scene on its own (gate run, 26 October: with a ProjectGraphicsQuality.byml overlay at 1920x1080 every scene
   target stayed 1600x900). Here the sites take the new size, so the scene, the canvas, the swapchain and the UI are all
   composed at it and MetalFX gets more real pixels; the render-target allocator and agl's heap grow with the pixel count
   (and the application pool with them, runtime_output_res_extra_bytes). Every original word is checked first: on any
   mismatch nothing is patched. Pair it with scripts/make_resolution_overlay.py <w>x<h> (the data's docked size and its
   dynamic-resolution steps) so the two agree; without it the scene stays 1600x900 (gate run C1). Measured 26 October with
   the table: 1920x1080 and 2240x1260 run (16.7 ms frames); 2400x1350 and 2560x1440 stop the game with an SDK Break after
   the first frame (some other fixed-size heap; not found yet), so the size is capped at 2240x1260. */
static unsigned render_w, render_h;
static int render_res(unsigned *w, unsigned *h) {
    static int done, ok; static unsigned rw, rh;
    if (!done) {
        done = 1; const char *e = getenv("ODYSSEY_RENDER_RES");
        if (e && sscanf(e, "%ux%u", &rw, &rh) == 2 && rw >= 1600 && rw <= 2240 && rh >= 900 && rh <= 1260 && rw * 9 == rh * 16 && !(rw & 7) && !(rh & 1)) ok = rw != 1600;
        else if (e) fprintf(stderr, "[odyssey] ODYSSEY_RENDER_RES=%s ignored: a 16:9 size from 1600x900 to 2240x1260, width a multiple of 8\n", e);
    }
    if (ok) { *w = rw; *h = rh; }
    return ok;
}
static uint32_t movz64(unsigned rd, unsigned v) { return 0xd2800000u | v << 5 | rd; }                 /* mov xd, #v */
static uint32_t movk64_32(unsigned rd, unsigned v) { return 0xf2c00000u | v << 5 | rd; }             /* movk xd, #v, lsl #32 */
static uint32_t movz32(unsigned rd, unsigned v) { return 0x52800000u | v << 5 | rd; }                 /* mov wd, #v */
static uint32_t movz32_16(unsigned rd, unsigned v) { return 0x52a00000u | v << 5 | rd; }              /* mov wd, #v, lsl #16 */
static void patch_render_res(Module *m) {
    unsigned w, h; if (!render_res(&w, &h)) return;
    double grow = (double)w * h / (1600.0 * 900.0);
    unsigned alloc_mib = (unsigned)(100 * grow + 0.5) + 20, agl_mib = 170 + (alloc_mib - 100);   /* 100 MiB allocator, 170 MiB AglHeap at 1600x900 */
    struct { uint64_t off; uint32_t original, replacement; const char *what; } sites[] = {
        {0x4bf2a4, movz64(9, 1600), movz64(9, w), "framework create-args width (fn_4bf140)"},
        {0x4bf2a8, movk64_32(9, 900), movk64_32(9, h), "framework create-args height"},
        {0x4bf34c, movz32(4, 1600), movz32(4, w), "fn_624ad0 docked width"},
        {0x4bf350, movz32(5, 900), movz32(5, h), "fn_624ad0 docked height"},
        {0x4e27bc, movz32(3, 1600), movz32(3, w), "GameSystem::vf4 console viewport width"},
        {0x4e27c0, movz32(4, 900), movz32(4, h), "GameSystem::vf4 console viewport height"},
        {0x624b7c, movz32_16(8, 0x640), movz32_16(8, alloc_mib << 4), "agl DynamicTextureAllocator 100 MiB"},
        {0x624b4c, movz32_16(0, 0xaa0), movz32_16(0, agl_mib << 4), "AglHeap 170 MiB"},
    };
    enum { N = sizeof sites / sizeof sites[0] };
    for (int i = 0; i < N; i++) {
        uint32_t word; if (sites[i].off + 4 > m->size) { fprintf(stderr, "[odyssey] render resolution: main too small\n"); return; }
        memcpy(&word, m->base + sites[i].off, 4);
        if (word != sites[i].original) {
            fprintf(stderr, "[odyssey] render resolution: main+%#llx is %08x, expected %08x (%s): not patched, the game renders at 1600x900\n",
                    (unsigned long long)sites[i].off, word, sites[i].original, sites[i].what);
            return;
        }
    }
    for (int i = 0; i < N; i++) memcpy(m->base + sites[i].off, &sites[i].replacement, 4);
    __builtin___clear_cache((char *)m->base + 0x4bf2a4, (char *)m->base + 0x624b80);
    render_w = w; render_h = h;
    fprintf(stderr, "[odyssey] render resolution %ux%u: framework, docked size and console viewport patched (6 sites); render-target allocator %u MiB, AglHeap %u MiB\n", w, h, alloc_mib, agl_mib);
}
void runtime_game_patches(Module *main_module) { patch_render_res(main_module); }
void runtime_frame_step_pin(double ms) { (void)ms; }
void runtime_frame_step_update(uint64_t now_ns) { (void)now_ns; }
int runtime_output_res(unsigned *w, unsigned *h) { (void)w; (void)h; return 0; }
uint64_t runtime_output_res_extra_bytes(void) {   /* the application pool grows by the allocator and heap growth (patch_render_res) */
    unsigned w, h; if (!render_res(&w, &h)) return 0;
    double grow = (double)w * h / (1600.0 * 900.0); unsigned extra_mib = 2 * ((unsigned)(100 * grow + 0.5) + 20 - 100);
    return (uint64_t)extra_mib << 20;
}
uint64_t runtime_output_size_current(void) { return (uint64_t)1080 << 32 | 1920; }
int runtime_output_res_toggle(void) { return 0; }
/* Key 3: anti-aliasing (third_party/d2r_gfx/gfx/nvn/odyssey_gfx.h; keys 4-7 are the other graphics settings). */
int dm_gfx_opt_cycle(int which);
int runtime_output_mode_cycle(void) { return dm_gfx_opt_cycle(0) + 1; }
int runtime_aspect_toggle(void) { return 0; }
float runtime_aspect_now(void) { return 0; }
