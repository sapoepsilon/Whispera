#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float glowWidth = 28.0;
// exp(-4.6) < 1%: past this distance the glow is invisible, skip the math
constant float glowCutoff = glowWidth * 4.6;

static half3 spectrum(float t) {
	return half3(0.5 + 0.5 * cos(6.2831853 * (float3(0.0, 0.33, 0.67) + t)));
}

[[stitchable]] half4 recordingGlow(
	float2 position, half4 color, float4 bounds, float time, float pulse
) {
	float2 size = bounds.zw;
	float edgeDistance = min(
		min(position.x, size.x - position.x),
		min(position.y, size.y - position.y)
	);
	if (edgeDistance > glowCutoff) {
		return half4(0.0);
	}
	float intensity = exp(-edgeDistance / glowWidth) * pulse;

	float2 centered = position - size * 0.5;
	float angle = atan2(centered.y, centered.x) / 6.2831853;
	half3 rgb = spectrum(angle + time * 0.2);

	// premultiplied alpha, as SwiftUI colorEffect expects
	return half4(rgb * half(intensity), half(intensity));
}
