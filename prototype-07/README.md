# Prototype 07: the interleaved loop on RoommateAlbert

Throwaway code for Wayfinder ticket 07 (`~/KnowledgeBase/Resources/inspector/app-integration/07-prototyp--loop-auf-roommatealbert.md`), 2026-10-22.
Never merge this branch. The verdict lives in the ticket's answer and in `spec.md` next to it.

- `BonjourTransport.swift` on this branch skips the 500 ms second-app grace period when `--app` names an instance that is already present.
- `loop.sh <label> <inspector args…>` times one CLI call and appends to `timings.csv`.
- `until.sh '<jq filter>' [s]` polls `state` until the filter holds.
- `targets.sh <hierarchy.txt>` filters an Xcode-MCP hierarchy to interactive elements as JSON.
