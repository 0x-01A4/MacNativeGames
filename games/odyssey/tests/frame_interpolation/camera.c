#include <assert.h>
#include <stdatomic.h>
#include "totk_mfx_mode.h"
#include "odyssey_mfx.h"

#include <stdio.h>
#define MLOG(...) do { if (0) printf(__VA_ARGS__); } while (0)
static _Atomic uint64_t g_cur_frame;
typedef struct { uint64_t addr, size; } p_bind_buf;
static struct { p_bind_buf ubo[1][16]; } S;
static struct { int want_cam; } g_mfx;
static int received;
static float observed[84];
static void pend_materialize(uint64_t a, uint8_t *out, size_t n, int depth) {
    (void)depth; memcpy(out, (void *)(uintptr_t)a, n);
}
static void mfx_note_camera(const float *cam, int n) {
    assert(n == 84); memcpy(observed, cam, sizeof observed); received++;
}
/* The Python driver inserts the production mfx_take_camera here. */
PRODUCTION_CAMERA

int main(void) {
    float h[0x180/4] = {0};
    const float c = cosf(.61f), s = sinf(.61f), aspect = 16.f/9, fov = 1.04719755f;
    float view[12] = {c,0,s,1000, 0,1,0,200, -s,0,c,3000};
    memcpy(h, view, sizeof view);
    float fy = 1/tanf(fov/2), fx = fy/aspect;
    for (int i = 0; i < 4; i++) {
        h[24+i]=view[i]*fx; h[28+i]=view[4+i]*fy;
        h[32+i]=view[8+i]; h[36+i]=-view[8+i];
    }
    h[15]=100; h[19]=200; h[23]=300; h[88]=100; h[89]=100000;
    /* Not fixed to Zelda's slot 1. A short and a malformed buffer precede the camera. */
    S.ubo[0][1]=(p_bind_buf){(uintptr_t)h,16};
    S.ubo[0][7]=(p_bind_buf){(uintptr_t)h,sizeof h};
    mfx_take_camera(); assert(received==1);
    assert(fabsf(observed[70]-fov)<1e-5f && fabsf(observed[62]-aspect)<1e-5f);
    assert(observed[47]==100 && observed[51]==200 && observed[55]==300);
    assert(observed[8]==view[8] && observed[10]==view[10]);
    /* Pending/current uniform bytes, not a cached camera. Invalid input publishes nothing. */
    h[15]=400; mfx_take_camera(); assert(received==2 && observed[47]==400);
    h[28]=NAN; mfx_take_camera(); assert(received==2);
    h[28]=0; memset(h+24,0,16*sizeof(float)); mfx_take_camera(); assert(received==2);
    double a[84]={0}, b[84]={0}; a[10]=b[10]=1;
    a[47]=20; assert(!odyssey_mfx_cut(a,b));
    a[47]=900; assert(odyssey_mfx_cut(a,b));
    a[47]=0; a[10]=0; assert(odyssey_mfx_cut(a,b));
    a[10]=1; a[47]=NAN; assert(odyssey_mfx_cut(a,b));
    for (int req=0;req<MFX_NMODES;req++) for (int hz=0;hz<=240;hz++)
        assert(odyssey_mfx_mode(req,hz)==(req && hz==120 ? MFX_HALF : MFX_OFF));
    /* The 60+60 pacing itself (a 1/60 s game period on our own clock) is checked by probe-gfx's present-interval probe. */
    /* A second, different block that also passes (e.g. a rotation-only model matrix) never replaces the first. */
    for (int i = 0; i < 4; i++) {
        h[24+i]=view[i]*fx; h[28+i]=view[4+i]*fy;
        h[32+i]=view[8+i]; h[36+i]=-view[8+i];
    }
    float other[0x180/4]; memcpy(other,h,sizeof other); other[15]=-5000;
    other[0]=1; other[2]=0; other[8]=0; other[10]=1;   /* a different, still orthonormal rotation */
    S.ubo[0][9]=(p_bind_buf){(uintptr_t)other,sizeof other};
    int before=received; mfx_take_camera(); assert(received==before+1 && observed[47]==400);
    S.ubo[0][7]=(p_bind_buf){0,0}; mfx_take_camera(); assert(received==before+2 && observed[47]==-5000);
    /* Display link: 60+60 lifts only the 60 Hz request to the 120 Hz range; off, the request comes back unchanged. */
    for (int want=0;want<=3;want++) for (int m=0;m<MFX_NMODES;m++)
        assert(odyssey_link_mode(want,m)==(want==1 && m==MFX_HALF ? 2 : want));
    /* Scene canvas: the FXAA draw counts only once encoded. Skipped (no pipeline yet / compiling in the background):
       the next draw clears it and the frame has no scene. Encoded: its canvas, until the frame ends. */
    odyssey_scene sc={0};
    odyssey_scene_draw(&sc); odyssey_scene_fxaa(&sc,77);
    odyssey_scene_draw(&sc); assert(!sc.ready && odyssey_scene_drawn(&sc)==0 && !sc.ready);
    odyssey_scene_draw(&sc); odyssey_scene_fxaa(&sc,77); assert(!sc.ready);
    assert(odyssey_scene_drawn(&sc)==77 && sc.ready && !sc.pending);
    odyssey_scene_draw(&sc); assert(sc.ready && odyssey_scene_drawn(&sc)==0 && sc.ready);
    odyssey_scene_frame(&sc); assert(!sc.ready && !sc.pending);
    assert(odyssey_mfx_fxaa("5345f3231650f0b7-variant"));
    assert(!odyssey_mfx_fxaa("addef5ac") && !odyssey_mfx_fxaa(NULL));
    return 0;
}
