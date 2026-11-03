# python-free-development Specification

## Purpose
Build and validate the native application without Python or uv while preserving transcript and AEC contracts.

## Requirements

### Requirement: Python-free development commands
The first-party checkout SHALL build and validate the native app without a
Python interpreter or uv. The previous recognizer SHALL remain recoverable from
the retained research branch, without shipping or invoking it in current code.

#### Scenario: Build the native echo canceller
- **GIVEN** the pinned AEC archive is available and Python is unavailable
- **WHEN** the AEC build command runs
- **THEN** it verifies the same SHA-256 and builds the same native processor,
  library and third-party notices without changing DSP settings

#### Scenario: Validate module boundaries
- **GIVEN** Python is unavailable
- **WHEN** the module boundary check runs on valid or forbidden manifests
- **THEN** the structured graph is checked and forbidden dependencies/frameworks,
  missing targets and invalid manifests are still rejected

#### Scenario: Find the latest transcript
- **GIVEN** an explicit recordings root or optional plist configuration
- **WHEN** the exported skill finder runs without Python
- **THEN** it returns the same JSON fields for the newest filename timestamp,
  including unfinished recordings and old flat TXT, without reading audio

#### Scenario: Preserve transcript fixture contracts
- **WHEN** the old recognizer is removed
- **THEN** the existing JSON fixtures remain available to all Swift tests and
  editor checks, and no user recordings, models, preferences or installed app change
