#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float glowWidth = 24.0;
// widest possible glow at full voice level
constant float maxGlowWidth = glowWidth * 3.0;
// exp(-4.6) < 1%: past this distance the glow is invisible, skip the math
constant float glowCutoff = maxGlowWidth * 4.6;
constant float cornerRadius = 36.0;

[[stitchable]] half4 recordingGlow(
	float2 position, half4 color, float4 bounds, half4 glowColor, float time, float pulse,
	float level
) {
	float2 halfSize = bounds.zw * 0.5;
	// signed distance to a rounded rectangle inset to the screen bounds,
	// negative inside; the glow hugs its rounded border instead of the
	// sharp screen corners
	float2 q = abs(position - halfSize) - (halfSize - cornerRadius);
	float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cornerRadius;
	float edgeDistance = max(-sdf, 0.0);
	if (edgeDistance > glowCutoff) {
		return half4(0.0);
	}

	// voice drives both thickness and brightness; at silence only a faint
	// breathing base remains, so speech reads as a strong uniform bloom
	float width = mix(glowWidth, maxGlowWidth, level);
	float energy = mix(pulse * 0.45, 1.0, level);
	float intensity = exp(-edgeDistance / width) * energy;

	// premultiplied alpha, as SwiftUI colorEffect expects
	half alpha = half(intensity) * glowColor.a;
	return half4(glowColor.rgb * alpha, alpha);
}
