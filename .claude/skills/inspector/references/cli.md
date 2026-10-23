# inspector CLI reference

Every command prints one JSON document on stdout, with keys sorted. A rejection is one JSON line on
stderr and exit code 1; branch on `code` (every code and its next step: `errors.md`). A usage
error exits with 64.

`scripts/inspector.sh` takes the same arguments. It runs the CLI of the inspector checkout the
skill lives in, also through a symlink such as `~/.claude/skills/inspector`, builds it when the
binary is missing or older than anything in `Sources/`, `Package.swift` or `Package.resolved`, and
signs it after every build, so Xcode keeps serving it (a bare `swift build` leaves a signature
Xcode refuses; the script signs that again on its next call). A fresh call adds a few
milliseconds; a rebuild costs the build.

The CLI bounds every call itself: discovery gives up after 5 s with `APP_NOT_FOUND`, and an app
that stops answering ends in `TIMEOUT` after 5 s, or after a `send`'s settle timeout plus 5 s; a
condition's timeout (`--timeout`, 3 s by default) is added on top, so the CLI never gives up
before the app.

## Commands

| Command | Answer |
|---|---|
| `hello` | `{"app","instance","pid","provider"}`: which process answered, and the full instance name it was reached under |
| `catalog` | `{"actions":[{"path","payload"?}]}`. `payload` is the schema; it is missing for an action that takes none |
| `state` | The whole state document: every registered key with its current value |
| `state <path>` | The value at a dotted path inside the state document |
| `send <path>` | Runs an action that takes no payload |
| `send <path> <json>` | Runs an action with a payload |
| `send <path> [json] --until <match> [--timeout s]` | Runs the action, then answers once the state contains the match |
| `wait <match> [--timeout s]` | The whole state document, once it contains the match |
| `init [--warm] [--reset] [--workspace path]` | `{"config","hello","state"}`: builds, installs and starts the app through Xcode, writes `.inspector/config.json` and reads the first observation (see *Init* below) |
| `capture` | `{"screenshot","hierarchy","targets"}`: captures the simulator's screen in the session in `.inspector/config.json`. `targets` lists the controls as `{type, identifier?, label?, placeholder?, value?, hitPoint: [x, y]}`; `value` holds a field's typed text. Find a tap point with `jq '.targets[] \| select(.label == "Sichern")'` |
| `tap <x> <y>`, `tap --target <name>` | `{"gesture","target"?}`: taps a point, or the `hitPoint` of the one target whose identifier or label is the name (`TARGET_NOT_FOUND` / `TARGET_AMBIGUOUS` list the targets in `detail`). Simulator only |
| `swipe <x1> <y1> <x2> <y2> [s]` | `{"gesture"}`: drags from one point to the other. Simulator only |
| `type <text>` | `{"gesture"}`: types into the focused field, after its text; `${NAME}` comes from `.inspector/.env`, `\u{0008}` is backspace. Simulator only |
| `tap`, `swipe`, `type` … `--until <match> [--timeout s]` | Like `send --until`: the diff against the state before the gesture. Wait about 1 s after opening a sheet before a gesture on it; one during the slide-in animation is lost |
| `end` | `{"session","xcode"}`: ends the Xcode session in `.inspector/config.json`; the app that session started ends with it. `xcode` is Xcode's answer, `{"userMessage":"Session doesn't exist anymore"}` for a session that already ended |

## Init

Run `scripts/inspector.sh init` from the app's repository. It ends once `state` answered, and its answer carries that whole state.

- **Cold** (the default; after every code change): starts Xcode with `xed -b` when it is not running, opens the repository's workspace, ends the session the old `config.json` names, starts a new one, builds, installs and starts the app with the active scheme, then reads `hello` and `state`. It takes the build time plus a few seconds; with the build up to date about 11 s.
- **Warm** (`--warm`; you decide that no code changed since the last run): only `hello` and `state` of the app that serves, well under a second, no build, the session untouched. It finds only an app that runs outside a session, for example after `xcrun simctl launch <udid> <bundleId>` of the installed build, because the app of an expired session is gone.
- **`--reset`** uninstalls the app before the install, which deletes its data. Use it only when the task needs a fresh app; init never logs in.
- **`--app <name>`** picks the app when several serve, and the scheme to build when the workspace has a scheme of that name. **`--workspace <path>`** picks the workspace when the repository has several.
- `config.json` gets every field, `instance` being the full name `hello` reported and `logSubsystem` the bundle ID's vendor prefix (`de.juliankahnert.`), so `logs.sh` covers the app's packages too; `.inspector/` goes into `.git/info/exclude` when nothing ignores it yet.
- The first `init` on a machine opens Xcode's approval dialog for the CLI; until a human confirms it, `init` ends in `NOT_APPROVED`.

### Without Xcode

When Xcode cannot run the build, build and start the app yourself. This path has no session, so no gestures and no `end`:

```sh
xcodebuild -project App/RoommateAlbert.xcodeproj -scheme RoommateAlbert \
  -destination "id=$UDID" -derivedDataPath "${TMPDIR}inspector-build" build
xcrun simctl install "$UDID" "${TMPDIR}inspector-build/Build/Products/Debug-iphonesimulator/RoommateAlbert.app"
xcrun simctl launch "$UDID" de.juliankahnert.RoommateAlbert
scripts/inspector.sh init --warm --app RoommateAlbert
```

Take the project, scheme and app name from the repository, and the bundle ID from `xcodebuild -showBuildSettings`. `init --warm` then binds the calls to the app; `logs.sh` needs `udid` and `logSubsystem` in `config.json`, which only a cold init writes.

## `state` and paths

- A key is present only while something registered it. A screen registers when its model is
  created, so the document grows and shrinks as you navigate. A reader whose owner is gone reads
  `null`.
- `state <path>` splits the path at every dot, so `state a.b` looks for `a` → `b`. A top-level key
  that itself contains a dot (`"chat.draft"`) is unreachable that way (`UNKNOWN_STATE_PATH`). Read
  the whole document and filter it: `jq '."chat.draft"'`.

## `send`

- The payload argument is parsed as JSON. Anything that doesn't parse is sent as a string, so
  `send x.set 42` sends an integer, `send x.set '"42"'` a string, and `send x.set abc` the string
  `"abc"`.
- The answer is `{"settled","state","diff"}`:
  - `diff` lists `{"path","old","new"}` between the state before the action and the state right
    after its closure returned.
  - `state` is that after-state.
- An action that starts a push or presents a sheet returns before the new screen exists, so its
  `diff` can be empty although the screen opens. Name the screen's key instead:
  `send settings.open --until '{"settings.detail":{}}'` answers once it registered, with the diff
  against the state before the action.
- The app side gives an action 5 seconds by default.
- `${NAME}` in the payload is filled from `.inspector/.env` (see below), for example
  `send session.login '{"user":"${USER}","password":"${SECRET}"}'`. The answer, an error and
  `run.json` show each filled-in value as `${NAME}`, a number equal to one as the string `"${NAME}"`.

## Conditions: `wait` and `--until`

The match is a JSON object the state has to contain: `{}` as a value asks only for the key, an
array matches as a prefix, a scalar exactly (`1` matches `1.0`), and keys are taken as written
(`"settings.detail"` is one key). No operators; for `>` or a regex use `scripts/wait-state.sh` with a
`jq` filter. The app checks the match itself, right after the action, on every registration and
every 25 ms, so `--until` costs no extra round trips.

## Payload schemas in the catalog

`{"kind": …}` with one of: `bool`, `int`, `double`, `string`, `url`, `uuid`, `date` (ISO 8601
string), `optional` (`of`), `array` (`of`), `enum` (`values`: pass one of them as a string),
`rawValue` (`raw`), `decodable` (`type`: JSON for a `Codable` Swift type), `tuple` (`fields`,
`input`: object or array), `opaque` (`type`).

## Several apps

`scripts/inspector.sh apps` lists every serving app as one JSON array, each checked with `hello`:
its instance `name`, `live`, and for a live one `app`, `pid` and `provider`. With more than one
serving, every other command fails with `AMBIGUOUS_APP` until `--app <name>` picks one, for example
`scripts/inspector.sh --app "$(scripts/inspector.sh apps | jq -r '.[0].name')" state`. Apps
advertise as `<app> @ <device>`, so `--app DemoHost` is enough while only one DemoHost serves. A
second instance of the same app on the same device gets a Bonjour suffix such as `(2)`. A full
instance name (`name` from `apps`, `instance` from `hello`) connects at once; the `<app>` part
waits about 500 ms for a second match, so pass the full name to every call in a loop.

## `.inspector/`

A folder in the app's repository root that binds separate calls to one app. Every command but
`apps` looks for it from the working directory up to the repository root; `INSPECTOR_DIR=<path>`
names it for one call instead. Without it, the commands work as before.

- `config.json`: `instance` (the full instance name) is the default for `--app`; `--app` wins.
- `run.json`: `lastStep` is the last call, `{"arguments","at","command"}`, `at` being its start.
- `.env`: `NAME=value` lines for `${NAME}` in a `send` payload or `type` text. Never in git, never
  printed.

## Capture, targets and screenshots

Diagnosis only, after a failed step. `capture` answers the paths Xcode wrote and the `targets`
on the screen; every gesture also leaves its `lastScreenshot` and `lastHierarchy` in
`.inspector/run.json`. Read `targets` (about 1 KB) to find a control or a typed value; open the
PNG at `screenshot` only when targets, state and logs leave the question open; leave the
hierarchy file (5 to 25 KB of text) unread. All of it exists only in the simulator, after `init`.

## Logs

Logs explain a failure; they never decide whether a step passed. Read them only after a step
failed: a condition that did not hold, a `hello` that finds no app, or an app that would not
start.

`scripts/logs.sh [--all] [--since <seconds>]` prints the app's log entries since the last step,
straight from the simulator's unified log through `xcrun simctl spawn <udid> log show`. It needs no
Xcode session, so it also works after `simctl launch`.

- **What it reads**: `udid` and `logSubsystem` from `.inspector/config.json`, found the same way
  the CLI finds the folder (`INSPECTOR_DIR` included). `com.example.app` takes that subsystem and
  every one below it; a value ending in a dot (`com.example.`) is a prefix.
- **Window**: from `lastStep.at` in `.inspector/run.json`, the start of the last call.
  `--since <seconds>` takes the last seconds instead.
- **Severity**: `error` and `fault`; `--all` adds every other level, `info` and `debug` included.
- **Output**: `log show --style compact`: a header line, then one line per entry with timestamp,
  type (`E`, `F`, …), process, `[subsystem:category]` and the message. The header alone means
  the app logged no error since the step; `--all` then shows what it did log.
- **Errors**: one JSON line on stderr and exit 1, like the CLI. `NO_CONFIG` for a missing folder or
  a config without `udid` or `logSubsystem` (`detail` is the expected path); `BAD_REQUEST` for no
  `lastStep` (pass `--since`), or when `log show` fails, for example on a shut-down simulator
  (`detail` is simctl's message). A usage error exits with 64.

**Alternative: `GetConsoleOutput`** from Xcode's MCP tools, with `oslogSeverity`, a regex
`pattern` and `tailLimit`. Use it only in two cases: the Xcode launch session that started the app
is still alive, or the app runs on a physical device, where `simctl` can't reach.
