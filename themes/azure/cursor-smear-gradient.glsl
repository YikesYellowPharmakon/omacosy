// Shader Contribution by PremModhaOfficial
// For inquiries or modifications, please reach him
// GitHub: https://github.com/PremModhaOfficial
//
// Cursor trail shader that creates a hexagonal trailing effect. The colors
// flow like the No Bad Memories rainbow, but through six of this theme's own
// colors; theme-pack.py fills them in.

const int PALETTE_N = 6;
const vec3 PALETTE[6] = vec3[6](
        vec3(0.3373, 0.3373, 0.7412), // omacosy-palette-0
        vec3(0.4078, 0.4078, 0.9020), // omacosy-palette-1
        vec3(0.5529, 0.6314, 0.7843), // omacosy-palette-2
        vec3(0.6784, 0.8471, 0.9608), // omacosy-palette-3
        vec3(0.4627, 0.7333, 0.9333), // omacosy-palette-4
        vec3(0.3373, 0.5765, 0.7686) // omacosy-palette-5
    );

// A closed loop through the palette: h in [0, 1) goes 0 -> 1 -> 2 -> 3 -> 0.
vec3 paletteAt(float h) {
    float x = fract(h) * float(PALETTE_N);
    int i = int(x);
    return mix(PALETTE[i], PALETTE[(i + 1) % PALETTE_N], smoothstep(0.0, 1.0, fract(x)));
}

// Process each edge: compute distance and determine if point is inside
void processEdge(vec2 p, vec2 a, vec2 b, inout float minDist, inout float inside) {
    vec2 edge = b - a;
    vec2 pa = p - a;
    float lenSq = dot(edge, edge);
    float invLenSq = 1.0 / lenSq;

    float t = clamp(dot(pa, edge) * invLenSq, 0.0, 1.0);
    vec2 diff = pa - edge * t;
    minDist = min(minDist, dot(diff, diff));

    float cross = edge.x * pa.y - edge.y * pa.x;
    inside = min(inside, step(0.0, cross));
}

// Signed distance field for hexagon (negative inside, positive outside)
// Vertices must be in counter-clockwise order
float sdHexagon(in vec2 p, in vec2 v0, in vec2 v1, in vec2 v2, in vec2 v3, in vec2 v4, in vec2 v5) {
    float minDist = 1e20;
    float inside = 1.0;

    processEdge(p, v0, v1, minDist, inside);
    processEdge(p, v1, v2, minDist, inside);
    processEdge(p, v2, v3, minDist, inside);
    processEdge(p, v3, v4, minDist, inside);
    processEdge(p, v4, v5, minDist, inside);
    processEdge(p, v5, v0, minDist, inside);

    float dist = sqrt(max(minDist, 0.0));
    return mix(dist, -dist, inside);
}

// Signed distance field for rectangle (negative inside, positive outside)
float sdRectangle(in vec2 p, in vec2 center, in vec2 halfSize) {
    vec2 d = abs(p - center) - halfSize;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Represents cursor as a quad with four corners
struct Quad {
    vec2 topLeft;
    vec2 topRight;
    vec2 bottomLeft;
    vec2 bottomRight;
};

// Construct quad from top-left position and size
Quad getQuad(vec2 pos, vec2 size) {
    Quad q;
    q.topLeft = pos;
    q.topRight = pos + vec2(size.x, 0.0);
    q.bottomLeft = pos - vec2(0.0, size.y);
    q.bottomRight = pos + vec2(size.x, -size.y);
    return q;
}

// Select 3 corners from quad based on movement direction
// sel.x: 0=left, 1=right | sel.y: 0=top, 1=bottom
// Returns corners in counter-clockwise order for hexagon construction
void selectTrailCorners(Quad q, vec2 sel, out vec2 p1, out vec2 p2, out vec2 p3) {
    p1 = mix(mix(q.topRight, q.topLeft, sel.x),
             mix(q.bottomRight, q.bottomLeft, sel.x),
             sel.y);

    p2 = mix(mix(q.topLeft, q.bottomLeft, sel.x),
             mix(q.topRight, q.bottomRight, sel.x),
             sel.y);
    p3 = mix(mix(q.bottomRight, q.topRight, sel.x),
             mix(q.bottomLeft, q.topLeft, sel.x),
             sel.y);

}

// Select 4 corners from quad based on movement direction
// sel.x: 0=left, 1=right | sel.y: 0=top, 1=bottom
// Returns corners in counter-clockwise order for hexagon construction
void selectCorners(Quad q, vec2 sel, out vec2 p1, out vec2 p2, out vec2 p3, out vec2 p4) {
    selectTrailCorners(q, sel, p1, p2, p3);

    p4 = mix(mix(q.bottomLeft, q.bottomRight, sel.x),
             mix(q.topLeft, q.topRight, sel.x),
             sel.y);
}

// Cubic ease-out function for smooth animation (expects clamped input)
float easeClamped(float x) {
    float t = 1.0 - x;
    return 1.0 - t * t * t;
}

// Trail animation duration in seconds
const float DURATION = 0.42;

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

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Calculate animation progress with easing
    float baseProgress = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);

    vec2 uv = fragCoord / iResolution.xy;
    vec4 background = texture(iChannel0, uv);

    // Skip further work when animation is complete
    if (baseProgress >= 1.0) {
        fragColor = background;
        return;
    }

    fragColor = background;

    // Precompute reused values
    float invResY = 1.0 / iResolution.y;
    float scale = 2.0 * invResY;
    float aaWidth = scale * 3.5;
    vec2 normOffset = iResolution.xy * invResY;

    // Normalize cursor positions and sizes to screen-independent coordinates
    vec2 currentPos = iCurrentCursor.xy * scale - normOffset;
    vec2 previousPos = iPreviousCursor.xy * scale - normOffset;
    vec2 currentSize = iCurrentCursor.zw * scale;
    vec2 previousSize = iPreviousCursor.zw * scale;
    vec2 trailPad = vec2(0.006, 0.002);
    vec2 realCurrentPos = currentPos;
    vec2 prevCenter = previousPos + previousSize * vec2(0.5, -0.5);
    vec2 currCenter = currentPos + currentSize * vec2(0.5, -0.5);
    vec2 travel = prevCenter - currCenter;
    float jump = length(travel);
    vec2 dir = travel / max(jump, 1e-4);
    float sudden = step(max(currentSize.y * 1.8, 0.03), jump);
    vec2 newPrev = mix(currCenter + dir * jump * TAIL_STRETCH, screenExit(currCenter, dir), sudden);
    vec2 newCurr = mix(currCenter, screenExit(currCenter, -dir), sudden);
    previousPos += newPrev - prevCenter;
    currentPos += newCurr - currCenter;

    // Determine movement direction and construct cursor quads
    vec2 deltaPos = currentPos - previousPos;
    Quad currentCursor = getQuad(currentPos, currentSize + trailPad);
    Quad previousCursor = getQuad(previousPos, previousSize + trailPad);
    vec2 selector = step(vec2(0.0), deltaPos);

    // Select corners based on movement direction
    vec2 currP1, currP2, currP3, currP4;
    vec2 prevP1, prevP2, prevP3;
    selectCorners(currentCursor, selector, currP1, currP2, currP3, currP4);
    selectTrailCorners(previousCursor, selector, prevP1, prevP2, prevP3);

    float easedProgress = easeClamped(baseProgress);
    float stretchedProgress = min(baseProgress * 2.0, 1.0);
    float easedProgressDouble = easeClamped(stretchedProgress);

    // Create trailing effect by moving diagonal point slower
    vec2 trailP1 = mix(prevP1, currP1, easedProgress);
    vec2 trailP2 = mix(prevP2, currP2, easedProgressDouble);
    vec2 trailP3 = mix(prevP3, currP3, easedProgressDouble);

    // Compute hexagon SDF and convert to alpha with antialiasing
    vec2 normCoord = fragCoord * scale - normOffset;
    float sdfHex = sdHexagon(normCoord, trailP1, trailP2, currP2, currP4, currP3, trailP3);
    float alpha = 1.0 - smoothstep(-aaWidth, aaWidth, sdfHex);

    // Compute current cursor SDF from the real cursor, not the stretched end.
    vec2 halfCurrentSize = currentSize * 0.5;
    vec2 currentCenter = realCurrentPos + vec2(halfCurrentSize.x, -halfCurrentSize.y);
    float sdfCurrentCursor = sdRectangle(normCoord, currentCenter, halfCurrentSize);

    // Thin out toward the tail instead of darkening, so it reads on light
    // and dark backgrounds alike.
    vec2 tailCenter = previousPos + vec2(previousSize.x * 0.5, -previousSize.y * 0.5);
    float lineLength = max(distance(currentCenter, tailCenter), 1e-4);
    float along = clamp(distance(normCoord, currentCenter) / lineLength, 0.0, 1.0);
    alpha *= 0.3 + 0.7 * (1.0 - smoothstep(0.0, 1.0, along));

    // The whole palette runs from cursor to tail, however short the move,
    // and flows while the trail is up.
    vec3 flow = paletteAt(along * 0.9 - iTime * 0.6);

    // Blend trail color with background
    vec4 originalColor = fragColor;
    fragColor.rgb = mix(fragColor.rgb, flow, alpha);

    // Remove trail where it overlaps with current cursor
    fragColor.rgb = mix(fragColor.rgb, originalColor.rgb, step(sdfCurrentCursor, 0.0));
}
