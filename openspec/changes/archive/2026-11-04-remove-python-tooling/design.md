# Design

Owner approved removal after confirming the previous branch remains available.
Use macOS shell tools for the pinned AEC archive, SHA-256 verification, C++
compilation and license collection. Keep the same URL, digest, compiler flags,
library install name and notices. Verify the archive before extraction; failed
downloads must not replace the cached verified archive.

Decode the SwiftPM graph with Foundation in a Swift script; retain all current
boundary checks and fail-closed errors. Replace the exported skill's finder
with a Foundation-only Swift script, retaining plist configuration, explicit
root, filename ordering, unfinished/new and legacy flat discovery.

Move shared JSON fixtures under Tests/Fixtures and the unchanged C++ processor
under Sources/WebRTCAEC (outside SwiftPM targets). Remove the obsolete Python
recognizer/tests/probes/launcher. Keep historical research documents and accepted
ADRs; update executable instructions and links without rewriting history.

TDD: first confirm the Python-free checkout check fails on the original files;
retain graph counterexamples and finder behavior checks. Validate release,
fixtures/editor tests and standalone AEC compilation with Python blocked in PATH.
No new audio or inference is required because DSP and runtime behavior are unchanged.
