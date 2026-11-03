# Remove obsolete Python tooling

The accepted native app no longer executes Python. The checkout still contains
the old recognizer, its tests and Python-only build/check/finder commands.
Keep that implementation in `research/swift-mlx-pipeline` at `56cf8a3`, as the
owner requested, and remove it from the current development tree.

Retain Swift/MLX recognition, the exact WebRTC AEC3 dependency/configuration,
JSON transcript fixtures, user files and all existing transcript contracts.
Replace only the development commands that still require Python. No DSP
replacement, model download, migration, installation or release is included.
