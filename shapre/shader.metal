#include <metal_stdlib>
using namespace metal;

struct ShaderParams {
    float time;
    float2 screenSize;
    float2 distortion_fac;
    float2 scale_fac;
    float feather_fac;
    float noise_fac;
    float bloom_fac;
    float crt_intensity;
    float glitch_intensity;
    float scanlines;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut passthroughVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VOut out;
    out.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(uv.x, 1.0 - uv.y);
    return out;
}

fragment float4 shader(VOut in [[stage_in]],
                         texture2d<float> tex [[texture(0)]],
                         sampler s [[sampler(0)]],
                         constant ShaderParams &params [[buffer(0)]]) {
    float3 rgb = tex.sample(s, in.uv).rgb;
    
    rgb = (rgb - 0.55) * 1.14 + 0.5;
    
    return float4(rgb, 1.0);
}
