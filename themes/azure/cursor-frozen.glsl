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

float determineStartVertexFactor2(vec2 c, vec2 p) {
    // Conditions using step
    float condition1 = step(p.x, c.x) * step(c.y, p.y); // c.x < p.x && c.y > p.y
    float condition2 = step(c.x, p.x) * step(p.y, c.y); // c.x > p.x && c.y < p.y

    // If neither condition is met, return 1 (else case)
    return 1.0 - max(condition1, condition2);
}

vec2 getRectangleCenter(vec4 rectangle) {
    return vec2(rectangle.x + (rectangle.z / 2.), rectangle.y - (rectangle.w / 2.));
}
float ease(float x) {
    return pow(1.0 - x, 3.0);
}

// Everyday tails reach this multiple of the move. A sudden jump
// keeps going until it leaves the screen, in the same direction.
const float TAIL_STRETCH = 2.0;

vec2 screenExit(vec2 from, vec2 dir) {
    vec2 d = dir;
    if (abs(d.x) < 1e-4) d.x = d.x < 0.0 ? -1e-4 : 1e-4;
    if (abs(d.y) < 1e-4) d.y = d.y < 0.0 ? -1e-4 : 1e-4;
    float aspect = iResolution.x / iResolution.y;
    float tx = d.x > 0.0 ? (aspect - from.x) / d.x : (-aspect - from.x) / d.x;
    float ty = d.y > 0.0 ? (1.0 - from.y) / d.y : (-1.0 - from.y) / d.y;
    return from + d * max(min(tx, ty), 0.0);
}

const vec4 TRAIL_COLOR = vec4(0.3804, 0.6549, 0.8392, 1.0); // omacosy-body
const vec4 TRAIL_COLOR_ACCENT = vec4(0.2078, 0.3569, 0.4588, 1.0); // omacosy-edge
const float DURATION = 0.3; //IN SECONDS

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
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

    // Set every vertex of my parellogram
    vec2 v0 = vec2(currentCursor.x + currentCursor.z * vertexFactor, currentCursor.y - currentCursor.w);
    vec2 v1 = vec2(currentCursor.x + currentCursor.z * invertedVertexFactor, currentCursor.y);
    vec2 v2 = vec2(previousCursor.x + currentCursor.z * invertedVertexFactor, previousCursor.y);
    vec2 v3 = vec2(previousCursor.x + currentCursor.z * vertexFactor, previousCursor.y - previousCursor.w);

    vec2 midCurr = (v0 + v1) * 0.5;
    vec2 midPrev = (v2 + v3) * 0.5;
    vec2 travel = midPrev - midCurr;
    float jump = length(travel);
    vec2 dir = travel / max(jump, 1e-4);
    float sudden = step(max(currentCursor.w * 1.8, 0.03), jump);
    vec2 newPrev = mix(midCurr + dir * jump * TAIL_STRETCH, screenExit(midCurr, dir), sudden);
    vec2 newCurr = mix(midCurr, screenExit(midCurr, -dir), sudden);
    vec2 shiftPrev = newPrev - midPrev;
    vec2 shiftCurr = newCurr - midCurr;
    v0 += shiftCurr;
    v1 += shiftCurr;
    v2 += shiftPrev;
    v3 += shiftPrev;

    float sdfCurrentCursor = getSdfRectangle(vu, currentCursor.xy - (currentCursor.zw * offsetFactor), currentCursor.zw * 0.5);
    float sdfTrail = getSdfParallelogram(vu, v0, v1, v2, v3);

    float progress = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float easedProgress = ease(progress);
    // Fade uses the drawn length, so the stretched tail stays bright.
    float lineLength = max(distance(centerCC, newPrev), distance(centerCC, newCurr));

    vec4 newColor = vec4(fragColor);
    // Compute fade factor based on distance along the trail
    float fadeFactor = 1.0 - smoothstep(lineLength, sdfCurrentCursor, easedProgress * lineLength);

    // A little thicker than the thin bar. The halo falls off over a medium edge.
    float band = sdfTrail - 0.0045;
    float edge = 0.008;
    float halo = 1.0 - smoothstep(0.0, edge, band);
    float core = 1.0 - smoothstep(0.0, edge * 0.45, band);
    vec4 trail = mix(fragColor, TRAIL_COLOR_ACCENT, halo * 0.8);
    trail = mix(trail, TRAIL_COLOR, core);
    float cursorGlow = 1.0 - smoothstep(0.0, 0.004, sdfCurrentCursor);
    trail = mix(trail, TRAIL_COLOR, cursorGlow * 0.55);
    fragColor = mix(trail, fragColor, 1. - smoothstep(0., sdfCurrentCursor, easedProgress * lineLength));
}
