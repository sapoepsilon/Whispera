#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
#include "GlowGeometry.h"
using namespace metal;

[[stitchable]] half4 recordingGlow(
	float2 position, half4 color, float4 bounds, half4 glowColor, float time, float pulse,
	float level
) {
	float2 halfSize = bounds.zw * 0.5;
	// signed distance to a rounded rectangle inset to the screen bounds,
	// negative inside; the glow hugs its rounded border instead of the
	// sharp screen corners
	float2 q = abs(position - halfSize) - (halfSize - glowCornerRadius);
	float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - glowCornerRadius;
	float edgeDistance = max(-sdf, 0.0);
	if (edgeDistance > glowCutoff) {
		return half4(0.0);
	}

	float intensity = glowEdgeIntensity(edgeDistance, level, pulse);

	// premultiplied alpha, as SwiftUI colorEffect expects
	half alpha = half(intensity) * glowColor.a;
	return half4(glowColor.rgb * alpha, alpha);
}
