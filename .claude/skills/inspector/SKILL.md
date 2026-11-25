---
name: inspector
description: >-
  Drives a running iOS or macOS debug build through the `inspector` CLI: start it, navigate to a
  screen, read its state, tap, swipe and type in the simulator. Use to check a change in the
  running app, reproduce a bug on a deep screen, add or remove an app's debug integration, or on
  "inspector init/state/send/tap".
---

`inspector` reads the state of a debug build that registers state readers and actions and calls
`serve()`, sends it actions, and performs gestures in the simulator through Xcode. Every call is
one Bash command with one JSON document on stdout; a failure is one JSON line with `code` on
stderr and exit 1, a usage error exits 64.

Call the CLI as `scripts/inspector.sh <command…>` (paths here are relative to this skill's
directory). It builds the CLI when the binary is missing or older than its sources, signs it so
Xcode keeps its approval, and passes the arguments through.

## Rules

- **State decides.** A step passes when its condition held in the state: `--until` or `wait`.
  Screenshot, hierarchy and logs are *diagnosis*: they explain a failure and never pass a step.
  An expectation only a screenshot could check is a missing registration: report the run as not
  checkable and add the value to the screen's registration (*Integrating*).
- **Every navigation and every gesture carries `--until '<match>'`** naming what the next screen
  has. Its answer is `{"settled","state","diff"}`; read the `diff`. A step that waits for the
  network (sign-in, a first sync, an upload) adds `--timeout 90`: the default is 3 s.
- **Turns are the cost, not calls.** Each of your turns costs 2–5 s, a call 0.1–2 s.
- **Write the whole route as code, then read only where it stopped.** After `init`, write every
  step of the task as one `&&` chain in a single Bash call, also across screens: names from the
  task are your targets, not something to look up first. Each step carries its `--until`; a
  control that appears a moment later (a dialog sliding in, a menu item) gets
  `tap --target <name> --find 3`. Send every step's answer to `>/dev/null` except the last: a
  failing step still prints its error, with every target in `detail`, and the chain stops there.
  Your next call fixes that one step and chains everything after it again. A route you know
  whole takes one call; aim for under five. Do not look before a step to check it will work, and
  do not look after it to check it worked: its `--until` and `--find` do both. A picker, a menu
  and its item, a system dialog and the screen after it go into the same call:

  ```sh
  scripts/inspector.sh tap --target Server --until '{"login":{}}' >/dev/null &&
    scripts/inspector.sh tap --target Staging --find 3 --until '{"login":{"server":"staging"}}' >/dev/null &&
    scripts/inspector.sh tap --target 'Sign in' --until '{"login":{}}' >/dev/null &&
    scripts/inspector.sh tap --target Continue --find 5 --until '{"login":{}}' --targets
  ```

  The first answer you read is the one at the end, or the error of the step that stopped.
- **Never `sleep`.** A wait is a condition: `--until` on the step, `wait '<match>' --timeout <s>`
  for something slow, `tap --target <name> --find <s>` for a control that appears outside the app
  (a system dialog). A gesture answers only after Xcode captured the screen again, so the next
  gesture in the same chain finds the new screen settled.
- **Tap a name before you look for it.** A control the task or an earlier answer names is tapped
  with `tap --target <name>` without a `capture` first: `--target` captures by itself, and a
  wrong name fails with `TARGET_NOT_FOUND` whose `detail` lists every target, which is your
  capture. Add `--targets` to a gesture to get the next screen's targets in its answer instead of
  a separate `capture`.
- **In-app activation beats a gesture.** When the catalog has `ui.tap`, `send ui.tap '"<name>"'
  --until …` activates the control with that identifier or label inside the app in about 0.1 s,
  where a gesture through Xcode takes 1–2 s. It reaches only the app's own controls: a system
  dialog, a web page or the keyboard needs a gesture, and a control it cannot activate answers
  `TARGET_NOT_FOUND`; then tap it.
- **A hit point you already have beats a name.** `tap <x> <y>` skips the capture `--target`
  makes; a state that publishes `hitPoints` gives you coordinates without any capture.
- **Write the script path out in every step.** No shell variables, loops or `$( )`: a host with
  an allow-list rejects the whole call.
- **A screen whose targets are empty** is drawn by another process (a web sign-in page). Read its
  screenshot once and take every point you need from that one image. Tap the field, then `type`
  the text with `\u{000A}` (Return) at its end, which submits the form, carrying the `--until` of
  the screen after it.
- **End the route at the first failed step.** A route that goes on types into whatever is still
  open and can save into real data. Diagnose, fix, then start again from the state.
- **Ask before an action or tap that writes real data** (sends a message, deletes an entry);
  navigating needs no question.

## The loop

1. **Start the app.** In the app's repository run `scripts/inspector.sh init`. It builds,
   installs and starts the app through Xcode in a new session, writes `.inspector/config.json`
   (which binds every later call to this app and simulator; an iOS app gets this worktree's own
   simulator, created once and kept, never one another session holds) and answers
   `{"config","hello","state"}`. Run it cold after every code change; with no change since the
   last run and the app still serving, `init --warm` only reads it. An app you cannot start
   (a Mac app, a physical device) needs no `init` for state and actions: `hello`, then `state`.
   Gestures exist only in the simulator, after `init`. Done when `init` answered with a state.
2. **Find where the app is.** The keys in that state are the screens alive now; a sheet left open
   by an earlier run shows up as its key. The route starts there. `catalog` lists the actions with
   their payload schema; state and catalog both grow as screens open.
3. **Plan the route**: a chain of steps from where the app is to the goal, each with the match
   that proves it arrived. Take each step's value from the state of the step before; an `int`
   payload is a row index or a domain id, as the action's name says. To leave a screen use its
   close action, an action higher up that rebuilds everything below it, or, for a sheet without a
   close action, `tap --target` on its close or cancel button. An action missing from the catalog
   lives on a screen not open yet; missing everywhere, the app needs a registration
   (*Integrating*, with the user's go-ahead).
4. **Navigate with actions**: `send <path> [json] --until '<match>'`, for example
   `send settings.open 2 --until '{"settings.detail":{"isLoading":false}}'`. An empty `{}` as a
   value asks only for the key.
5. **Gesture where the UI itself is under test**, or where no action reaches:
   `tap --target <name> --until …`, `swipe <x1> <y1> <x2> <y2> [s] --until …`,
   `type <text> --until …`. `type` writes at the cursor of the focused field: tap the field near
   its right end first so the cursor sits after its text, and clear text with `\u{0008}`
   (backspace) per character. `${NAME}` in a payload or typed text comes from `.inspector/.env`
   and prints masked.
6. **Answer from the state.** Read the values the task asks about from the last `diff` or
   `state`. A key containing a dot is read from the whole document: `state | jq '."a.b"'`. The run
   passes when every condition of the route held, the last one included.
7. **Diagnose only after a failure** (`EXPECTATION_FAILED`, a `hello` that finds no app, an
   `init` that fails), in this order: the last state in the error's `detail`
   (`jq -r .detail | jq`); `capture`'s `targets`; `scripts/logs.sh`, the app's errors since that
   step; the screenshot PNG at `capture`'s `screenshot` path, only when targets, state and logs
   leave the question open. The raw hierarchy file stays unread.
   `screenshot` is a copy at most 1000 pixels on its longest edge; `screenshotFull` (and
   `lastScreenshotFull` in `run.json`) is the full-resolution original for the human, never
   opened by you. A PNG from elsewhere (`xcrun simctl io <udid> screenshot`) goes through
   `scripts/screenshot.sh <png>` first; to compare several screens, read one
   `scripts/screenshot.sh --sheet <out.png> <png…>` instead of each PNG.
8. **Report** the route as the calls in order, the state values that answer the task, which
   conditions held, whether a screenshot was needed and which registration you added so the next
   run needs none, and what you could not reach.

```sh
scripts/inspector.sh send tabs.select settings --until '{"settings.list":{}}' &&
  scripts/inspector.sh send settings.open 2 --until '{"settings.detail":{"isLoading":false}}' &&
  scripts/inspector.sh tap --target Edit --until '{"settings.detail":{"isEditing":true}}' --targets
```

To wait without a gesture: `scripts/inspector.sh wait '<match>' --timeout <s>`. Only for a
condition a match cannot express (`>`, a regex): `scripts/wait-state.sh '<jq filter>' [seconds]`.

## Session

`init`'s Xcode session expires about two minutes after its last call; every gesture and capture
pushes that back. Nobody needs to end it: let it expire. An app that session started ends with it,
and the next gesture answers `NO_SESSION`, so `init` again. An app started outside a session (an
installed build after `xcrun simctl launch`) survives, and the CLI starts a new session for it by
itself. `scripts/inspector.sh end` ends the session and its app at once.

## Errors

Every `code` the CLI and the scripts emit has exactly one next step in `references/errors.md`.
Look the code up and take that step. A step marked **human** ends your run: report the code and
the step, without retrying.

## Integrating

The integration is one file, `DebugInspector.swift`, that registers every screen from the app's
root object and is the only caller of `serve()`, plus three marked touch points
(`// DEBUG INSPECTOR`): the dependency, one call in the app's entry point, the two `Info.plist`
keys. A repository keeps it in one of two modes:

- **Permanent**: committed behind `#if DEBUG`, left out of release builds with
  `EXCLUDED_SOURCE_FILE_NAMES`, `.inspector/` in `.gitignore`; the app's own docs name its release
  check (no InspectorKit symbol, no `NSBonjourServices`). The call line goes inside `#if DEBUG`
  too, because a release build without the file cannot resolve `DebugInspector`.
- **Ephemeral**: never committed. The file and an `.env` live in the store,
  `~/.claude/inspector/integrations/<repo>/<target path>/`. Run
  `scripts/integrate.sh <repo> --from ~/.claude/inspector/integrations/<repo>` (`--into <target
  path>` starts from the template), add the one marked call line, and before every pull request
  run `scripts/remove.sh <repo…>` and `scripts/remove.sh --check <repo…>`. Both scripts run
  without asking. A registration a loop needed goes into the store's copy too, so the next
  workspace starts with it.
- **The store's copy drifts**: it was written against another checkout, whose code or pinned
  package versions can have a type or case this one lacks. Pass `--check-build` with every
  `--from`: it builds the app scheme once (`--scheme`, `--workspace`, `--destination` when it
  cannot tell) and answers `INTEGRATION_STALE` with the failing `files` and unresolved `symbols`,
  the integration left in place. Adapt the repository's copy to this checkout, build, then copy
  it back to `detail.store`.

A screen's state mirrors what the screen shows, in the screen's unit: a value the app stores
scaled (a meter reading in thousandths) is registered as displayed, or its key names the unit.
Every sheet and pushed screen gets a close action. Details, rules and the template:
`references/integration.md`.

## Routes

A way you will take again (a sign-in, the path to the screen you debug) becomes a route: one call
plays it, where finding it took one turn per step. `scripts/inspector.sh` logs every call to
`.inspector/calls.jsonl`; after a run that reached the screen, `scripts/route.sh record` writes
its successful changing calls as a draft route, one call per line. Harden the draft once, then
`scripts/route.sh play <route> [--from n] [--to n]`; it stops at the first line that fails and
prints that line and its error, so you continue from there by hand.

Harden each line to the fastest call that is still sure:
- an app control: `send ui.tap '"<name>"' … || tap --target <name> …`, the gesture only as fallback;
- a control that appears a moment later: `tap --target <name> --find <s>`, never a coordinate;
- UI another process draws (system dialog, web page): `@retry <s>` with `@has <name>` or
  `@lacks <name>` on the answer's targets, e.g. `@retry 20 @lacks Continue tap --target Continue --find 20`;
- a slow step (network): `wait '<match>' --timeout 90` after it;
- drop the misses the recording kept (a tap that hit nothing, a scroll too many).

Keep a route beside the integration (`.inspector/routes/`) and name it after where it ends.

## Scripts

- `scripts/inspector.sh [--app name] <command…>`: the CLI, rebuilt when stale and signed
  (`INSPECTOR_REBUILD=1` forces a build).
- `scripts/route.sh record [<calls.jsonl>]` / `play <route> [--from n] [--to n]`: turns the
  logged calls into a route and plays one back (*Routes*).
- `scripts/wait-state.sh '<jq filter>' [seconds]`: polls `state` until the filter yields neither
  `null` nor `false`.
- `scripts/logs.sh [--all] [--since <seconds>]`: after a failed step, the app's error and fault
  log entries since that step.
- `scripts/screenshot.sh [--sheet <out.png>] <png…>`: the small copy of each PNG, beside it as
  `<name>-small.png`, or one contact sheet of all of them; either at most 1000 pixels on its
  longest edge. Read only what it answers as `screenshot` or `sheet`.
- `scripts/integrate.sh <repo> --from <store dir> | --into <target path> [--check-build]`: adds
  an ephemeral integration; `--check-build` then proves it compiles against this checkout.
- `scripts/remove.sh [<repo…>]`: takes it out again; `--check [--base <ref>]` exits 1 while
  anything of it is left.
- `scripts/add-to-package.sh <package dir> <target> [--ios-only] [--copy-template]`: adds
  InspectorKit to one package target, marked.

## References

| File | Read it |
|---|---|
| `references/cli.md` | Before a command you have not used yet: every command, its answer, `init`, conditions, `.inspector/`, several apps, logs |
| `references/errors.md` | On any error `code` |
| `references/integration.md` | Before touching an app's or a package's code |
| `assets/DebugInspector.swift` | The integration file's template |
