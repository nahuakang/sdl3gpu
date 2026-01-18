cbuffer UBO : register(b0, space1) {
    float4x4 mvp;
};

struct Input {
    float3 position : TEXCOORD0;
    float4 color : TEXCOORD1;
    float2 uv : TEXCOORD2;
};

struct Output {
    float4 position : SV_Position;
    float4 color : TEXCOORD0;
    float2 uv : TEXCOORD1;
};

Output main(Input input) {
    Output output;
    // NOTE(nahua): Jai's matrix is row-major, so vector goes first
    output.position = mul(float4(input.position, 1.0), mvp);
    output.color = input.color;
    output.uv = input.uv;
    return output;
}
