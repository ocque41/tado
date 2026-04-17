//
//  Shaders.metal — Tado terminal grid renderer.
//
//  One cell per instance. A single `drawIndexedPrimitives` call emits N×M
//  instanced quads; each picks up its cell from the cell buffer via the
//  instance id. Per-frame cost scales with rows×cols × visible tiles,
//  which for 100 × (80×24) is 192k instances — well within M-series
//  capabilities at 60fps.
//
//  Uniform layout MUST stay in sync with `TerminalUniforms` in
//  MetalTerminalRenderer.swift. Keep this file under ~50 lines: reviewing a
//  diff of the shader against the Swift uniform struct should be trivial.
//

#include <metal_stdlib>
using namespace metal;

struct CellInstance {
    uint32_t ch;     // Unicode scalar (0 = blank)
    uint32_t fg;     // RGBA8
    uint32_t bg;     // RGBA8
    uint32_t attrs;  // bit flags (bold/italic/underline/reverse/dim/strike)
};

struct Uniforms {
    float2 viewport;   // pixels
    float2 cellSize;   // pixels (width, height)
    float2 atlasSize;  // pixels
    uint32_t cols;
    uint32_t rows;
    uint32_t cursorX;
    uint32_t cursorY;
    uint32_t cursorVisible;   // 0/1
    // Normalized selection rect (inclusive). Swift passes coords in
    // reading order, so walking (selStart..selEnd) per-row gives the
    // right set of cells without extra min/max. selActive=0 disables
    // the highlight — sel* fields are then ignored.
    uint32_t selStartCol;
    uint32_t selStartRow;
    uint32_t selEndCol;
    uint32_t selEndRow;
    uint32_t selActive;
};

// Atlas lookup: glyph index -> (uvRect.xy, uvRect.zw) in 0..1.
// Cell.ch is the Unicode scalar; the CPU maintains a per-frame lookup
// (`glyphLUT`) that maps ch -> atlas rect. Phase 2.1 keeps the LUT small
// and ASCII-focused; LRU eviction lands in Phase 3.
struct GlyphRect {
    float4 uvRect;  // (u0, v0, u1, v1)
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 fg;
    float4 bg;
    uint32_t attrs;
    uint32_t hasGlyph;
};

// Two triangles per quad; corners laid out so gl_VertexID in [0..5] maps to
// {top-left, top-right, bottom-left, bottom-left, top-right, bottom-right}.
constant float2 kQuadCorners[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(1.0, 1.0),
};

inline float4 unpackRGBA(uint32_t c) {
    float r = float((c >> 24) & 0xFF) / 255.0;
    float g = float((c >> 16) & 0xFF) / 255.0;
    float b = float((c >>  8) & 0xFF) / 255.0;
    float a = float( c        & 0xFF) / 255.0;
    return float4(r, g, b, a);
}

vertex VertexOut terminal_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms& u [[buffer(0)]],
    constant CellInstance* cells [[buffer(1)]],
    constant GlyphRect* glyphs [[buffer(2)]]
) {
    CellInstance cell = cells[iid];

    uint col = iid % u.cols;
    uint row = iid / u.cols;
    float2 corner = kQuadCorners[vid];

    // Pixel-space position of the corner.
    float2 px = float2(float(col), float(row)) * u.cellSize + corner * u.cellSize;
    // Clip space (top-left origin → Metal's +Y-up clip space).
    float2 clip = float2(
         (px.x / u.viewport.x) * 2.0 - 1.0,
         1.0 - (px.y / u.viewport.y) * 2.0
    );

    // Atlas UV. `glyphs[cell.ch]` is the CPU-maintained lookup table. A
    // blank cell (ch == 0 or rect collapsed to zero area) is rendered as
    // pure background.
    GlyphRect rect = glyphs[cell.ch];
    float2 uv = mix(rect.uvRect.xy, rect.uvRect.zw, corner);

    bool reverse = (cell.attrs & 0x8u) != 0u; // ATTR_REVERSE
    float4 fg = unpackRGBA(cell.fg);
    float4 bg = unpackRGBA(cell.bg);
    if (reverse) {
        float4 tmp = fg;
        fg = bg;
        bg = tmp;
    }

    // Cursor highlight: invert fg/bg on the cursor cell. (Cheap, no blink.)
    if (u.cursorVisible != 0u && col == u.cursorX && row == u.cursorY) {
        float4 tmp = fg;
        fg = bg;
        bg = tmp;
    }

    // Selection highlight: invert fg/bg on cells inside the selection
    // rect. Per-row semantics: first row starts at selStartCol, last row
    // ends at selEndCol, middle rows run full width. Single-row
    // selections take the intersection.
    if (u.selActive != 0u) {
        uint sr0 = u.selStartRow;
        uint sr1 = u.selEndRow;
        bool inRows = (row >= sr0 && row <= sr1);
        bool inCols;
        if (sr0 == sr1) {
            inCols = (col >= u.selStartCol && col <= u.selEndCol);
        } else if (row == sr0) {
            inCols = (col >= u.selStartCol);
        } else if (row == sr1) {
            inCols = (col <= u.selEndCol);
        } else {
            inCols = true;
        }
        if (inRows && inCols) {
            float4 tmp = fg;
            fg = bg;
            bg = tmp;
        }
    }

    VertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    out.uv = uv;
    out.fg = fg;
    out.bg = bg;
    out.attrs = cell.attrs;
    out.hasGlyph = (rect.uvRect.z > rect.uvRect.x) ? 1u : 0u;
    return out;
}

fragment float4 terminal_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 color = in.bg;
    if (in.hasGlyph != 0u) {
        float coverage = atlas.sample(atlasSampler, in.uv).r;
        color = mix(in.bg, in.fg, coverage * in.fg.a);
    }
    return color;
}
