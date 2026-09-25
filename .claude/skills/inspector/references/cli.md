# inspector CLI reference

Every command prints one JSON document on stdout, with keys sorted. A rejection is one JSON line on
stderr and exit code 1; branch on `code`, never on `message`. A usage error exits with 64.

`scripts/inspector.sh` takes the same arguments and builds the CLI when it is missing. The CLI
bounds every call itself: discovery gives up after 5 s with `APP_NOT_FOUND`, and an app that stops
answering ends in `TIMEOUT` after 5 s, or after a `send`'s settle timeout plus 5 s.

## Commands

| Command | Answer |
|---|---|
| `hello` | `{"app","pid","provider"}`: which process answered |
| `catalog` | `{"actions":[{"path","payload"?}]}`. `payload` is the schema; it is missing for an action that takes none |
| `state` | The whole state document: every registered key with its current value |
| `state <path>` | The value at a dotted path inside the state document |
| `send <path>` | Runs an action that takes no payload |
| `send <path> <json>` | Runs an action with a payload |

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
  `diff` can be empty although the screen opens. Wait for the screen's key with
  `scripts/wait-state.sh` instead.
- The app side gives an action 5 seconds by default.

## Payload schemas in the catalog

`{"kind": …}` with one of: `bool`, `int`, `double`, `string`, `url`, `uuid`, `date` (ISO 8601
string), `optional` (`of`), `array` (`of`), `enum` (`values`: pass one of them as a string),
`rawValue` (`raw`), `decodable` (`type`: JSON for a `Codable` Swift type), `tuple` (`fields`,
`input`: object or array), `opaque` (`type`).

## Error codes

| `code` | Meaning | What to do |
|---|---|---|
| `UNKNOWN_ACTION_PATH` | No action at that path. `didYouMean` lists the closest registered paths | Take a suggestion, or open the screen that registers it first |
| `UNKNOWN_STATE_PATH` | The path selects nothing | The screen isn't open yet, or the key contains a dot (see above) |
| `PAYLOAD_TYPE_MISMATCH` | Missing, extra or undecodable payload | Match the schema from `catalog` |
| `BAD_REQUEST` | Anything else, including an error the app's action threw | Read `message` and `detail` |
| `APP_NOT_FOUND` | No serving app within 5 s, or none matches `--app` | Check that a debug build is running and serving, and the name in `inspector apps` |
| `AMBIGUOUS_APP` | Several apps serve and no `--app` picks one. `detail` lists their instance names | Repeat the call with `--app <name>` |
| `TIMEOUT` | The app was found but did not answer in time | Check that the app is still running and not stopped in the debugger |

## Several apps

`scripts/inspector.sh apps` lists every serving app as one JSON array, each checked with `hello`:
its instance `name`, `live`, and for a live one `app`, `pid` and `provider`. With more than one
serving, every other command fails with `AMBIGUOUS_APP` until `--app <name>` picks one, for example
`scripts/inspector.sh --app "$(scripts/inspector.sh apps | jq -r '.[0].name')" state`. Apps
advertise as `<app> @ <device>`, so `--app DemoHost` is enough while only one DemoHost serves. A
second instance of the same app on the same device gets a Bonjour suffix such as `(2)`.

## Screenshots

`scripts/screenshot.sh [file.png] [UDID]` captures the booted iOS simulator at full device
resolution through `xcrun simctl io <device> screenshot`. With several simulators booted it lists
them and asks for a UDID. It can't capture a physical device or a Mac app.
