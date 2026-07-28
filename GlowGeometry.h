#ifndef GLOW_GEOMETRY_H
#define GLOW_GEOMETRY_H

// Shared by RecordingGlow.metal and EdgeMagnet.metal so the magnet particles pin
// themselves onto exactly the path the ambient glow occupies, at the same
// brightness. If these drift, the handoff between the two effects shows up as a
// jump in either position or exposure.

// Falloff scale of the ambient glow, in points, at silence.
constant float glowWidth = 24.0;
// Widest possible glow at full voice level.
constant float maxGlowWidth = glowWidth * 3.0;
// exp(-4.6) < 1%: past this distance the glow is invisible, skip the math.
constant float glowCutoff = maxGlowWidth * 4.6;
// Radius of the rounded rectangle both effects hug, in points.
constant float glowCornerRadius = 36.0;

// Alpha the ambient glow puts on screen `edgeDistance` points inside the
// border. The magnet calibrates its settled particle field against this so the
// crossfade between the two is flat rather than a flare that decays.
static inline float glowEdgeIntensity(float edgeDistance, float level, float pulse) {
	// voice drives both thickness and brightness; at silence only a faint
	// breathing base remains, so speech reads as a strong uniform bloom
	float width = metal::mix(glowWidth, maxGlowWidth, level);
	float energy = metal::mix(pulse * 0.45, 1.0, level);
	return metal::exp(-edgeDistance / width) * energy;
}

// The level/pulse the glow sits at while idle. The handoff happens at the end
// of the outbound leg, before anyone has spoken, so this is the state the
// settled particle field has to match.
constant float glowRestLevel = 0.0;
constant float glowRestPulse = 0.8;

#endif
