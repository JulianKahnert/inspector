---
name: inspector
description: >-
  Drives a running iOS or macOS debug build through the `inspector` CLI: navigate to a screen,
  read its state, trigger actions, take a simulator screenshot. Use to check a change in the
  running app, reproduce a bug on a deep screen, or on "inspector hello/catalog/state/send".
---

## Overview

`inspector` reaches into a running debug build that registers state readers and actions and calls
`Inspector.shared.serve()` (README → *Integrating from an app or a feature package*). This skill
gets an agent from "the app is running" to "I'm on the right screen, I can see it, and I know the
state behind it". Tests and logs can't show that, and a screenshot alone can't get you there.

Every command goes through the scripts below. They build the CLI when needed and poll instead of
sleeping; the CLI bounds each call itself.

## State first, screenshots as the fallback

Read the state to find out where the app is and what it shows. A state answer is a few hundred
bytes of JSON. A screenshot is a full-resolution image: slower to take, far more tokens to read,
and a picture you still have to interpret. So:

- **Check every step with `state` or `wait-state.sh`**, including where you are when you start.
  Which keys exist tells you which screens are alive; a sheet left open by an earlier session
  shows up as its key.
- **Take a screenshot only when the state can't answer**: a step fails and the state doesn't say
  why, state and behaviour disagree, or the question is visual (layout, colour, clipping).
- **When a screenshot shows something the task needed and the state lacks it**, add that value to
  the screen's registration right away, rebuild, and read it from the state from then on. Treat
  every screenshot you needed as a gap in the registrations, so the next run doesn't need it.

## Workflow

1. **Connect and find out where the app is.** Run `scripts/inspector.sh hello`, then
   `scripts/inspector.sh state`: the app may still show a sheet or a deep screen from an earlier
   session, and the route has to start from there. The first call builds the CLI (a few seconds);
   later calls take about 20–100 ms. `APP_NOT_FOUND` means no debug build is serving: ask the
   user to start the app instead of retrying. `TIMEOUT` means the app stopped answering, for
   example at a breakpoint. `AMBIGUOUS_APP` means several apps
   serve: pick one with `--app` (see `references/cli.md` → *Several apps*).
2. **See what's on offer.** `scripts/inspector.sh catalog` lists the actions and their payload
   schemas, and `scripts/inspector.sh state` shows the current state. Both only cover screens whose
   model exists now, so they grow as you navigate.
3. **Plan the route.** Map the goal ("members of a channel's details", "the settings sheet") to a
   chain of actions, and read the value each step needs from the state of the step before. An
   `int` payload can be a row index or a domain id; the action's name and that state show which.
   The inspector has no generic back: to leave a screen, use its close action if it has one, or
   an action higher up the route that rebuilds everything below it (opening another list entry,
   switching tabs).
   When an action you need isn't in the catalog, open the screen that owns it first. If no screen
   registers it at all, the app needs a new registration: follow *Integrating* below, with the
   user's go-ahead, instead of tapping around it.
4. **Navigate step by step.** After each `scripts/inspector.sh send <path> [json]` that pushes a
   screen or presents a sheet, run `scripts/wait-state.sh '<jq filter for the next screen>'`
   before the next step. That usually takes 100–200 ms and sometimes a second. Don't read an
   empty `diff` as failure: the new screen registers after the action has returned. A top-level
   key that contains a dot can't be read with `state <key>`; filter the whole state with
   `wait-state.sh` or `jq` instead, and quote it: `'."settings.detail".rows'`.
5. **Answer from the state.** Read the values the task asks about from the target screen's
   state. Each `send` answer's `diff` shows what that action changed; see `references/cli.md`
   for the error codes.
6. **Fall back to a screenshot only if the state can't answer** (see *State first* above): run
   `scripts/screenshot.sh [file.png]` and read the PNG it prints. If it showed something the
   state should have carried, extend the registration before you report.
7. **Report** the route you took (the actions in order), the state values that answer the task,
   whether a screenshot was needed and which registration you added so it won't be next time,
   and anything you couldn't reach.

**Example route** (the paths are whatever the app registered; `catalog` names them):

```sh
scripts/inspector.sh send tabs.select settings
scripts/wait-state.sh '."settings.list" | length > 0'
scripts/inspector.sh send settings.open 2
scripts/wait-state.sh '."settings.detail".isLoading == false'
scripts/inspector.sh state | jq '."settings.detail"'
```

Actions change real app data when the app wires them to real use cases, such as sending a message
or deleting an entry. Before sending one like that, check whether it only navigates. If it writes
data, ask first.

## Integrating into an app or package

When the app has no inspector yet, a route is missing a step, or a screen's state leaves out
something it shows, add to the temporary debug integration. Register the state of each screen so
it mirrors what the screen shows (see `references/integration.md` → *What a screen's state should
carry*); every value missing there turns into a screenshot later. Follow `references/integration.md`: `scripts/add-to-package.sh` adds the dependency,
then fill the copied `assets/DebugInspector.swift` template's `<#placeholders#>`
(they keep the file from compiling until every one is filled). Add `registerInspector()` to each
init, then `serve()` and the `Info.plist` keys. Mark every line `// DEBUG INSPECTOR`. To take it
out again, run `scripts/find-debug-markers.sh <dirs>` and work through its list.

## References

| Topic | File | When |
|---|---|---|
| Every command, the `send` answer, payload schemas, error codes, several apps, screenshots | `references/cli.md` | When a call is rejected, or before using a command for the first time |
| Adding and removing a debug integration: manifests, registrations, serve, plist, pitfalls | `references/integration.md` | Before touching an app's or package's code |

## Scripts

- `scripts/inspector.sh [--app name] <command…>` — the CLI with a build-if-missing step
  (`INSPECTOR_REBUILD=1` forces a build). `apps` lists every serving app.
- `scripts/wait-state.sh '<jq filter>' [seconds]` — polls `state` until the filter yields something
  other than `null` or `false`; prints the value, and the elapsed time on stderr.
- `scripts/screenshot.sh [file.png] [UDID]` — PNG of the booted iOS simulator; prints its path.
- `scripts/add-to-package.sh <package dir> <target> [--ios-only] [--copy-template]` — adds
  InspectorKit via `swift package add-dependency` / `add-target-dependency`, marked, and rolls
  the manifest back on failure.
- `scripts/find-debug-markers.sh <dir…>` — every `DEBUG INSPECTOR` file and line, for removal.

## Assets

- `assets/DebugInspector.swift` — registration template for a list screen and a detail screen.
