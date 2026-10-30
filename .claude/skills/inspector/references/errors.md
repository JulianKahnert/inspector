# Error codes and the next step

A failure is one JSON line on stderr, `{"code","message","detail"?}`, and exit code 1. Branch on
`code`; `message` and `detail` carry the specifics. Exit code 64 is a usage error: fix the call
after `scripts/inspector.sh help <command>` (or the script's `--help`).

Each row has one next step. **Agent** steps you take yourself. **Human** steps end the run:
report the code and the step, and leave the retry to the human, because repeating the call
changes nothing.

## Reaching the app

| `code` | Situation | Who | Next step |
|---|---|---|---|
| `APP_NOT_FOUND` | No `.inspector/` yet, or no debug build serves | Agent | `scripts/inspector.sh init` in the app's repository; an app it cannot start (Mac app, physical device): ask the user to start the debug build |
| `APP_NOT_FOUND` | Right after a cold `init` started the app, and the repository has no `DebugInspector.swift` | Agent | Integrate it ([SKILL.md, Integrating](../SKILL.md#integrating)), then cold `init` |
| `APP_NOT_FOUND` | Right after a cold `init` started the app, and the repository has a `DebugInspector.swift` | Agent | Check that the debug build calls `DebugInspector.start(root:)` and has both `Info.plist` keys (`references/integration.md`), then `scripts/logs.sh` |
| `APP_NOT_FOUND`, `TIMEOUT` | After `init --warm` | Agent | `init` without `--warm` |
| `APP_NOT_FOUND` | With `--app <name>` | Agent | `scripts/inspector.sh apps`, then the full `name` it lists |
| `AMBIGUOUS_APP` | Several apps serve, none picked | Agent | Repeat with `--app` and one full name from `detail` |
| `TIMEOUT` | `hello`, `state` or `send` found the app, which did not answer | Agent | Cold `init`: an app that was terminated leaves a Bonjour record behind for a while, which answers `TIMEOUT` instead of `APP_NOT_FOUND` |
| `TIMEOUT` | Again right after a cold `init` | Human | The app sits at a breakpoint: continue it in Xcode's debugger |
| `TIMEOUT` | From a command through Xcode: the bridge or a tool did not answer | Agent | `pgrep -x Xcode`; when Xcode is not running, `init` starts it |
| `TIMEOUT` | From `init`: Xcode did not open the workspace within 90 s | Agent | `init` again; a starting Xcode can take a minute |

## State and actions

| `code` | Situation | Who | Next step |
|---|---|---|---|
| `UNKNOWN_ACTION_PATH` | No action at that path; `didYouMean` lists the closest | Agent | Take a suggestion, or open the screen that registers the action first |
| `UNKNOWN_STATE_PATH` | `state <path>` selects nothing | Agent | Navigate to the screen first; for a top-level key with a dot, `state \| jq '."a.b"'` |
| `PAYLOAD_TYPE_MISMATCH` | Payload missing, extra or of the wrong type | Agent | Match the schema in `catalog` |
| `BAD_REQUEST` | The app's action threw; `message` and `detail` carry its error | Agent | A failed step: diagnose it (SKILL.md, step 7) |
| `BAD_REQUEST` | `Invalid argument` for `wait` | Agent | The app links an InspectorKit without conditions: update its InspectorKit package, then cold `init` |
| `EXPECTATION_FAILED` | A condition did not hold before its timeout; `detail` is the last state as a JSON string | Agent | End the route and diagnose: `jq -r .detail \| jq`, then `capture`, then `scripts/logs.sh` |
| `EXPECTATION_FAILED` | `message` says the app answered before the match held | Agent | The app links an InspectorKit without conditions: update its InspectorKit package, then cold `init` |
| `TIMEOUT` | From `wait-state.sh`: the filter stayed `null` or `false` until the limit | Agent | Diagnose as for `EXPECTATION_FAILED`, from `scripts/inspector.sh state` |
| `ENV_MISSING` | A `${NAME}` has no value in `.inspector/.env`; nothing was sent; `detail` lists the names | Agent | Copy the line from the store's `.env` (`~/.claude/inspector/integrations/<repo>/…/.env`) into `.inspector/.env`; a name the store lacks too comes from the human |

## The `.inspector/` folder and the session

| `code` | Situation | Who | Next step |
|---|---|---|---|
| `NO_CONFIG` | No `.inspector/` from here up to the repository root, `INSPECTOR_DIR` names nothing, or (from `logs.sh`) `config.json` lacks `udid` or `logSubsystem`; `detail` is the path expected | Agent | Cold `scripts/inspector.sh init` in the app's repository, or fix `INSPECTOR_DIR` |
| `NO_SESSION` | `config.json` names no session, the session expired and its app with it, or a gesture with `--until` found its app not answering | Agent | Cold `init` |
| `BAD_REQUEST` | From `logs.sh`: no `lastStep` in `run.json` | Agent | `scripts/logs.sh --since <seconds>` |
| `BAD_REQUEST` | From `logs.sh`: `log show` failed; `detail` is simctl's message | Agent | Cold `init` (the simulator in `config.json` is shut down or gone) |

## Xcode, gestures and capture

| `code` | Situation | Who | Next step |
|---|---|---|---|
| `NOT_APPROVED` | Xcode has not approved this binary | Human | Confirm Xcode's dialog that approves `de.juliankahnert.inspector` (it opens on `init`), then `init` again |
| `NO_SIGNING_IDENTITY` | From `inspector.sh`: no "Apple Development" identity to sign with | Human | Add one in Xcode > Settings > Accounts |
| `XCODE_TOO_OLD` | The selected Xcode has no `mcpbridge` | Human | Select Xcode 27.2 or newer (`xcode-select`) |
| `BAD_REQUEST` | From `init`: the repository has no workspace or project, or several | Agent | `init --workspace <path>` |
| `XCODE_ERROR` | `init`'s build failed; `message` quotes the build output | Agent | Fix the code, cold `init` |
| `XCODE_ERROR` | The device is in a session that `config.json` names (your earlier run) | Agent | `scripts/inspector.sh end`, then cold `init` |
| `XCODE_ERROR` | The device is in a session `config.json` does not name (another agent, another workspace) | Human | End that session or free the simulator |
| `XCODE_ERROR` | Xcode says the agent or client is not approved or allowed | Human | As for `NOT_APPROVED` |
| `XCODE_ERROR` | `Session with that key doesn't exist` while `init` installs | Agent | Cold `init` once more |
| `XCODE_ERROR` | Anything else; `detail` is Xcode's text | Agent | Take the step Xcode's text names; none named: report the text |
| `NO_HIERARCHY` | A capture came back without a hierarchy; `detail` is Xcode's answer | Agent | `capture` again; still none: read the screenshot at the path in `detail` |
| `TARGET_NOT_FOUND` | No target has that identifier or label; `detail` lists every target | Agent | Name one from `detail`; a control with neither identifier nor label: tap its `hitPoint` coordinates |
| `TARGET_AMBIGUOUS` | Targets at several points have it; `detail` lists them | Agent | Name the identifier, or tap the right one's `hitPoint` coordinates |
| `BUILD_FAILED` | From `inspector.sh`: the inspector checkout does not build; the compiler output precedes the line, `detail` is the checkout | Agent | Your own change in that checkout: fix it. Otherwise report it as **human**: the inspector checkout is mid-change |

## Integration scripts

`integrate.sh` and `remove.sh` answer like the CLI. `add-to-package.sh` prints plain text on
stderr, exits 1 on failure with the manifest restored, and 2 on a usage error.

| `code` | Who | Next step |
|---|---|---|
| `ALREADY_INTEGRATED` | Agent | `scripts/remove.sh <repo>` first |
| `STORE_INVALID` | Agent | Keep exactly one `DebugInspector.swift` below the store folder, at its target path |
| `TARGET_DIR_MISSING`, `TARGET_UNKNOWN` | Agent | Fix the store's path, or pass `--package-target` |
| `NEEDS_PROJECT_DEPENDENCY` | Agent, else human | Pass `--package <local wrapper package> --package-target <name>`; without such a package a human adds it in Xcode (File > Add Package Dependencies > Add Local, product InspectorKit), then `integrate.sh` again |
| `DEPENDENCY_FAILED` | Agent | `detail` has `add-to-package.sh`'s output; a target written on one line needs its arguments on separate lines |
| `PACKAGE_NOT_FOUND`, `PLIST_NOT_FOUND` | Agent | Fix the path |
| `PLIST_INVALID` | Agent | `plutil -convert xml1 <plist>`, then `integrate.sh` again |
| `INTEGRATION_LEFT` | Agent | `scripts/remove.sh`; a `diff` or `tracked` finding in a commit: change that commit |
| `INTEGRATION_LEFT` with a `resolved` finding: a build or `swift run` added InspectorKit's pins to a `Package.resolved` | Agent | `scripts/remove.sh`, which puts the file back as it was; never commit the pins |
| `INTEGRATION_LEFT` with a `deleted` finding: a tracked file is gone but not `git rm`ed | Agent | `git restore <path>`; only a deletion the task asked for: `git rm <path>` |
| `BASE_NOT_FOUND` | Agent | `--base <branch>` |
| `NOT_A_REPO`, `NOT_AN_APP_REPO` | Agent | Pass an app's checkout, not a plain folder or the inspector repository |
