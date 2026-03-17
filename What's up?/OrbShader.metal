#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 audioOrb(
	float2 position,
	half4 color,
	float2 size,
	float time,
	float audioLevel
) {
	float2 uv = position / size;
	float2 center = float2(0.5, 0.5);
	float dist = length(uv - center);

	float pulse = 0.25 + audioLevel * 0.15;
	float edge = pulse + 0.02;

	// Layered glow rings that respond to audio
	float innerGlow = smoothstep(edge, pulse * 0.3, dist);
	float outerGlow = smoothstep(pulse + 0.2, pulse, dist) * 0.5;
	float halo = exp(-dist * dist * 8.0) * (0.3 + audioLevel * 0.7);

	// Organic distortion from audio
	float angle = atan2(uv.y - 0.5, uv.x - 0.5);
	float wave1 = sin(angle * 3.0 + time * 2.0) * audioLevel * 0.04;
	float wave2 = sin(angle * 5.0 - time * 1.5) * audioLevel * 0.03;
	float wave3 = sin(angle * 7.0 + time * 3.0) * audioLevel * 0.02;
	float distorted = dist - wave1 - wave2 - wave3;

	float orbShape = smoothstep(edge, pulse * 0.5, distorted);

	// Color: blue core shifting toward cyan at edges
	half3 coreColor = half3(0.3, 0.5, 1.0);
	half3 edgeColor = half3(0.4, 0.8, 1.0);
	half3 glowColor = half3(0.2, 0.4, 1.0);

	half3 col = mix(edgeColor, coreColor, half(orbShape));
	col += glowColor * half(halo);
	col += half3(0.3, 0.6, 1.0) * half(outerGlow);

	float alpha = max(orbShape, max(outerGlow * 0.8, halo * 0.6));
	alpha = clamp(alpha, 0.0, 1.0);

	return half4(col * half(alpha), half(alpha));
}
