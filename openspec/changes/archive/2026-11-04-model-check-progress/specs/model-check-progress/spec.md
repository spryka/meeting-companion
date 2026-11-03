## ADDED Requirements

### Requirement: Visible local model check progress
The application SHALL show discrete progress while local model assets are checked,
without hiding the current operation inside a collapsed details disclosure.

#### Scenario: Check a large local asset
- **WHEN** the worker begins checking a required file
- **THEN** it emits and flushes the file name and file count before reading its bytes
- **AND** checksum validation remains enabled and local

#### Scenario: Preparation checks existing files
- **WHEN** preparation first verifies existing model assets
- **THEN** it forwards the same per-file progress instead of silently hashing them

#### Scenario: Settings reports progress and completion
- **WHEN** the owner starts Check
- **THEN** Settings shows checking state and the latest output outside Details
- **AND** completion displays success or failure with details retained

#### Scenario: Queue snapshots arrive during a check
- **GIVEN** the worker has reported a file or completed the check
- **WHEN** the Application service publishes another busy or idle snapshot
- **THEN** the snapshot does not replace progress or the final result with a generic starting message
