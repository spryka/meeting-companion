# Design

Add an optional progress callback to the existing local availability check.
Emit the current file and count before filesystem/checksum work. Wire it through
both worker check mode (flushed stdout) and preparation's initial/final checks.
Use the existing subprocess output, service and view-model route. No new protocol,
parser, polling loop, percentage estimate, model download or inference is needed.

Settings distinguishes checking from preparation and displays the latest output
line outside Details. Completion keeps a visible success/failure state and full
details. New tests use tiny temporary corrupt/missing files and a controlled App
runner; no installed model scan is rerun by the agent.
