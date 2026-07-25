import AppKit
import Metal
import QuartzCore

private let logger = AppLogger.shared.ui

// Field layout must stay in lockstep with EdgeMagnetUniforms in EdgeMagnet.metal:
// float4s first so Swift and Metal agree on padding without explicit offsets.
private struct EdgeMagnetUniforms {
	var sourceRect: SIMD4<Float>
	var color: SIMD4<Float>
	var targetRect: SIMD4<Float>
	var viewport: SIMD2<Float>
	var progress: Float
	var fade: Float
	var time: Float
	var particleScale: Float
	var pointScale: Float
	var intensityScale: Float
	var targetMode: Float
}

/// Where the field is headed, which also decides whether it can come back.
enum EdgeMagnetRoute {
	/// Onboarding: pin to the screen border and return to the source later.
	case screenBorder
	/// Dictation: a one-way flight into the caret the text is pasted at.
	case rect(CGRect)
}

/// Everything that differs between the two routes: how much light the field
/// carries, and how long it takes. Kept together so a route is tuned in one place.
struct EdgeMagnetProfile {
	let particleCount: Int
	/// Per-particle energy, calibrated at `particleCount`. Raising it without
	/// lowering the count blows the field out.
	let intensity: Float
	/// Sprite radius in points. Large enough that neighbouring particles overlap,
	/// which is what keeps the field smooth instead of sandy.
	let spriteRadius: Float
	let outbound: CFTimeInterval
	let settle: CFTimeInterval
	let inbound: CFTimeInterval
	/// Fraction of the outbound leg after which the source window starts fading.
	let vanishCue: CFTimeInterval
	/// Fraction of the inbound leg after which the source window starts returning.
	let returnCue: CFTimeInterval

	/// Measured against `glowEdgeIntensity` at rest so the settled field and the
	/// ambient glow sit at the same alpha and the handoff is a flat crossfade.
	static let onboarding = EdgeMagnetProfile(
		particleCount: 200_000, intensity: 0.024, spriteRadius: 3.2,
		outbound: 0.55, settle: 0.3, inbound: 0.5, vanishCue: 0.12, returnCue: 0.6)

	/// Fewer and quicker: the paste it accompanies is instantaneous, and the
	/// field gathers into a caret rather than spreading along the screen border,
	/// so far less light is needed to read.
	static let dictation = EdgeMagnetProfile(
		particleCount: 24_000, intensity: 0.05, spriteRadius: 3.0,
		outbound: 0.18, settle: 0.07, inbound: 0, vanishCue: 0, returnCue: 0)
}

/// Backing view for the particle field. Owns a CAMetalLayer directly rather than
/// using MTKView, because MTKView delivers its draw callback on the main thread
/// and this animation plays while WhisperKit is loading a CoreML model on the
/// main actor — which stalled it mid-flight.
final class EdgeMagnetLayerView: NSView {
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("not supported") }

	override func makeBackingLayer() -> CALayer {
		let layer = CAMetalLayer()
		layer.isOpaque = false
		layer.pixelFormat = .bgra8Unorm
		layer.framebufferOnly = true
		return layer
	}

	var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		syncDrawableSize()
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		syncDrawableSize()
	}

	func syncDrawableSize() {
		let scale = window?.backingScaleFactor ?? 2
		metalLayer.contentsScale = scale
		metalLayer.drawableSize = CGSize(
			width: bounds.width * scale, height: bounds.height * scale)
	}
}

/// Draws the particle field that carries the window into the screen border and
/// back. Motion is a pure function of `progress`, so the renderer only has to
/// advance a clock and hand the shader a few floats.
///
/// Rendering runs on a dedicated thread so main-thread work (CoreML model
/// loading, SwiftUI layout) cannot stall the animation. Pacing comes from
/// `nextDrawable()`, which blocks until the layer has a free buffer and so
/// self-synchronises to the display; CAMetalDisplayLink is deliberately not used
/// because its callbacks are never delivered on a secondary thread on macOS.
final class EdgeMagnetRenderer {
	private enum Stage {
		case outbound(start: CFTimeInterval)
		case pinned(start: CFTimeInterval)
		case inbound(start: CFTimeInterval)
		case finished
	}

	private let layer: CAMetalLayer
	private let commandQueue: MTLCommandQueue
	private let pipelineState: MTLRenderPipelineState
	private let profile: EdgeMagnetProfile
	private let color: SIMD4<Float>
	private let sourceRect: CGRect
	private let route: EdgeMagnetRoute
	private let epoch = CACurrentMediaTime()

	// touched from both the render thread and the main thread
	private let lock = NSLock()
	private var stage: Stage
	private var hasCuedVanish = false
	private var hasCuedReturn = false

	private var renderThread: Thread?
	/// Set once the field has nothing left to draw, cleared by `reverse()`.
	private var isParked = false
	/// Captured on the main thread by `start(pointScale:)`.
	private var pointScale: Float = 2
	private var frameCount = 0

	/// Fired once the field has enough mass on screen to cover the window leaving.
	var onSourceShouldVanish: (() -> Void)?
	/// Fired while the field is still converging, so the window fades back under it.
	var onSourceShouldReturn: (() -> Void)?
	/// Fired when the inbound leg finishes and the panel can be torn down.
	var onCompleted: (() -> Void)?

	init?(layer: CAMetalLayer, device: MTLDevice, sourceRect: CGRect, route: EdgeMagnetRoute,
		color: NSColor, profile: EdgeMagnetProfile)
	{
		guard let queue = device.makeCommandQueue() else {
			logger.error("EdgeMagnet: could not create a Metal command queue")
			return nil
		}
		guard let library = device.makeDefaultLibrary(),
			let vertexFunction = library.makeFunction(name: "edgeMagnetVertex"),
			let fragmentFunction = library.makeFunction(name: "edgeMagnetFragment")
		else {
			logger.error("EdgeMagnet: shader functions missing from the default library")
			return nil
		}

		let descriptor = MTLRenderPipelineDescriptor()
		descriptor.vertexFunction = vertexFunction
		descriptor.fragmentFunction = fragmentFunction
		if let attachment = descriptor.colorAttachments[0] {
			attachment.pixelFormat = layer.pixelFormat
			// additive, premultiplied: overlapping particles build the bloom
			// instead of the last one drawn winning
			attachment.isBlendingEnabled = true
			attachment.rgbBlendOperation = .add
			attachment.alphaBlendOperation = .add
			attachment.sourceRGBBlendFactor = .one
			attachment.destinationRGBBlendFactor = .one
			attachment.sourceAlphaBlendFactor = .one
			attachment.destinationAlphaBlendFactor = .one
		}

		do {
			pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
		} catch {
			logger.error("EdgeMagnet: pipeline state failed: \(error)")
			return nil
		}

		let srgb = color.usingColorSpace(.sRGB) ?? NSColor.systemBlue
		self.layer = layer
		self.commandQueue = queue
		self.profile = profile
		self.sourceRect = sourceRect
		self.route = route
		self.color = SIMD4<Float>(
			Float(srgb.redComponent), Float(srgb.greenComponent), Float(srgb.blueComponent), 1)
		self.stage = .outbound(start: CACurrentMediaTime())
		layer.device = device
	}

	// MARK: - Lifecycle

	/// `pointScale` is read from the layer on the main thread and captured, so the
	/// render thread never touches CALayer state.
	func start(pointScale: CGFloat) {
		self.pointScale = Float(pointScale)

		let thread = Thread { [weak self] in
			while !Thread.current.isCancelled {
				guard let self else { return }
				if self.parked {
					// nothing to draw until reverse() wakes us; idle cheaply
					// rather than spinning the GPU for the whole recording
					Thread.sleep(forTimeInterval: 0.03)
					continue
				}
				// drained every frame, or the CAMetalDrawables are retained and
				// the layer's buffer pool starves
				autoreleasepool { self.renderFrame() }
			}
		}
		thread.name = "com.whispera.edge-magnet"
		thread.qualityOfService = .userInteractive
		renderThread = thread
		thread.start()
	}

	func invalidate() {
		logger.debug("EdgeMagnet: rendered \(frameCount) frames")
		renderThread?.cancel()
		renderThread = nil
	}

	private var parked: Bool {
		lock.lock()
		defer { lock.unlock() }
		return isParked
	}

	/// True once the field is already heading home. The mic closing posts several
	/// state changes in a row, and without this each one would wake the render
	/// loop back up after it had parked.
	var isReturning: Bool {
		lock.lock()
		defer { lock.unlock() }
		switch stage {
		case .inbound, .finished: return true
		case .outbound, .pinned: return false
		}
	}

	/// Starts the return leg. Safe to call at any point in the outbound leg: the
	/// clock is rewound so the field converges from wherever it currently is.
	func reverse() {
		lock.lock()
		switch stage {
		case .outbound, .pinned:
			let elapsed = Double(1 - progressLocked(at: CACurrentMediaTime()))
			stage = .inbound(start: CACurrentMediaTime() - elapsed * profile.inbound)
		case .inbound, .finished:
			break
		}
		isParked = false
		lock.unlock()
	}

	// MARK: - Rendering

	private func renderFrame() {
		let now = CACurrentMediaTime()
		frameCount += 1
		let frame = advance(to: now)

		// blocks until the layer frees a buffer, which paces this loop to the
		// display without needing a display link
		guard let drawable = layer.nextDrawable(),
			drawable.texture.width > 0, drawable.texture.height > 0,
			let buffer = commandQueue.makeCommandBuffer()
		else { return }

		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
		pass.colorAttachments[0].storeAction = .store

		guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

		let scale = pointScale
		let target: CGRect
		let targetMode: Float
		switch route {
		case .screenBorder:
			target = .zero
			targetMode = 0
		case .rect(let rect):
			target = rect
			targetMode = 1
		}
		var uniforms = EdgeMagnetUniforms(
			sourceRect: SIMD4<Float>(
				Float(sourceRect.origin.x) * scale, Float(sourceRect.origin.y) * scale,
				Float(sourceRect.width) * scale, Float(sourceRect.height) * scale),
			color: color,
			targetRect: SIMD4<Float>(
				Float(target.origin.x) * scale, Float(target.origin.y) * scale,
				Float(target.width) * scale, Float(target.height) * scale),
			viewport: SIMD2<Float>(
				Float(drawable.texture.width), Float(drawable.texture.height)),
			progress: frame.progress,
			fade: frame.fade,
			time: Float(now - epoch),
			particleScale: profile.spriteRadius * scale,
			pointScale: scale,
			intensityScale: profile.intensity,
			targetMode: targetMode
		)

		encoder.setRenderPipelineState(pipelineState)
		encoder.setVertexBytes(
			&uniforms, length: MemoryLayout<EdgeMagnetUniforms>.stride, index: 0)
		encoder.drawPrimitives(
			type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: profile.particleCount)
		encoder.endEncoding()
		buffer.present(drawable)
		buffer.commit()
	}

	// MARK: - Timeline

	/// Progress of the outbound leg at `now`, assuming the lock is held.
	private func progressLocked(at now: CFTimeInterval) -> Float {
		switch stage {
		case .outbound(let start):
			return Float(min((now - start) / profile.outbound, 1))
		case .pinned: return 1
		case .inbound(let start):
			return Float(1 - min(max((now - start) / profile.inbound, 0), 1))
		case .finished: return 0
		}
	}

	private func advance(to now: CFTimeInterval) -> (progress: Float, fade: Float) {
		var cueVanish = false
		var cueReturn = false
		var completed = false
		var park = false
		var progress: Float = 0
		var fade: Float = 0

		lock.lock()
		switch stage {
		case .outbound(let start):
			let t = (now - start) / profile.outbound
			progress = Float(min(t, 1))
			fade = 1
			if t >= profile.vanishCue, !hasCuedVanish {
				hasCuedVanish = true
				cueVanish = true
			}
			if t >= 1 { stage = .pinned(start: now) }

		case .pinned(let start):
			progress = 1
			if !hasCuedVanish {
				hasCuedVanish = true
				cueVanish = true
			}
			let t = (now - start) / profile.settle
			// the pinned field dims out and hands the border over to the
			// ambient recording glow
			fade = Float(max(0, 1 - t))
			if t >= 1 {
				if case .rect = route {
					// a one-way flight has nowhere to return to; the run ends
					// once the field has dissolved into the target
					stage = .finished
					completed = true
				}
				// otherwise nothing left to draw until reverse() wakes us, so
				// stop burning frames for however long the user keeps talking
				park = true
			}

		case .inbound(let start):
			let t = min(max((now - start) / profile.inbound, 0), 1)
			progress = Float(1 - t)
			fade = smoothstep(0, 0.12, t) * (1 - smoothstep(0.78, 1.0, t))
			if t >= profile.returnCue, !hasCuedReturn {
				hasCuedReturn = true
				cueReturn = true
			}
			if t >= 1 {
				stage = .finished
				park = true
				completed = true
			}

		case .finished:
			fade = 0
			park = true
		}
		lock.unlock()

		if park { lock.lock(); isParked = true; lock.unlock() }
		if cueVanish || cueReturn || completed {
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				if cueVanish { self.onSourceShouldVanish?() }
				if cueReturn { self.onSourceShouldReturn?() }
				if completed { self.onCompleted?() }
			}
		}
		return (progress, fade)
	}

	private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Float {
		let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
		return Float(t * t * (3 - 2 * t))
	}
}
