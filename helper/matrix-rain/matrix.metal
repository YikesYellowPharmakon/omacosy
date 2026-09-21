#include <metal_stdlib>
using namespace metal;

// Desktop + screensaver rain is the Omarchy GPU port (tools/matrix.frag).
// VAPOR wordmark is screensaver-only (u.wordmark).

struct Uniforms {
    float iTime;
    float pad0;
    float2 iResolution;
    float4 colBg;
    float4 colHead;
    float4 colRainA;
    float4 colRainB;
    float cellH;
    float dpr;
    float period;
    float birth;
    float wordmark;
    float trapBoost;
    float cellW;
    float pad3;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

constant float ATLAS_COLS = 8.0;
constant float ATLAS_ROWS = 7.0;
constant float GLYPHS = 50.0;
constant float TAIL_MAX = 40.0;
constant float LETTER_W = 5.0;
constant float LETTER_GAP = 3.0;
constant float LETTER_STRIDE = 8.0;
constant float BITMAP_STRIDE = 6.0;
constant float N_LETTERS = 5.0;
constant float VAPOR_LAYOUT_W = 37.0;
constant float VAPOR_BITMAP_W = 29.0;
constant float VAPOR_H = 7.0;
constant float RAIN_LEAD = 6.0;
constant float FORM_TIME = 46.0;
constant float HOLD_END = 62.0;
constant float CYCLE = 69.0;
constant float TRAP_FADE = 1.0;
constant uint VAPOR[7] = {
    0x1139e39eu,
    0x11451451u,
    0x11451451u,
    0x0a7de45eu,
    0x0a450454u,
    0x04450452u,
    0x04450391u
};

vertex VertexOut vs_main(uint vid [[vertex_id]]) {
    float2 pos[4] = { float2(-1.0,  1.0), float2( 1.0,  1.0), float2(-1.0, -1.0), float2( 1.0, -1.0) };
    float2 uv[4]  = { float2( 0.0,  0.0), float2( 1.0,  0.0), float2( 0.0,  1.0), float2( 1.0,  1.0) };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = uv[vid];
    return out;
}

float hash11(float n) {
    return fract(sin(n) * 43758.5453);
}

float hash12(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

void column(float cx, float span, float period, float iTime, float birth, float speedScale,
            thread float &head, thread float &tail, thread float &dim, thread float &alive) {
    float k = 300.0 + floor(hash11(cx * 1.31 + 0.7) * 601.0);
    float speed = k * span / period * speedScale;
    float phi = hash11(cx * 7.13 + 4.7) * span * k;
    float travel = iTime * speed + phi;
    float cycle = floor(travel / span);
    head = travel - cycle * span;
    float c = fmod(cycle, k);
    tail = 14.0 + hash12(float2(cx + 0.5, c)) * 24.0;
    dim = 0.68 + hash12(float2(cx + 3.7, c)) * 0.60;
    alive = step(0.20, hash12(float2(cx + 9.1, c)));
    float tFirst = (ceil(phi / span) * span - phi) / speed;
    alive *= step(tFirst, birth);
}

void vaporLayout(float2 res, float cellW, float cellH, thread float &scale, thread float2 &origin) {
    float cols = res.x / cellW;
    float rows = res.y / cellH;
    scale = max(2.0, floor(min(cols * 0.62 / VAPOR_LAYOUT_W, rows * 0.32 / VAPOR_H)));
    float2 size = float2(VAPOR_LAYOUT_W, VAPOR_H) * scale;
    origin = floor((float2(cols, rows) - size) * 0.5);
}

bool vaporBit(float bx, float ly) {
    if (bx < 0.0 || ly < 0.0 || bx >= VAPOR_BITMAP_W || ly >= VAPOR_H)
        return false;
    uint bits = VAPOR[int(ly)];
    uint shift = uint(VAPOR_BITMAP_W) - 1u - uint(bx);
    return ((bits >> shift) & 1u) == 1u;
}

bool vaporLayoutBit(float lx, float ly) {
    float letter = floor(lx / LETTER_STRIDE);
    float within = lx - letter * LETTER_STRIDE;
    if (letter < 0.0 || letter >= N_LETTERS || within < 0.0 || within >= LETTER_W)
        return false;
    return vaporBit(letter * BITMAP_STRIDE + within, ly);
}

bool vaporCell(float2 cellId, float2 res, float cellW, float cellH) {
    float scale;
    float2 origin;
    vaporLayout(res, cellW, cellH, scale, origin);
    float2 local = floor((cellId - origin) / scale);
    return vaporLayoutBit(local.x, local.y);
}

bool vaporTrapped(float2 cellId, float t) {
    float lockAt = RAIN_LEAD + hash12(cellId * 1.13) * (FORM_TIME - RAIN_LEAD);
    float releaseAt = hash12(cellId * 2.71 + 9.0) * 7.0;
    if (t < RAIN_LEAD)
        return false;
    if (t < FORM_TIME)
        return t >= lockAt;
    if (t < HOLD_END)
        return true;
    return (t - HOLD_END) < releaseAt;
}

void pickGlyph(float2 cellId, float tick, float2 cellUV, thread float2 &slot, thread float2 &guv) {
    float gi = floor(hash12(float2(cellId.x * 3.1 + cellId.y * 7.7, tick)) * GLYPHS);
    slot = float2(fmod(gi, ATLAS_COLS), floor(gi / ATLAS_COLS));
    guv = cellUV;
    if (hash12(float2(cellId.x * 1.9 + cellId.y * 4.3, tick + 0.5)) > 0.5)
        guv.x = 1.0 - guv.x;
}

// Atlas glyphs are 38x80. Never stretch them to the cell; letterbox instead.
float sampleGlyph(texture2d<float> atlas, sampler atlasSampler, float2 slot, float2 cellUV, float cellW, float cellH) {
    const float nativeA = 38.0 / 80.0;
    float2 uv = (cellUV - 0.5) / 0.92 + 0.5;
    float cellA = cellW / max(cellH, 0.001);
    if (cellA > nativeA) {
        float used = nativeA / cellA;
        uv.x = (uv.x - 0.5) / used + 0.5;
    } else {
        float used = cellA / nativeA;
        uv.y = (uv.y - 0.5) / used + 0.5;
    }
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;
    float2 pad = float2(0.5 / 38.0, 0.5 / 80.0);
    uv = clamp(uv, pad, 1.0 - pad);
    return atlas.sample(atlasSampler, (slot + uv) / float2(ATLAS_COLS, ATLAS_ROWS)).a;
}

fragment float4 fs_main(VertexOut in [[stage_in]],
                        constant Uniforms &u [[buffer(0)]],
                        texture2d<float> atlas [[texture(0)]],
                        sampler atlasSampler [[sampler(0)]]) {
    float2 frag = in.uv * u.iResolution;
    float cellH = u.cellH > 4.0 ? u.cellH : 16.0;
    float cellW = u.cellW > 4.0 ? u.cellW : cellH * 0.47;
    float2 cell = float2(cellW, cellH);
    float2 cellId = floor(frag / cell);
    float2 cellUV = fract(frag / cell);
    float span = u.iResolution.y / cellH + TAIL_MAX;
    float period = u.period > 1.0 ? u.period : 3600.0;
    float calm = saturate(u.trapBoost);
    float speedScale = mix(1.0, 0.90, calm);

    float head, tail, dim, alive;
    column(cellId.x, span, period, u.iTime, u.birth, speedScale, head, tail, dim, alive);

    float above = head - cellId.y;
    float vis = step(0.0, above) * step(above, tail) * alive;
    float t = clamp(above / max(tail, 1.0), 0.0, 1.0);
    float bright = mix(1.0, 0.30, pow(t, 0.75)) * vis * dim * mix(1.0, 0.93, calm);

    float band = floor(t * 4.0);
    float rate = (band < 1.0) ? 9.0 : (band < 2.0) ? 3.0 : (band < 3.0) ? 1.5 : 0.75;
    float off = hash12(cellId * 1.7) * 8.0;
    float tick = fmod(floor(u.iTime * rate + off), rate * period);

    float2 slot;
    float2 guv;
    pickGlyph(cellId, tick, cellUV, slot, guv);
    float a = sampleGlyph(atlas, atlasSampler, slot, guv, cellW, cellH);

    float3 rain = mix(u.colRainA.rgb, u.colRainB.rgb, hash12(cellId + 3.7));
    float heat = clamp(1.0 - above / 3.0, 0.0, 1.0) * vis;
    float3 glyph = mix(rain, u.colHead.rgb, heat * heat);

    float glow = 0.0;
    for (int i = -1; i <= 1; i++) {
        float nh, nt, nd, na;
        column(cellId.x + float(i), span, period, u.iTime, u.birth, speedScale, nh, nt, nd, na);
        float dy = nh - cellId.y - cellUV.y;
        float dx = float(i) + 0.5 - cellUV.x;
        glow += na * nd * exp(-dx * dx * 3.0 - dy * dy * 0.5);
    }

    float cycleT = fmod(u.iTime, CYCLE);
    bool mark = u.wordmark > 0.5 && vaporCell(cellId, u.iResolution, cellW, cellH);
    bool trapped = mark && vaporTrapped(cellId, cycleT);

    if (u.wordmark > 0.5 && cycleT >= HOLD_END) {
        float scale;
        float2 origin;
        vaporLayout(u.iResolution, cellW, cellH, scale, origin);
        float lx = floor((cellId.x - origin.x) / scale);
        if (lx >= 0.0 && lx < VAPOR_LAYOUT_W) {
            float bestAge = -1.0;
            float2 bestMark = cellId;
            for (int ly = 0; ly < 7; ly++) {
                if (!vaporLayoutBit(lx, float(ly)))
                    continue;
                for (int sy = 0; sy < 8; sy++) {
                    if (float(sy) >= scale)
                        break;
                    float my = origin.y + float(ly) * scale + float(sy);
                    float2 markId = float2(cellId.x, my);
                    float rel = hash12(markId * 2.71 + 9.0) * 7.0;
                    float age = cycleT - HOLD_END - rel;
                    if (age < 0.0)
                        continue;
                    float spd = 8.0 + hash12(markId * 5.3) * 10.0;
                    float dropHead = my + age * spd;
                    float dropLen = 16.0 + hash12(markId * 8.1) * 18.0;
                    if (cellId.y <= dropHead && cellId.y >= dropHead - dropLen && cellId.y >= my && age > bestAge) {
                        bestAge = age;
                        bestMark = markId;
                    }
                }
            }
            if (bestAge >= 0.0) {
                float spd = 8.0 + hash12(bestMark * 5.3) * 10.0;
                float dropHead = bestMark.y + bestAge * spd;
                float along = max(0.0, dropHead - cellId.y);
                pickGlyph(cellId, floor(u.iTime * 6.0 + hash12(cellId) * 8.0), cellUV, slot, guv);
                a = sampleGlyph(atlas, atlasSampler, slot, guv, cellW, cellH);
                float persist = pow(saturate(1.0 - along / 18.0), 0.55);
                glyph = mix(u.colHead.rgb, mix(u.colRainA.rgb, u.colRainB.rgb, 0.35), saturate(along / 6.0));
                bright = persist * 0.95;
                vis = 1.0;
                heat = 0.0;
            }
        }
    }

    if (trapped) {
        float lockAt = RAIN_LEAD + hash12(cellId * 1.13) * (FORM_TIME - RAIN_LEAD);
        float age = (cycleT < FORM_TIME) ? max(0.0, cycleT - lockAt) : TRAP_FADE;
        float cool = saturate(age / TRAP_FADE);
        pickGlyph(cellId, floor(u.iTime * 0.75 + hash12(cellId) * 8.0), cellUV, slot, guv);
        a = sampleGlyph(atlas, atlasSampler, slot, guv, cellW, cellH);
        glyph = mix(u.colHead.rgb, u.colRainA.rgb, cool * 0.55);
        bright = 0.95;
        vis = 1.0;
        glow += 0.35;
    }

    float3 col = u.colBg.rgb + glyph * a * bright + u.colHead.rgb * glow * mix(0.07, 0.012, calm);
    col *= mix(0.93 + 0.07 * sin(frag.y * u.dpr * 3.14159265), 1.0, calm);
    return float4(col, 1.0);
}
