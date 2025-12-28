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
	// NOTE(nahua): mul(x, y); Jai's matrix is row-major, so we put the vector into x for row
	// NOTE(nahua): We'd have a [1x4] x [4x4] => [1x4] vector
	output.position = mul(float4(input.position, 1), mvp);
	output.color = input.color;
	output.uv = input.uv;
	return output;
}
