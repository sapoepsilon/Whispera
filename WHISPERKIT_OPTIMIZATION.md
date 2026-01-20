# WhisperKit Optimization - TDD Checklist

## Overview
Implement WhisperKit's recommended configuration for optimal performance with larger models.

---

## 1. Compute Options - Different Units Per Component

WhisperKit recommends **different compute units for different model components**:

```swift
let computeOptions = ModelComputeOptions(
    melCompute: .cpuAndGPU,              // feature extraction
    audioEncoderCompute: .cpuAndGPU,     // audio encoding
    textDecoderCompute: .cpuAndNeuralEngine,  // text decoding
    prefillCompute: .cpuAndGPU           // context prefill
)
```

### Tasks

- [ ] **Test:** Write test to verify `ModelComputeOptions` is created with correct component-specific values
- [ ] **Test:** Write test to verify `melCompute` defaults to `.cpuAndGPU`
- [ ] **Test:** Write test to verify `audioEncoderCompute` defaults to `.cpuAndGPU`
- [ ] **Test:** Write test to verify `textDecoderCompute` defaults to `.cpuAndNeuralEngine`
- [ ] **Test:** Write test to verify `prefillCompute` defaults to `.cpuAndGPU`
- [ ] **Implement:** Create `getOptimizedComputeOptions()` function returning component-specific options
- [ ] **Implement:** Update `loadModel()` to use optimized compute options
- [ ] **Implement:** Update `initialize()` to use optimized compute options
- [ ] **Refactor:** Remove single `getMLComputeUnits()` in favor of component-specific approach

---

## 2. Enable Prewarm for Memory Optimization

WhisperKit recommends enabling prewarming for optimized memory usage during first load:

```swift
let config = WhisperKitConfig(
    model: "large-v3",
    computeOptions: computeOptions,
    prewarm: true  // optimize memory during first load
)
```

### Tasks

- [ ] **Test:** Write test to verify `WhisperKitConfig` is created with `prewarm: true`
- [ ] **Test:** Write test to verify model loads successfully with prewarm enabled
- [ ] **Test:** Write test to verify memory usage is optimized after prewarm (benchmark)
- [ ] **Implement:** Add `prewarm: true` to `WhisperKitConfig` in `loadModel()`
- [ ] **Implement:** Add `prewarm: true` to `WhisperKitConfig` in `initialize()`

---

## 3. Add Missing prefillCompute

The current implementation is missing `prefillCompute` in `ModelComputeOptions`.

### Tasks

- [ ] **Test:** Write test to verify `prefillCompute` is set in compute options
- [ ] **Implement:** Add `prefillCompute: .cpuAndGPU` to `ModelComputeOptions`

---

## 4. Settings UI Updates (Optional)

Consider updating the Performance settings to reflect component-specific options.

### Tasks

- [ ] **Design:** Decide if users should configure individual components or use presets
- [ ] **Test:** Write UI test for performance settings changes
- [ ] **Implement:** Update `SettingsView` Performance section if needed
- [ ] **Implement:** Add preset options (e.g., "Optimized", "Power Saving", "Maximum Performance")

---

## Implementation Reference

### Target Code for `loadModel()`

```swift
private func loadModel(_ modelName: String) async throws {
    isModelLoading = true
    loadProgress = 0.0

    do {
        await updateLoadProgress(0.2, "Preparing to load \(modelName)...")

        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndNeuralEngine,
            prefillCompute: .cpuAndGPU
        )

        await updateLoadProgress(0.6, "Loading \(modelName)...")

        whisperKit = try await Task { @MainActor in
            let config = WhisperKitConfig(
                model: modelName,
                downloadBase: baseModelCacheDirectory,
                computeOptions: computeOptions,
                prewarm: true
            )
            let whisperKitInstance = try await WhisperKit(config)
            self.setupModelStateCallback(for: whisperKitInstance)
            return whisperKitInstance
        }.value

        // ... rest of implementation
    }
}
```

### Target Code for `initialize()`

```swift
func initialize() async {
    // ... existing code ...

    if !downloadedModels.isEmpty {
        await updateProgress(0.8, "Loading existing model...")
        do {
            whisperKit = try await Task { @MainActor in
                let computeOptions = ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndNeuralEngine,
                    prefillCompute: .cpuAndGPU
                )

                let config = WhisperKitConfig(
                    downloadBase: baseModelCacheDirectory,
                    computeOptions: computeOptions,
                    prewarm: true
                )
                let whisperKitInstance = try await WhisperKit(config)
                self.setupModelStateCallback(for: whisperKitInstance)
                return whisperKitInstance
            }.value
            // ...
        }
    }
}
```

---

## Notes

### sampleLength
The `sampleLength: 224` fix is a safe default to prevent KV cache overflow crashes. This is not explicitly documented by WhisperKit but addresses CoreML-level array bounds errors with larger models.

### Testing Strategy
1. Unit tests for configuration creation
2. Integration tests for model loading with new options
3. Performance benchmarks comparing old vs new configuration
4. Manual testing with large-v3 and distil-large-v3 models

---

## Progress

| Phase | Status |
|-------|--------|
| Tests Written | [ ] |
| Implementation | [ ] |
| Code Review | [ ] |
| Manual Testing | [ ] |
| Merged | [ ] |
