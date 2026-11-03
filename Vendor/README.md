# Vendored Third-Party Dependencies

This directory contains offline source closures, pinned package dependencies, licenses, and patches for Meeting Companion's MLX speech and audio pipelines.

## Vendored Targets

### 1. GigaAMKit (`Vendor/GigaAMKit`)
- **Pristine Upstream**: `https://github.com/kruatech/gigaam-v3-mlx` @ `95bd42a4b9a65450a24e1898c7d84b85e0e88509`
- **License**: MIT (`Vendor/LICENSES/GigaAM-MIT-LICENSE.txt`)
- **Patch**: `Vendor/patches/gigaam.patch`
  - `Features/MelSpectrogram.swift`: MLX-accelerated FFT (`MLXFFT.rfft`) and matmul replacing CPU loop DFT tables.
  - `Model/GigaAMRNNTHead.swift`: `bestRNNTToken` using Accelerate `vDSP_maxvi` on shared memory buffer (`asData(access: .noCopyIfContiguous)`).
  - `Model/RNNTGreedyDecoder.swift`: uses `bestRNNTToken`.
  - `Runtime/GigaAMTensorStore.swift`: optional `computeDType: DType? = nil` parameter for research F32 override support.
- 25 files are 100% byte-for-byte identical to pristine upstream.

### 2. Nemotron Diarization & SpeechVAD (`Vendor/Nemotron`)
- **Pristine Upstream**: `https://github.com/soniqo/speech-swift` @ `f8ca61de3902b22e3e3a1434c680c1b21d8d48af`
- **License**: Apache-2.0 (`Vendor/LICENSES/SpeechSwift-Apache-LICENSE.txt`), Third-Party Notices (`Vendor/LICENSES/speech-swift/`)
- **Patch**: `Vendor/patches/nemotron.patch`
  - 5 files identical to upstream: `PowersetDecoder.swift`, `SortformerStateUpdater.swift`, `SortformerConfig.swift`, `SortformerMelExtractor.swift`, `SDPA.swift`.
  - 3 files adapted for offline execution: `Nemotron3Diarizer.swift` (offline `diarize(samples:sampleRate:configuration:)`), `DiarizationHelpers.swift`, `Nemotron3MLXModel.swift`.
  - 3 extracted helpers: `Binarize.swift`, `Types.swift`, `BaselineMelExtractor.swift`.
- **DSP MelFeatures Provenance**:
  - `BaselineMelExtractor.swift` implements BF16 DSP MelFeatures following `PrinceCanuma/mlx-audio` Python v0.5.8 `MelFeatures` (`mlx_audio/vad/models/nemotron_diarization/nemotron_diarization.py`, lines 24-71, SHA-256 `e56ab019f0d3400cb19ebc2deefcd7575b418dec60a6ab4bdafe322579636683`), verified against the frozen baseline documented in `openspec/changes/swift-mlx-pipeline/baseline.md` (lines 40-48: `Python 3.12.12`, `mlx-audio 0.5.8`). Licensed under MIT (`Vendor/LICENSES/MLXAudioPython-MIT-LICENSE.txt`).

### 3. Silero VAD (`Vendor/Silero`)
- **Pristine Upstream**: `https://github.com/Blaizzy/mlx-audio-swift` @ `d4fa7be1c2fef65ed13a4f73bd58e0a23a0ba307`
- **License**: MIT (`Vendor/LICENSES/MLXAudio-MIT-LICENSE.txt`)
- **Patch**: `Vendor/patches/silero.patch`
  - `SileroVADConfig.swift`: 100% byte-for-byte identical to upstream.
  - `SileroVAD.swift`: Offline loading support (`fromModelDirectory`) with optional `include8k` defaulting to `false` for 16kHz memory optimization.

### 4. MLXAudio Swift Package (`Vendor/mlx-audio-swift`)
- **Pristine Upstream**: `https://github.com/Blaizzy/mlx-audio-swift` @ `d4fa7be1c2fef65ed13a4f73bd58e0a23a0ba307`
- **License**: MIT (`Vendor/mlx-audio-swift/LICENSE`)
- **Embedded Licensing**:
  - `Sources/MLXAudioSTT/Models/Phonon2`: Apache-2.0, Copyright 2026 Fermion Research (`Vendor/LICENSES/MLXAudio-Phonon2-Apache-LICENSE.txt`, notice: `Vendor/LICENSES/MLXAudio-Phonon2-NOTICE.txt`).
- **Patch**: `Vendor/mlx-audio-manifest.patch` (adds `MLXFFT` dependency to `MLXAudioSTT` target in `Package.swift`); `Vendor/patches/parakeet-public-timing.patch` (adds `ParakeetTiming.swift` public adapter for production builds without `@testable`).
- Pinned minimal buildable set: `Package.swift`, `Package.resolved`, `LICENSE`, `Sources/` (598 files), `Tests/` (91 files).

## Transitive Dependency Graph & Embedded Licenses

See `Vendor/dependency-licenses.json` for full machine-readable licensing and notice metadata.
Embedded Cmlx subcomponents in `mlx-swift` (0.32.3 @ `19601207e9a0de51e03ee6ec0c3c5f3784275075`):
- `metal-cpp`: Apache-2.0 (`Vendor/LICENSES/mlx-swift/metal-cpp-LICENSE.txt`)
- `json` (nlohmann/json): MIT (`Vendor/LICENSES/mlx-swift/json-LICENSE.MIT`)
- `fmt`: MIT with exception (`Vendor/LICENSES/mlx-swift/fmt-LICENSE`)
- `mlx-c`: MIT (`Vendor/LICENSES/mlx-swift/mlx-c-LICENSE`)
- `mlx` (mlx-core): MIT (`Vendor/LICENSES/mlx-swift/mlx-LICENSE`)
