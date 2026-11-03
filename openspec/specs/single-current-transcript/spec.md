# single-current-transcript Specification

## Purpose
Expose one current transcript with safe manual corrections, atomic publication and explicit recording ownership.

## Requirements

### Requirement: One current result

The app SHALL expose one current transcript without a recognition-version picker or prior-result navigation. Technical result IDs SHALL remain internal for storage/edit binding. Successful reprocessing SHALL show the new current result in App, reopening and companion text, ignoring prior selectedResultID. Unsupported or corrupt current results SHALL NOT cause selection of older results.

#### Scenario: Successful retry
- **GIVEN** a recording with an existing result, possibly old selectedResultID metadata, and preserved source WAVs
- **WHEN** the user explicitly reprocesses it and publication succeeds
- **THEN** the GUI and reopening show the new current transcript without a version menu
- **AND** existing original audio and historical files remain untouched

#### Scenario: Failure or cancellation before commit
- **WHEN** reprocessing fails or is cancelled before directory rename
- **THEN** the UI reports the failed attempt and permits retry after teardown
- **AND** source audio and previously saved data remain intact; old text is not reported as the new attempt's success
- **AND** no incomplete result becomes current

### Requirement: Safe manual corrections

Manual correction of text and speaker names, listening, copying/export and current-result edit persistence SHALL remain. Reprocessing SHALL NOT map old manual edits onto different new turn IDs. Unsaved edits SHALL require save/discard/cancel before destructive navigation or replacement; the current editor SHALL NOT allow an obsolete draft/session to save into the new result. Unnecessary version navigation SHALL be removed, while close-window unsaved protection SHALL remain.

#### Scenario: Delayed replacement with editor open
- **GIVEN** the current transcript is open for manual correction
- **WHEN** reprocessing or its publication overlaps editing
- **THEN** the current-result transition explicitly preserves/resolves the draft and invalidates obsolete editing safely
- **AND** there is no async version-switch route that silently clears a newly entered draft

### Requirement: Schema compatibility and manual reprocessing

GUI compatibility SHALL depend on standard folder ownership, supported JSON v1 and validated artifacts, independently of producer, age or metadata markers. The extra marker SHALL NOT be written or gate eligibility; old tokens/duplicates SHALL NOT require migration. Retry in supported folders SHALL require the exact contained raw source pair, without flat fallback or mix substitution.

#### Scenario: Existing supported result
- **GIVEN** a valid supported JSON result, including one created by Python or an earlier beta
- **WHEN** it is opened
- **THEN** current viewing/correction/listening capabilities work without reprocessing or discovery writes

#### Scenario: Unsupported or absent result with original sources
- **GIVEN** a missing/unsupported result and a supported contained original source pair
- **WHEN** the user views the entry
- **THEN** available saved text is read-only and manual reprocessing is offered
- **AND** processing starts only on the explicit command and a successful new result can be opened normally

#### Scenario: Repeated lifecycle saves
- **WHEN** the app starts/stops/processes/saves a recording repeatedly
- **THEN** metadata remains readable after actual disk reload and GUI open
- **AND** unknown high-precision fields, user files and relevant durable state are preserved

### Requirement: Originals and derivatives

New recordings SHALL store timeline-aligned original microphone/system WAVs in raw/ with existing host_record/remote_record filenames. AEC output and playback SHALL remain separate derivatives. Processing SHALL NOT mutate, relabel or substitute originals. Flat placement SHALL remain list plus saved text read-only. No migration or deletion is permitted.

#### Scenario: AEC processing and retry
- **WHEN** a source pair is processed with AEC or reprocessed with different settings
- **THEN** original source hashes and paths remain unchanged
- **AND** the viewer plays the derived audio belonging to its current result, with truthful availability/warnings

#### Scenario: Existing flat sources
- **WHEN** a nonstandard flat entry has original WAVs and shared structured results
- **THEN** it remains list plus its available standalone saved TXT read-only, without processing or shared result access
- **AND** all files remain at their original paths

### Requirement: Standard recording ownership

Full features SHALL require the canonical containing folder basename to equal the recording stem. Raw existence SHALL NOT establish ownership. Unsupported entries SHALL reject capture, processing and every durable mutation before side effects. Descriptive flat metadata SHALL retain its exact root read path. Standard structured results SHALL retain full viewing/editing/playback without source WAVs; only retry requires originals.

#### Scenario: Owner and flat neighbour
- **GIVEN** owner D/D.m4a and neighbour D/other.m4a sharing D/raw
- **WHEN** history, window, retry or persistence is invoked for other
- **THEN** other cannot resolve/edit/play D's structured result or write files
- **AND** D retains its supported capabilities

#### Scenario: Capture before raw exists
- **GIVEN** a dedicated D/D.m4a output and no raw directory yet
- **WHEN** capture starts
- **THEN** standard ownership is accepted before capture creates raw files

#### Scenario: Flat metadata remains read-only
- **GIVEN** flat A/B with precise unknown root metadata and optional saved TXT
- **WHEN** raw appears or capture/processing/history writes are attempted
- **THEN** original metadata paths and bytes remain unchanged and display reload uses root metadata
- **AND** an entry without saved TXT has no transcript available

### Requirement: Single publication commit
Current SHALL be the newest contained non-staging directory by filesystem creation date/name tie-breaker, chosen before schema validation and ignoring selectedResultID. Atomic rename after staging mandatory files including text SHALL be the commit. Precommit failure SHALL preserve prior current; postcommit failure SHALL retain new current with warnings. Root TXT SHALL be a derived cache, never current authority.

#### Scenario: Newest unsupported result
- **GIVEN** supported A, newer unsupported/corrupt B and selectedResultID=A
- **WHEN** the entry is opened
- **THEN** B is the current unavailable structured result, available saved text may be read-only, and A is not silently selected

#### Scenario: Root export fails after commit
- **WHEN** B commits and root TXT refresh fails
- **THEN** B remains current across reopen, B text remains available from its committed artifacts and an explicit export warning is surfaced

#### Scenario: Flat file alias and escaping originals
- **GIVEN** other.m4a symlinks to the standard owner, or an exact raw source symlinks outside the owner folder
- **WHEN** Worker recording mode resolves its input
- **THEN** the flat identity or escaping original is rejected before pipeline execution
- **AND** canonical directory aliases and standard file/directory invocation retain their contract
