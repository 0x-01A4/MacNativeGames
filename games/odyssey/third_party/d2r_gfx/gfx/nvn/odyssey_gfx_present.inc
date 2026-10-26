/* Odyssey graphics settings, the present part (odyssey_gfx.h has the settings; nvn_mtl.m includes this before
   present_encode_m4). The game picture goes through, in order:
     anti-aliasing (key 3) at the picture's own size into gx_aa[slot]  ->  the upscale to the viewport (key 5): MetalFX
     (output_upscale), or FSR 1 EASU / Lanczos-2 drawn by a shader, or the bilinear blit  ->  CAS (key 4) on the result.
   A stage that is off costs nothing; a shader upscale followed by CAS goes through gx_up[slot] (the viewport's size).
   The passes read their constants from the slot's present buffer: the final draw at 0 (its Crop as before), the
   anti-aliasing pass at 96, the upscale pass at 192. Two timestamps per slot bracket the whole picture work (after a
   barrier that waits for the game's frame), for the HUD's "picture" figure. */
#define GX_PASS_A 96
#define GX_PASS_B 192
#define GX_UV_BYTES 288
static const char *gx_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    // rect/edge: the input's valid region in UV (as the blit's Crop); region: the same in texels (x, y, w, h); outsz: the pass's output size
    "struct GP { float4 rect; float4 edge; float4 region; float4 outsz; float sharp; float3 pad; };\n"
    "static float3 tap(texture2d<float> t, sampler s, constant GP& c, float2 uv, float2 d) { return t.sample(s, clamp(uv + d, c.edge.xy, c.edge.zw)).rgb; }\n"
    "static float luma(float3 v) { return dot(v, float3(0.299, 0.587, 0.114)); }\n"
    "static float2 in_uv(V in, constant GP& c) { return clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw); }\n"
    // FXAA (3.11-style console variant) at the input's own resolution
    "fragment float4 fs_fxaa(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant GP& c [[buffer(0)]]) {\n"
    "  float2 uv = in_uv(in, c), px = 1.0 / float2(t.get_width(), t.get_height());\n"
    "  float4 o = t.sample(s, uv); float3 m = o.rgb;\n"
    "  float3 nw = tap(t, s, c, uv, px * float2(-1, -1)), ne = tap(t, s, c, uv, px * float2(1, -1)), sw = tap(t, s, c, uv, px * float2(-1, 1)), se = tap(t, s, c, uv, px * float2(1, 1));\n"
    "  float lnw = luma(nw), lne = luma(ne), lsw = luma(sw), lse = luma(se), lm = luma(m);\n"
    "  float lmin = min(lm, min(min(lnw, lne), min(lsw, lse))), lmax = max(lm, max(max(lnw, lne), max(lsw, lse)));\n"
    "  if (lmax - lmin < max(0.0312, lmax * 0.125)) return o;\n"
    "  float2 dir = float2(-((lnw + lne) - (lsw + lse)), (lnw + lsw) - (lne + lse));\n"
    "  float red = max((lnw + lne + lsw + lse) * (0.25 / 8.0), 1.0 / 128.0);\n"
    "  dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + red), float2(-8), float2(8)) * px;\n"
    "  float3 ra = 0.5 * (tap(t, s, c, uv, dir * (1.0 / 3.0 - 0.5)) + tap(t, s, c, uv, dir * (2.0 / 3.0 - 0.5)));\n"
    "  float3 rb = ra * 0.5 + 0.25 * (tap(t, s, c, uv, dir * -0.5) + tap(t, s, c, uv, dir * 0.5));\n"
    "  float lb = luma(rb); return float4((lb < lmin || lb > lmax) ? ra : rb, o.a); }\n"
    // CAS (after AMD FidelityFX CAS): taps one input texel apart
    "fragment float4 fs_cas(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant GP& c [[buffer(0)]]) {\n"
    "  float2 uv = in_uv(in, c), px = 1.0 / float2(t.get_width(), t.get_height());\n"
    "  float4 o = t.sample(s, uv); float3 e = o.rgb;\n"
    "  float3 a = tap(t, s, c, uv, float2(0, -px.y)), b = tap(t, s, c, uv, float2(-px.x, 0)), f = tap(t, s, c, uv, float2(px.x, 0)), h = tap(t, s, c, uv, float2(0, px.y));\n"
    "  float3 mn = min(min(min(a, b), min(f, h)), e), mx = max(max(max(a, b), max(f, h)), e);\n"
    "  float3 amp = sqrt(saturate(min(mn, 2.0 - mx) / max(mx, 1e-5)));\n"
    "  float3 w = amp * (-1.0 / mix(8.0, 5.0, saturate(c.sharp)));\n"
    "  return float4(saturate(((a + b + f + h) * w + e) / (1.0 + 4.0 * w)), o.a); }\n"
    // FSR 1 EASU (after AMD FidelityFX Super Resolution 1.0, MIT): 12 taps, a direction and a length from the four
    // centre quads, a stretched Lanczos-2 approximation along the edge, the result clamped to the centre 2x2 (no ringing)
    "static float3 rd(texture2d<float> t, constant GP& c, int2 p) { int2 lo = int2(c.region.xy), hi = lo + int2(c.region.zw) - 1; return t.read(uint2(clamp(p, lo, hi))).rgb; }\n"
    "static float lum2(float3 v) { return v.b * 0.5 + (v.r * 0.5 + v.g); }\n"
    "static void easu_set(thread float2& dir, thread float& len, float w, float lA, float lB, float lC, float lD, float lE) {\n"
    "  float dc = lD - lC, cb = lC - lB, lenX = max(abs(dc), abs(cb)); lenX = 1.0 / max(lenX, 1e-5); float dirX = lD - lB; dir.x += dirX * w;\n"
    "  lenX = saturate(abs(dirX) * lenX); lenX *= lenX; len += lenX * w;\n"
    "  float ec = lE - lC, ca = lC - lA, lenY = max(abs(ec), abs(ca)); lenY = 1.0 / max(lenY, 1e-5); float dirY = lE - lA; dir.y += dirY * w;\n"
    "  lenY = saturate(abs(dirY) * lenY); lenY *= lenY; len += lenY * w; }\n"
    "static void easu_tap(thread float3& ac, thread float& aw, float2 off, float2 dir, float2 len2, float lob, float clp, float3 cv) {\n"
    "  float2 v = float2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len2;\n"
    "  float d2 = min(dot(v, v), clp), wB = 0.4 * d2 - 1.0, wA = lob * d2 - 1.0; wB *= wB; wA *= wA; wB = 1.5625 * wB - 0.5625;\n"
    "  float w = wB * wA; ac += cv * w; aw += w; }\n"
    "fragment float4 fs_easu(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant GP& c [[buffer(0)]]) {\n"
    "  float2 pp = in.uv * c.region.zw - 0.5 + c.region.xy, fp = floor(pp); pp -= fp; int2 i = int2(fp);\n"
    "  float3 b = rd(t, c, i + int2(0, -1)), cc = rd(t, c, i + int2(1, -1)), e = rd(t, c, i + int2(-1, 0)), f = rd(t, c, i), g = rd(t, c, i + int2(1, 0)), h = rd(t, c, i + int2(2, 0));\n"
    "  float3 ii = rd(t, c, i + int2(-1, 1)), j = rd(t, c, i + int2(0, 1)), k = rd(t, c, i + int2(1, 1)), l = rd(t, c, i + int2(2, 1)), n = rd(t, c, i + int2(0, 2)), o = rd(t, c, i + int2(1, 2));\n"
    "  float bL = lum2(b), cL = lum2(cc), eL = lum2(e), fL = lum2(f), gL = lum2(g), hL = lum2(h), iL = lum2(ii), jL = lum2(j), kL = lum2(k), lL = lum2(l), nL = lum2(n), oL = lum2(o);\n"
    "  float2 dir = 0.0; float len = 0.0;\n"
    "  easu_set(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);\n"
    "  easu_set(dir, len, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);\n"
    "  easu_set(dir, len, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);\n"
    "  easu_set(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);\n"
    "  float dirR = dot(dir, dir); bool zro = dirR < 1.0 / 32768.0; dirR = rsqrt(max(dirR, 1e-12)); dirR = zro ? 1.0 : dirR; dir.x = zro ? 1.0 : dir.x; dir *= dirR;\n"
    "  len = len * 0.5; len *= len;\n"
    "  float stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));\n"
    "  float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);\n"
    "  float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len, clp = 1.0 / lob;\n"
    "  float3 ac = 0.0; float aw = 0.0;\n"
    "  easu_tap(ac, aw, float2(0, -1) - pp, dir, len2, lob, clp, b); easu_tap(ac, aw, float2(1, -1) - pp, dir, len2, lob, clp, cc);\n"
    "  easu_tap(ac, aw, float2(-1, 1) - pp, dir, len2, lob, clp, ii); easu_tap(ac, aw, float2(0, 1) - pp, dir, len2, lob, clp, j);\n"
    "  easu_tap(ac, aw, float2(0, 0) - pp, dir, len2, lob, clp, f); easu_tap(ac, aw, float2(-1, 0) - pp, dir, len2, lob, clp, e);\n"
    "  easu_tap(ac, aw, float2(1, 1) - pp, dir, len2, lob, clp, k); easu_tap(ac, aw, float2(2, 1) - pp, dir, len2, lob, clp, l);\n"
    "  easu_tap(ac, aw, float2(2, 0) - pp, dir, len2, lob, clp, h); easu_tap(ac, aw, float2(1, 0) - pp, dir, len2, lob, clp, g);\n"
    "  easu_tap(ac, aw, float2(1, 2) - pp, dir, len2, lob, clp, o); easu_tap(ac, aw, float2(0, 2) - pp, dir, len2, lob, clp, n);\n"
    "  float3 mn = min(min(f, g), min(j, k)), mx = max(max(f, g), max(j, k));\n"
    "  return float4(clamp(ac / max(aw, 1e-5), mn, mx), 1.0); }\n"
    // Lanczos-2: 4x4 taps, clamped to the centre 2x2 like EASU
    "static float lz(float x) { x = abs(x); if (x < 1e-5) return 1.0; if (x >= 2.0) return 0.0; float a = M_PI_F * x; return 2.0 * sin(a) * sin(a * 0.5) / (a * a); }\n"
    "fragment float4 fs_lanczos(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant GP& c [[buffer(0)]]) {\n"
    "  float2 pp = in.uv * c.region.zw - 0.5 + c.region.xy, fp = floor(pp); pp -= fp; int2 i = int2(fp);\n"
    "  float wx[4], wy[4]; for (int k = 0; k < 4; k++) { wx[k] = lz(float(k - 1) - pp.x); wy[k] = lz(float(k - 1) - pp.y); }\n"
    "  float3 ac = 0.0; float aw = 0.0;\n"
    "  for (int y = 0; y < 4; y++) { float3 row = 0.0; for (int x = 0; x < 4; x++) row += rd(t, c, i + int2(x - 1, y - 1)) * wx[x]; ac += row * wy[y]; }\n"
    "  aw = (wx[0] + wx[1] + wx[2] + wx[3]) * (wy[0] + wy[1] + wy[2] + wy[3]);\n"
    "  float3 f = rd(t, c, i), g = rd(t, c, i + int2(1, 0)), j = rd(t, c, i + int2(0, 1)), k = rd(t, c, i + int2(1, 1));\n"
    "  return float4(clamp(ac / max(aw, 1e-5), min(min(f, g), min(j, k)), max(max(f, g), max(j, k))), 1.0); }\n";
enum { GX_FN_FXAA, GX_FN_CAS, GX_FN_EASU, GX_FN_LANCZOS, GX_NFN };
static const char *const gx_fn_name[GX_NFN] = {"fs_fxaa", "fs_cas", "fs_easu", "fs_lanczos"};
static id<MTLLibrary> g_gx_lib;
static struct { int fn; MTLPixelFormat fmt; __strong id<MTLRenderPipelineState> pso; } g_gx_pso[16]; static int g_gx_npso;
static id<MTLTexture> g_gx_aa[3], g_gx_up[3];
static id<MTL4CounterHeap> g_gx_heap; static double g_gx_hz; static int g_gx_timed[3];
static double g_gx_ms[128]; static _Atomic int g_gx_nms;
static _Atomic uint64_t g_gx_out;   // the viewport the picture was last drawn at (h << 32 | w), for the HUD

static id<MTLRenderPipelineState> gx_pso(int fn, MTLPixelFormat fmt) {
    for (int i = 0; i < g_gx_npso; i++) if (g_gx_pso[i].fn == fn && g_gx_pso[i].fmt == fmt) return g_gx_pso[i].pso;
    NSError *e = nil;
    if (!g_gx_lib) {
        MTLCompileOptions *o = [MTLCompileOptions new]; o.mathMode = MTLMathModeSafe;
        g_gx_lib = [g_dev newLibraryWithSource:@(gx_msl) options:o error:&e];
        if (!g_gx_lib) { MLOG("【红】[gfx] picture shaders failed to compile (%s): the settings fall back to the plain picture", e.localizedDescription.UTF8String); return nil; }
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [g_gx_lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [g_gx_lib newFunctionWithName:@(gx_fn_name[fn])];
    pd.colorAttachments[0].pixelFormat = fmt;
    id<MTLRenderPipelineState> p = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!p) { MLOG("【红】[gfx] %s pipeline (format %lu) failed: %s", gx_fn_name[fn], (unsigned long)fmt, e.localizedDescription.UTF8String); return nil; }
    if (g_gx_npso < 16) { g_gx_pso[g_gx_npso].fn = fn; g_gx_pso[g_gx_npso].fmt = fmt; g_gx_pso[g_gx_npso].pso = p; g_gx_npso++; }
    return p;
}
static id<MTLTexture> gx_target(id<MTLTexture> __strong *t, NSUInteger w, NSUInteger h, MTLPixelFormat fmt) {
    if (*t && (*t).width == w && (*t).height == h && (*t).pixelFormat == fmt) return *t;
    if (*t) res_remove(*t);   // a frame still in flight holds its own reference through the command buffer's resources
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
    *t = [g_dev newTextureWithDescriptor:d];
    if (*t) { res_add(*t); res_commit(); }
    return *t;
}
static float gx_sharpness(void);
// The GP constants of a pass (or of the final draw, off 0): the input's valid region in UV and texels, the output size.
static void gx_consts(int slot, NSUInteger off, id<MTLTexture> in, const NSUInteger r[4], NSUInteger ow, NSUInteger oh) {
    float *u = (float *)((uint8_t *)g_present_uv[slot].contents + off), W = in.width, H = in.height;
    const float v[20] = {r[0] / W, r[1] / H, r[2] / W, r[3] / H, (r[0] + 0.5f) / W, (r[1] + 0.5f) / H, (r[0] + r[2] - 0.5f) / W, (r[1] + r[3] - 0.5f) / H,
                         (float)r[0], (float)r[1], (float)r[2], (float)r[3], (float)ow, (float)oh, 0, 0, gx_sharpness(), 0, 0, 0};
    memcpy(u, v, sizeof v);
}
// One full-screen pass of `fn` from `in` (valid region x, y, w, h) into `dst` (whole texture), constants at `off`.
static int gx_pass(id<MTL4CommandBuffer> cb, int fn, id<MTLTexture> in, const NSUInteger r[4], id<MTLTexture> dst, int slot, NSUInteger off) {
    id<MTLRenderPipelineState> p = gx_pso(fn, dst.pixelFormat); if (!p) return 0;
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp]; if (!en) return 0;
    [en barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    gx_consts(slot, off, in, r, dst.width, dst.height);
    id<MTL4ArgumentTable> args = g_present_args[slot];
    [args setTexture:in.gpuResourceID atIndex:0]; [args setSamplerState:g_blit_samp.gpuResourceID atIndex:0];
    [args setAddress:g_present_uv[slot].gpuAddress + off atIndex:0];
    [en setArgumentTable:args atStages:MTLRenderStageFragment];
    [en setViewport:(MTLViewport){0, 0, dst.width, dst.height, 0, 1}]; [en setRenderPipelineState:p];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    m4_end(en);
    return 1;
}
static float gx_sharpness(void) {
    static float s = -1; if (s < 0) { const char *e = getenv("ODYSSEY_CAS_SHARPNESS"); s = e ? (float)atof(e) : 0.5f; if (!(s >= 0 && s <= 1)) s = 0.5f; }
    return s;
}
static void gx_stamp_begin(id<MTL4CommandBuffer> cb, int slot) {
    if (slot < 0 || slot > 2) return;
    g_gx_timed[slot] = 0;
    if (!g_gx_heap) { MTL4CounterHeapDescriptor *hd = [MTL4CounterHeapDescriptor new]; hd.type = MTL4CounterHeapTypeTimestamp; hd.count = 6;
                      NSError *e = nil; g_gx_heap = [g_dev newCounterHeapWithDescriptor:hd error:&e]; g_gx_hz = (double)[g_dev queryTimestampFrequency]; }
    if (!g_gx_heap) return;
    id<MTL4ComputeCommandEncoder> w = [cb computeCommandEncoder];   // waits for the game's frame, so the stamps time only the picture work
    [w barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    m4_end(w);
    [cb writeTimestampIntoHeap:g_gx_heap atIndex:(NSUInteger)slot * 2];
    g_gx_timed[slot] = 1;
}
static void gx_stamp_end(id<MTL4CommandBuffer> cb, int slot) {
    if (slot >= 0 && slot < 3 && g_gx_timed[slot]) [cb writeTimestampIntoHeap:g_gx_heap atIndex:(NSUInteger)slot * 2 + 1];
}
static int dcmp_gx(const void *x, const void *y) { double a = *(const double *)x, b = *(const double *)y; return a < b ? -1 : a > b; }
static void gx_note_gpu(int slot) {   // the present command buffer of this slot completed
    static int said;
    if (slot < 0 || slot > 2 || !g_gx_timed[slot] || !g_gx_heap || g_gx_hz <= 0) { if (said < 3) { said++; MLOG("[gfx] timer: slot %d timed %d heap %p hz %.0f", slot, slot >= 0 && slot < 3 ? g_gx_timed[slot] : -1, (__bridge void *)g_gx_heap, g_gx_hz); } return; }
    NSData *d = [g_gx_heap resolveCounterRange:NSMakeRange((NSUInteger)slot * 2, 2)]; const MTL4TimestampHeapEntry *t = d.bytes;
    if (!t || d.length < 2 * sizeof *t || t[1].timestamp <= t[0].timestamp) { if (said < 3) { said++; MLOG("[gfx] timer: %lu bytes, %llu -> %llu", (unsigned long)d.length, t ? (unsigned long long)t[0].timestamp : 0ull, t && d.length >= 2 * sizeof *t ? (unsigned long long)t[1].timestamp : 0ull); } return; }
    int n = atomic_fetch_add(&g_gx_nms, 1); g_gx_ms[n % 128] = (t[1].timestamp - t[0].timestamp) / g_gx_hz * 1e3;
    if ((n + 1) % 600 == 0) {   // for A/B runs: the picture work's GPU time with the settings in force
        double a[128]; memcpy(a, g_gx_ms, sizeof a); qsort(a, 128, sizeof *a, dcmp_gx);
        MLOG("[gfx] picture work GPU p50 %.3f / p95 %.3f ms (last 128 presents): aa %s, cas %s, upscaler %s, textures %s%s", a[64], a[121],
             gx_token[GX_AA][gx_eff(GX_AA)], gx_token[GX_CAS][gx_eff(GX_CAS)], gx_token[GX_UP][gx_eff(GX_UP)], gx_token[GX_TEX][gx_get(GX_TEX)], gx_live() ? "" : " (60+60 off: defaults)");
    }
}
static double gx_picture_ms(void) {
    int n = atomic_load(&g_gx_nms); if (n <= 0) return -1;
    if (n > 128) n = 128;
    double a[128]; memcpy(a, g_gx_ms, sizeof a); qsort(a, (size_t)n, sizeof *a, dcmp_gx);
    return a[n / 2];
}
/* The HUD's graphics lines (frontend.m shortcut_text): keys 3-7 with their values, then the GPU line. */
void dm_gfx_panel_text(char *out, size_t n) {
    size_t o = 0; int live = gx_live();
    for (int w = 0; w < GX_N && o < n; w++) {
        int v = gx_get(w);
        o += (size_t)snprintf(out + o, n - o, "%d  %s: %s", w + 3, gx_title[w], gx_label[w][v]);
        if (w == GX_RES && v != g_gx_res_now && o < n) o += (size_t)snprintf(out + o, n - o, " at next launch (now %s)", gx_label[GX_RES][g_gx_res_now]);
        if (w == GX_UP && v == GX_UP_METALFX && !(mfxup_enabled() && mfxup_output_enabled()) && o < n) o += (size_t)snprintf(out + o, n - o, " (off in this build: bilinear)");
        if (o < n) o += (size_t)snprintf(out + o, n - o, "\n");
    }
    if (!live && o < n) o += (size_t)snprintf(out + o, n - o, "   (3-5 apply while 60+60 is on)\n");
    sysload_start();
    sysload_info li; int have = sysload_get(&li);
    double ms = gx_picture_ms();
    uint64_t src = atomic_load(&g_pic_src), vp = atomic_load(&g_gx_out);
    if (o < n) o += (size_t)snprintf(out + o, n - o, "GPU");
    if (have && li.gpu_sys >= 0 && o < n) o += (size_t)snprintf(out + o, n - o, " %d%% busy", li.gpu_sys);
    if (have && li.gpu_game >= 0 && o < n) o += (size_t)snprintf(out + o, n - o, ", game %d%%", li.gpu_game);
    if (ms >= 0 && o < n) o += (size_t)snprintf(out + o, n - o, ", picture %.2f ms", ms);
    if (src && vp && o < n) snprintf(out + o, n - o, ", %llux%llu -> %llux%llu", (unsigned long long)(src & 0xffffffff), (unsigned long long)(src >> 32),
                                     (unsigned long long)(vp & 0xffffffff), (unsigned long long)(vp >> 32));
}
/* The game picture into `dst` at `vp` with the current settings (the render encoder for the final draw and the overlays
   is opened by the caller afterwards). Returns the texture and region the final draw reads, and its function:
   -1 the plain blit, else GX_FN_CAS / GX_FN_EASU / GX_FN_LANCZOS. */
static id<MTLTexture> gx_picture(id<MTL4CommandBuffer> cb, id<MTLTexture> src, NSUInteger r[4], MTLViewport vp, MTLPixelFormat dst_fmt, int slot, int *final_fn) {
    *final_fn = -1;
    atomic_store(&g_gx_out, (uint64_t)vp.height << 32 | (uint64_t)vp.width);
    int aa = gx_eff(GX_AA), cas = gx_eff(GX_CAS), up = gx_eff(GX_UP);
    id<MTLTexture> in = src;
    if (aa == GX_AA_FXAA) {
        id<MTLTexture> t = gx_target(&g_gx_aa[slot], r[2], r[3], src.pixelFormat);
        if (t && gx_pass(cb, GX_FN_FXAA, in, r, t, slot, GX_PASS_A)) { in = t; r[0] = r[1] = 0; }
    }
    NSUInteger ow = (NSUInteger)vp.width, oh = (NSUInteger)vp.height;
    if (up == GX_UP_METALFX) {
        id<MTLTexture> u = output_upscale(cb, in, r[0], r[1], r[2], r[3], vp, slot);   // TOTK 2K output: MetalFX to the viewport, drawn 1:1 below
        if (u) { in = u; r[0] = r[1] = 0; r[2] = u.width; r[3] = u.height; }
    } else if ((up == GX_UP_FSR1 || up == GX_UP_LANCZOS) && (ow > r[2] || oh > r[3])) {
        int fn = up == GX_UP_FSR1 ? GX_FN_EASU : GX_FN_LANCZOS;
        if (!cas) { *final_fn = fn; return in; }
        id<MTLTexture> t = gx_target(&g_gx_up[slot], ow, oh, dst_fmt);
        if (t && gx_pass(cb, fn, in, r, t, slot, GX_PASS_B)) { in = t; r[0] = r[1] = 0; r[2] = ow; r[3] = oh; }
        else { *final_fn = fn; return in; }
    }
    if (cas) *final_fn = GX_FN_CAS;
    return in;
}
