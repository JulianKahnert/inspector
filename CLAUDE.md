# CLAUDE.md

`inspector` lets an agent read the state of a running macOS or iOS app and steer it from the
command line. It is headed for `https://github.com/JulianKahnert/inspector`; the README is written
for that repo and holds every code example, so this file links there instead of repeating them.

## Targets

| Target | Kind | What it is |
|---|---|---|
| `InspectorKit` | library | `Inspector`, the protocol types, `InspectorCore` (internal), transports |
| `inspector` | executable | The CLI; talks to the app over `BonjourTransport` |
| `demo-host` | executable | A fake app on the Mac for manual checks |
| `InspectorKitTests` | tests | Swift Testing; in-process only, no sockets |

The module is `InspectorKit`, not `Inspector`: a module and a type with the same name break
qualified lookup.

## Commands

Run from the repo root.

```sh
swift build
swift test
swift run demo-host                     # terminal 1, keeps serving
swift run inspector apps                # terminal 2
swift run inspector hello
swift run inspector --app <name> hello
swift run inspector catalog
swift run inspector state [path]
swift run inspector send counter.set 42
```

Without a serving app the CLI fails with `APP_NOT_FOUND` after 5 seconds, an app that stops
answering ends in `TIMEOUT`, and with several apps serving it needs `--app`.
What each answer looks like is under [The CLI](README.md#the-cli).

## Driving a running app to debug it

Load the `inspector` skill (`.claude/skills/inspector/`) whenever a change has to be checked in a
running app. It owns the whole loop and its scripts: building the CLI, finding the serving app,
navigating, waiting for a screen's state, screenshots, and the error codes. Keep those details in
the skill and link to it from here, the same way the usage examples live only in the README.

## Usage examples

They live in the README. Link to them, do not copy them here.

- [Register state and actions](README.md#register-state-and-actions): registrations from a view
  model's or feature state's init, tokens kept and cancelled in `deinit`, what re-registering a key
  or path does.
- [Declare the payload schema](README.md#declare-the-payload-schema): how the JSON shape follows
  the closure's parameter type, and the explicit `schema:` for a Swift type wider than the
  accepted JSON.
- [Serve](README.md#serve): the `#if DEBUG` and `#available(iOS 26, *)` call, idempotence across a
  feature package and its host app, and the iOS `Info.plist` keys.

## Where things are

- [CODING_STANDARDS.md](CODING_STANDARDS.md): the architecture rule, what may be `public`, and the conventions, plus the shared standards linked from it. Read it before writing code.
