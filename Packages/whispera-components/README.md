# Whispera components

Three visual components — an edge **RecordingGlow**, an **AudioMeter**, and the **EdgeMagnet**
particle field — shipping for Apple (iOS 17 and macOS 14 from one Swift target), React and Svelte.

They were ported out of the Whispera macOS app. The web is **its own implementation**, not a
wrapper: Metal does not run in a browser, so the glow and the particle field are re-derived in
WebGL2 and the meter in Canvas2D. What keeps the ports honest is that all of them read the same
constants and are measured against each other.

```
tokens/tokens.json     the only place a visual constant is authored
tokens/fixtures/       golden numbers every port of the particle field must reproduce
Package.swift          the Swift package manifest — at the root so hosts can depend by URL
apple/                 its Swift sources, [.iOS(.v17), .macOS(.v14)]
web/core/              @whispera/components-core    WebGL2 + Canvas2D, framework-agnostic
web/react/             @whispera/components-react   bindings
web/svelte/            @whispera/components-svelte  bindings
```

## tokens.json is the contract

Every number that decides how these look — the 24pt falloff, the 36pt corner radius, the particle
counts and their calibrated intensities, the motion timings — lives in `tokens/tokens.json` and
nowhere else.

Three copies are **generated** from it, because a SwiftPM resource cannot reach outside its target
and Metal cannot read JSON at runtime:

| Generated file | Consumer |
|---|---|
| `web/core/src/tokens.generated.ts` | the web packages |
| `apple/Sources/WhisperaComponents/Resources/tokens.json` | Swift, via `Bundle.module` |
| `apple/Sources/WhisperaComponents/Glow/GeneratedTokens.h` | both Metal shaders |

Edit the source, then regenerate:

```bash
pnpm sync-tokens      # rewrite the three copies
pnpm check-tokens     # exit 1 if any is stale
```

`pnpm build` and `pnpm test` both gate on `check-tokens` first. That matters more than it looks:
the Swift parity test compares the generated Metal header against the *resource* `tokens.json`, and
both are generated — so an Apple copy that is stale relative to the source is self-consistent and
would pass every per-package suite.

## Building and testing

```bash
pnpm install
pnpm build          # all web packages (gates on check-tokens)
pnpm typecheck
pnpm test           # 193 tests across core / react / svelte
```

**Apple needs Xcode, and Metal needs Xcode's build system specifically.** `swift build` has no Metal
compiler step — it copies the `.metal` source and produces no `default.metallib`, so the package
still builds and its logic still tests, but nothing renders. Build through Xcode for pixels:

```bash
swift test                                                            # 58 tests, 5 skip without a metallib
xcodebuild -scheme WhisperaComponents -destination "platform=macOS" test
xcodebuild -scheme WhisperaComponents -destination "generic/platform=iOS" build
```

### GPU checks (need a browser, so they are scripts rather than tests)

```bash
pnpm glsl-pixel-check    # renders the glow on a real GPU, compares every pixel to glowAlphaAt()
pnpm glsl-magnet-check   # transform-feedback readback of the particle field vs the fixture
pnpm glsl-link-check     # compiles and links both programs; verdict is a banner in a screenshot
```

The first two exit non-zero on failure. The third is human-checked — Firefox headless has no
`--dump-dom` — and is largely superseded by the other two.

## How the ports are kept in agreement

Each platform being correct against the tokens is not the same as the platforms agreeing with each
other. Both are checked:

| Claim | Evidence |
|---|---|
| Metal glow == Swift spec | 11200 GPU samples, max 1.08e-07 |
| WebGL2 glow == TypeScript spec | 1045 GPU pixels, max **0/255** |
| Metal particle field == fixture | 140 hash samples **exact**; 84 assembled particles, 5.42e-04 px |
| WebGL2 particle field == fixture | identical figures to Metal, to every digit |
| AudioMeter geometry | rendered and read back on both — `ImageRenderer` and Canvas2D |

`tokens/fixtures/magnet-math.json` is generated from the TypeScript once and committed; Swift and
both shader languages are written independently and measured against it, so agreement is evidence
rather than a tautology. Regenerate only when the algorithm is meant to change:

```bash
pnpm gen-magnet-fixture
```

## Reading further

Each package has its own README with the API it exposes:
[`apple`](apple/README.md) · [`web/core`](web/core/README.md) ·
[`web/react`](web/react/README.md) · [`web/svelte`](web/svelte/README.md)
