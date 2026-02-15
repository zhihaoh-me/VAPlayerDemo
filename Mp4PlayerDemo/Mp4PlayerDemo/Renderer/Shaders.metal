#include <metal_stdlib>
using namespace metal;

// Vertex input structure
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

// Vertex output / Fragment input structure
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader - passes through position and texture coordinates
vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                               constant float4 *vertexData [[buffer(0)]]) {
    VertexOut outVertex;

    // Each vertex has 4 floats: position.xy, texCoord.xy
    float4 vtx = vertexData[vertexID];
    outVertex.position = float4(vtx.xy, 0.0, 1.0);
    outVertex.texCoord = vtx.zw;

    return outVertex;
}

// BT.709 YCbCr to RGB conversion matrix (for HD video)
// Y is in range [16, 235], Cb/Cr are in range [16, 240] for video range
// After normalizing to [0, 1], we need to apply offset and matrix
constant float3x3 ycbcrToRGBMatrix = float3x3(
    float3(1.164,  1.164, 1.164),   // Column 0: Y coefficients
    float3(0.000, -0.213, 2.112),   // Column 1: Cb coefficients
    float3(1.793, -0.533, 0.000)    // Column 2: Cr coefficients
);

// Offset to apply before matrix multiplication
// Y: subtract 16/255, Cb/Cr: subtract 128/255
constant float3 ycbcrOffset = float3(16.0/255.0, 128.0/255.0, 128.0/255.0);

// Fragment shader - converts YCbCr to RGB
fragment float4 fragmentShader(VertexOut inVertex [[stage_in]],
                                texture2d<float> yTexture [[texture(0)]],
                                texture2d<float> cbcrTexture [[texture(1)]],
                                sampler textureSampler [[sampler(0)]]) {
    // Sample Y from luminance texture
    float y = yTexture.sample(textureSampler, inVertex.texCoord).r;

    // Sample Cb and Cr from chrominance texture
    float2 cbcr = cbcrTexture.sample(textureSampler, inVertex.texCoord).rg;

    // Combine into YCbCr vector
    float3 ycbcr = float3(y, cbcr.x, cbcr.y);

    // Apply offset (convert from video range to normalized range)
    ycbcr -= ycbcrOffset;

    // Convert to RGB using BT.709 matrix
    float3 rgb = ycbcrToRGBMatrix * ycbcr;

    // Clamp to valid range
    rgb = saturate(rgb);

    return float4(rgb, 1.0);
}
