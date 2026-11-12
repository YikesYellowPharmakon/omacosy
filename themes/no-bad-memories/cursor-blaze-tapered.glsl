float getSdfRectangle(in vec2 p, in vec2 xy, in vec2 b)
{
    vec2 d = abs(p - xy) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Based on Inigo Quilez's 2D distance functions article: https://iquilezles.org/articles/distfunctions2d/
// Potencially optimized by eliminating conditionals and loops to enhance performance and reduce branching

float seg(in vec2 p, in vec2 a, in vec2 b, inout float s, float d) {
    vec2 e = b - a;
    vec2 w = p - a;
    vec2 proj = a + e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    float segd = dot(p - proj, p - proj);
    d = min(d, segd);

    float c0 = step(0.0, p.y - a.y);
    float c1 = 1.0 - step(0.0, p.y - b.y);
    float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
    float allCond = c0 * c1 * c2;
    float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
    float flip = mix(1.0, -1.0, step(0.5, allCond + noneCond));
    s *= flip;
    return d;
}

float getSdfParallelogram(in vec2 p, in vec2 v0, in vec2 v1, in vec2 v2, in vec2 v3) {
    float s = 1.0;
    float d = dot(p - v0, p - v0);

    d = seg(p, v0, v3, s, d);
    d = seg(p, v1, v0, s, d);
    d = seg(p, v2, v1, s, d);
    d = seg(p, v3, v2, s, d);

    return s * sqrt(d);
}

vec2 norm(vec2 value, float isPosition) {
    return (value * 2.0 - (iResolution.xy * isPosition)) / iResolution.y;
}

float antialising(float distance) {
    return 1. - smoothstep(0., norm(vec2(2., 2.), 0.).x, distance);
}

float determineStartVertexFactor(vec2 c, vec2 p) {
    // Conditions using step
    float condition1 = step(p.x, c.x) * step(c.y, p.y); // c.x < p.x && c.y > p.y
    float condition2 = step(c.x, p.x) * step(p.y, c.y); // c.x > p.x && c.y < p.y

    // If neither condition is met, return 1 (else case)
    return 1.0 - max(condition1, condition2);
}

float isLess(float c, float p) {
    // Conditions using step
    return 1.0 - step(p, c); // c < p
}

vec2 getRectangleCenter(vec4 rectangle) {
    return vec2(rectangle.x + (rectangle.z / 2.), rectangle.y - (rectangle.w / 2.));
}
float ease(float x) {
    return pow(1.0 - x, 3.0);
}

const float TAIL_STRETCH = 6.0;

vec2 screenExit(vec2 from, vec2 dir) {
    vec2 d = dir;
    if (abs(d.x) < 1e-4) d.x = d.x < 0.0 ? -1e-4 : 1e-4;
    if (abs(d.y) < 1e-4) d.y = d.y < 0.0 ? -1e-4 : 1e-4;
    float aspect = iResolution.x / iResolution.y;
    float tx = d.x > 0.0 ? (aspect - from.x) / d.x : (-aspect - from.x) / d.x;
    float ty = d.y > 0.0 ? (1.0 - from.y) / d.y : (-1.0 - from.y) / d.y;
    return from + d * max(min(tx, ty), 0.0);
}

// The same six colors as the frozen band, half a loop apart from it, so the
// two layers never sit on the same color. theme-pack.py fills them in.
const int PALETTE_N = 6;
const vec3 PALETTE[6] = vec3[6](
        vec3(0.6588, 0.1725, 0.7216), // omacosy-palette-0
        vec3(0.7804, 0.1569, 0.7216), // omacosy-palette-1
        vec3(0.8784, 0.2902, 0.5490), // omacosy-palette-2
        vec3(1.0000, 0.3529, 0.2902), // omacosy-palette-3
        vec3(0.8980, 0.1569, 0.1020), // omacosy-palette-4
        vec3(0.8980, 0.5451, 0.2588) // omacosy-palette-5
    );

vec3 paletteAt(float h) {
    float x = fract(h) * float(PALETTE_N);
    int i = int(x);
    return mix(PALETTE[i], PALETTE[(i + 1) % PALETTE_N], smoothstep(0.0, 1.0, fract(x)));
}
const float DURATION = 0.42; //IN SECONDS

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
    // Ghostty redraws every frame; once the trail is over this pixel is unchanged.
    if (iTime - iTimeCursorChange >= DURATION) return;
    // Normalization for fragCoord to a space of -1 to 1;
    vec2 vu = norm(fragCoord, 1.);
    vec2 offsetFactor = vec2(-.5, 0.5);

    // Normalization for cursor position and size;
    // cursor xy has the postion in a space of -1 to 1;
    // zw has the width and height
    vec4 currentCursor = vec4(norm(iCurrentCursor.xy, 1.), norm(iCurrentCursor.zw, 0.));
    vec4 previousCursor = vec4(norm(iPreviousCursor.xy, 1.), norm(iPreviousCursor.zw, 0.));

    vec2 centerCC = getRectangleCenter(currentCursor);
    vec2 centerCP = getRectangleCenter(previousCursor);
    // When drawing a parellelogram between cursors for the trail i need to determine where to start at the top-left or top-right vertex of the cursor
    float vertexFactor = determineStartVertexFactor(currentCursor.xy, previousCursor.xy);
    float invertedVertexFactor = 1.0 - vertexFactor;

    float xFactor = isLess(previousCursor.x, currentCursor.x);
    float yFactor = isLess(currentCursor.y, previousCursor.y);

    // Set every vertex of my parellogram
    vec2 v0 = vec2(currentCursor.x + currentCursor.z * vertexFactor, currentCursor.y - currentCursor.w);
    vec2 v1 = vec2(currentCursor.x + currentCursor.z * xFactor, currentCursor.y - currentCursor.w * yFactor);
    vec2 v2 = vec2(currentCursor.x + currentCursor.z * invertedVertexFactor, currentCursor.y);
    vec2 v3 = centerCP;

    vec2 travel = v3 - centerCC;
    float jump = length(travel);
    vec2 dir = travel / max(jump, 1e-4);
    float sudden = step(max(currentCursor.w * 1.8, 0.03), jump);
    vec2 newTip = mix(centerCC + dir * jump * TAIL_STRETCH, screenExit(centerCC, dir), sudden);
    vec2 newWide = mix(centerCC, screenExit(centerCC, -dir), sudden);
    vec2 shiftWide = newWide - centerCC;
    v0 += shiftWide;
    v1 += shiftWide;
    v2 += shiftWide;
    v3 = newTip;

    float sdfCurrentCursor = getSdfRectangle(vu, currentCursor.xy - (currentCursor.zw * offsetFactor), currentCursor.zw * 0.5);
    float sdfTrail = getSdfParallelogram(vu, v0, v1, v2, v3);

    float progress = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float easedProgress = ease(progress);
    float lineLength = max(distance(centerCC, newTip), distance(centerCC, newWide));

    // A thin light streak: a fine core in the flowing palette with a soft
    // glow of the same color, both fading out toward the tip.
    float band = sdfTrail - 0.0012;
    float edge = 0.0035;
    float glow = 1.0 - smoothstep(0.0, edge * 2.5, band);
    float core = 1.0 - smoothstep(0.0, edge * 0.45, band);
    float along = clamp(distance(vu, centerCC) / max(lineLength, 1e-4), 0.0, 1.0);
    float taper = 1.0 - smoothstep(0.0, 1.0, along);
    vec3 body = paletteAt(along * 0.9 - iTime * 0.6 + 0.5);
    vec4 trail = fragColor;
    trail.rgb = mix(trail.rgb, body, glow * 0.35 * taper);
    trail.rgb = mix(trail.rgb, body, core * (0.35 + 0.65 * taper));
    float cursorGlow = 1.0 - smoothstep(0.0, 0.004, sdfCurrentCursor);
    trail.rgb = mix(trail.rgb, paletteAt(0.5 - iTime * 0.6), cursorGlow * 0.55);
    fragColor = mix(trail, fragColor, 1. - smoothstep(0., sdfCurrentCursor, easedProgress * lineLength));
}
