#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float glowWidth = 28.0;
// exp(-4.6) < 1%: past this distance the glow is invisible, skip the math
constant float glowCutoff = glowWidth * 4.6;
constant float cornerRadius = 36.0;
constant float tau = 6.2831853;

[[stitchable]] half4 recordingGlow(
	float2 position, half4 color, float4 bounds, half4 glowColor, float time, float pulse
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

	float2 centered = position - halfSize;
	float angle = atan2(centered.y, centered.x) / tau;
	// brightness-only wave traveling around the border; hue stays fixed
	float travel = 0.6 + 0.4 * cos((angle - time * 0.2) * 2.0 * tau);
	float intensity = exp(-edgeDistance / glowWidth) * pulse * travel;

	// premultiplied alpha, as SwiftUI colorEffect expects
	half alpha = half(intensity) * glowColor.a;
	return half4(glowColor.rgb * alpha, alpha);
}
