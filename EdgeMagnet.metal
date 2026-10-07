#include <metal_stdlib>
#include "GlowGeometry.h"
using namespace metal;

// Field layout must stay in lockstep with EdgeMagnetUniforms in
// EdgeMagnetRenderer.swift: float4s first so both compilers agree on padding.
struct EdgeMagnetUniforms {
	float4 sourceRect;    // origin.xy / size.zw, drawable pixels, bottom-left origin
	float4 color;         // ambient glow tint, rgb used
	float4 targetRect;    // destination when targetMode is 1, same convention
	float2 viewport;      // drawable size in pixels
	float progress;       // 0 = pooled over the source rect, 1 = arrived
	float fade;           // global opacity envelope
	float time;           // seconds, drives shimmer only
	float particleScale;  // base sprite radius in pixels
	float pointScale;     // pixels per point, converts the shared glow geometry
	float intensityScale; // per-particle energy, budgeted against particle count
	float targetMode;     // 0 = pin to the screen border, 1 = gather into targetRect
};

struct EdgeMagnetVertexOut {
	float4 position [[position]];
	float2 sprite;
	float3 tint;
	float intensity;
};

// Decorrelated streams off one instance id. Everything a particle needs is
// derived here, so the system stays stateless: no buffers, no simulation step,
// and any frame can be drawn without the ones before it.
static inline float randomStream(uint id, uint salt) {
	uint n = id * 747796405u + salt * 2891336453u;
	n = (n ^ (n >> 17)) * 668265263u;
	n = n ^ (n >> 15);
	return float(n & 0x00ffffffu) / float(0x01000000u);
}

struct BorderAnchor {
	float2 point;
	float2 inward;
};

// Walks the same rounded rectangle the ambient glow hugs, by arc length so
// particles spread evenly instead of piling into the corners. Sharing
// glowCornerRadius with RecordingGlow.metal is what lets the pinned field and
// the glow occupy the same path.
static inline BorderAnchor borderAnchor(float t, float2 size, float radius) {
	float straightX = max(size.x - 2.0 * radius, 0.0);
	float straightY = max(size.y - 2.0 * radius, 0.0);
	float quarter = max(M_PI_F * 0.5 * radius, 1e-3);
	float distance = fract(t) * (2.0 * (straightX + straightY) + 4.0 * quarter);

	BorderAnchor anchor;
	if (distance < straightX) {
		anchor.point = float2(radius + distance, 0.0);
		anchor.inward = float2(0.0, 1.0);
		return anchor;
	}
	distance -= straightX;
	if (distance < quarter) {
		float angle = -M_PI_F * 0.5 + (distance / quarter) * M_PI_F * 0.5;
		float2 normal = float2(cos(angle), sin(angle));
		anchor.point = float2(size.x - radius, radius) + normal * radius;
		anchor.inward = -normal;
		return anchor;
	}
	distance -= quarter;
	if (distance < straightY) {
		anchor.point = float2(size.x, radius + distance);
		anchor.inward = float2(-1.0, 0.0);
		return anchor;
	}
	distance -= straightY;
	if (distance < quarter) {
		float angle = (distance / quarter) * M_PI_F * 0.5;
		float2 normal = float2(cos(angle), sin(angle));
		anchor.point = float2(size.x - radius, size.y - radius) + normal * radius;
		anchor.inward = -normal;
		return anchor;
	}
	distance -= quarter;
	if (distance < straightX) {
		anchor.point = float2(size.x - radius - distance, size.y);
		anchor.inward = float2(0.0, -1.0);
		return anchor;
	}
	distance -= straightX;
	if (distance < quarter) {
		float angle = M_PI_F * 0.5 + (distance / quarter) * M_PI_F * 0.5;
		float2 normal = float2(cos(angle), sin(angle));
		anchor.point = float2(radius, size.y - radius) + normal * radius;
		anchor.inward = -normal;
		return anchor;
	}
	distance -= quarter;
	if (distance < straightY) {
		anchor.point = float2(0.0, size.y - radius - distance);
		anchor.inward = float2(1.0, 0.0);
		return anchor;
	}
	distance -= straightY;
	float angle = M_PI_F + (distance / quarter) * M_PI_F * 0.5;
	float2 normal = float2(cos(angle), sin(angle));
	anchor.point = float2(radius, radius) + normal * radius;
	anchor.inward = -normal;
	return anchor;
}

// Fraction of the timeline spent handing out staggered release times.
constant float staggerSpan = 0.35;

vertex EdgeMagnetVertexOut edgeMagnetVertex(
	uint vertexID [[vertex_id]],
	uint instanceID [[instance_id]],
	constant EdgeMagnetUniforms &uniforms [[buffer(0)]]
) {
	float originX = randomStream(instanceID, 0u);
	float originY = randomStream(instanceID, 1u);
	float anchorT = randomStream(instanceID, 2u);
	float release = randomStream(instanceID, 3u);
	float sizeBias = randomStream(instanceID, 4u);
	float arcBias = randomStream(instanceID, 5u);
	float depthBias = randomStream(instanceID, 6u);

	float2 start = uniforms.sourceRect.xy + uniforms.sourceRect.zw * float2(originX, originY);

	float2 target;
	if (uniforms.targetMode > 0.5) {
		// gather into a destination rect — the caret the transcription is being
		// pasted into — rather than spreading along the screen border
		target = uniforms.targetRect.xy + uniforms.targetRect.zw * float2(anchorT, depthBias);
	} else {
		float radius = glowCornerRadius * uniforms.pointScale;
		float falloff = glowWidth * uniforms.pointScale;
		BorderAnchor anchor = borderAnchor(anchorT, uniforms.viewport, radius);

		// inverse-CDF sample of exp(-depth / glowWidth): the settled particle
		// density then matches the ambient glow's own falloff, so the crossfade
		// at the end of the outbound leg has nothing to give away. The
		// distribution is truncated rather than clamped: clamping would stack
		// the whole tail onto one depth and draw a hard line there.
		float depthSpan = 1.0 - exp(-4.0);
		float depth = -falloff * log(max(1.0 - depthBias * depthSpan, 1e-4));
		// a sprite sitting exactly on the border loses its outer half to
		// clipping, which hollows out the outermost points; bias the whole band
		// out by half a sprite so the density peak lands on the border like the
		// glow's does
		target = anchor.point + anchor.inward * (depth - uniforms.particleScale * 0.5);
	}

	// each particle leaves on its own beat: the field peels off the window
	// rather than sliding away as one rigid sheet
	float local = saturate((uniforms.progress - release * staggerSpan) / (1.0 - staggerSpan));

	// smoothstep softens the release; blending toward a cubic keeps the tail
	// accelerating, which is what sells the magnetic snap onto the border
	float eased = mix(local * local * (3.0 - 2.0 * local), local * local * local, 0.35);

	float2 travel = target - start;
	float span = max(length(travel), 1.0);
	float2 forward = travel / span;
	float2 sideways = float2(-forward.y, forward.x);

	float heat = sin(saturate(eased) * M_PI_F);
	float arc = (arcBias - 0.5) * 2.0 * min(span * 0.18, 240.0);
	float2 centre = mix(start, target, eased) + sideways * arc * heat;

	// stretch into a comet at mid-flight, round back out as it parks
	float stretch = 1.0 + 4.0 * heat;
	float sprite = uniforms.particleScale * mix(0.65, 1.45, sizeBias);

	float2 corner = float2(
		(vertexID & 1u) != 0u ? 1.0 : -1.0,
		(vertexID & 2u) != 0u ? 1.0 : -1.0
	);
	float2 pixel = centre + forward * corner.x * sprite * stretch + sideways * corner.y * sprite;

	EdgeMagnetVertexOut out;
	out.position = float4(pixel / uniforms.viewport * 2.0 - 1.0, 0.0, 1.0);
	out.sprite = corner;

	float born = smoothstep(0.0, 0.06, local);
	float shimmer = 0.82 + 0.18 * sin(uniforms.time * 7.0 + originX * 63.0);
	// a brief flare as it clamps onto the border, the visual "click" of a magnet
	float impact = 1.0 + 0.35 * exp(-pow((local - 0.92) / 0.06, 2.0));
	// each particle stays dim on its own; the border reads bright only because
	// tens of thousands of them accumulate there, which is what keeps the
	// settled field smooth instead of sandy
	//
	// mid-flight the field is spread over the whole screen, and at full
	// brightness it curtains the desktop instead of streaking across it. Both
	// endpoints keep their calibrated brightness because heat is zero there.
	float flightDim = mix(1.0, 0.4, heat);
	// gathering into a caret-sized rect would stack every particle into one
	// blinding dot, so they dim as they land: the text field absorbs them
	float absorb = uniforms.targetMode > 0.5 ? 1.0 - smoothstep(0.55, 1.0, local) : 1.0;
	out.intensity =
		born * shimmer * impact * flightDim * absorb * uniforms.fade * uniforms.intensityScale;
	// only the airborne particles run hot; a settled one is exactly the glow's
	// own colour, so the handoff is a pure crossfade with no hue shift
	out.tint = mix(uniforms.color.rgb, float3(1.0), 0.35 * heat);
	return out;
}

fragment half4 edgeMagnetFragment(EdgeMagnetVertexOut in [[stage_in]]) {
	// radial falloff in the stretched sprite space, so a mid-flight particle
	// reads as an elongated streak and a parked one as a round mote
	float profile = exp(-3.2 * dot(in.sprite, in.sprite));
	float alpha = profile * in.intensity;
	// premultiplied; the pipeline blends these additively
	return half4(half3(in.tint * alpha), half(alpha));
}
