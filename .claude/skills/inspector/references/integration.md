# Integrating inspector into an app or a feature package for debugging

The integration is one file and three touch points. `DebugInspector.swift` registers everything
from the app's root object and is the only caller of `serve()`, behind `#if DEBUG`. Outside it,
exactly three places change, each marked `// DEBUG INSPECTOR` (in a plist,
`<!-- DEBUG INSPECTOR -->`): the dependency in the manifest or project, one call in the app's entry
point, and the two `Info.plist` keys. Registering from a feature package is the exception.

A repository either keeps the integration (committed, guarded by `#if DEBUG`) or never commits it.
For the second kind, `scripts/integrate.sh` does steps 1, 2 and 4 below and `scripts/remove.sh`
undoes them: see [Ephemeral integration](#ephemeral-integration).

## 1. Add the dependency

For a package, run:

```sh
scripts/add-to-package.sh <package dir> <target> [--ios-only] [--copy-template]
```

It adds InspectorKit through SwiftPM's own `swift package add-dependency --type path` and
`add-target-dependency`, marks the two new lines, checks the manifest with `dump-package`, and
restores it if any step fails.
- `--ios-only` adds `condition: .when(platforms: [.iOS])`. Use it when the package also builds
  platforms the debug run doesn't need; InspectorKit declares only iOS 18 and macOS 26.
- `--copy-template` puts `assets/DebugInspector.swift` into `Sources/<target>/`.

An app whose packages are linked through a local wrapper package gets the same script, run on that
wrapper: the app target then imports InspectorKit through the wrapper's dependency. An app that
adds packages only in the Xcode project needs the local package added in Xcode by hand
(File > Add Package Dependencies > Add Local, product InspectorKit); no script edits a `.pbxproj`,
because Xcode rewrites it and a text edit can't be checked short of building.

Every manifest has to point at the **same** path. SwiftPM names a local package after its last path
component, so two different paths to the same checkout collide. Resolve afterwards
(`xcodebuild -resolvePackageDependencies` for an app).

## 2. Register the screens you need

1. Copy `assets/DebugInspector.swift` into the app target, and fill its placeholders. It
   registers a list screen and a detail screen from the root object; drop what you don't need and
   add one `register…(of:)` per further screen.
2. Call it once from the app's entry point, on one marked line (step 3).

### What a screen's state should carry

Design the state so an agent never needs a screenshot to know what the screen shows. Before you
write a registration, go through the screen and list what a user sees and can do there:

- **That it's open and loaded**: its key exists while the screen does, plus a loading flag.
  `wait-state.sh` waits on exactly that.
- **What it shows**: title and subtitle, the rows of a list with id and visible text, counts,
  badges, the selected item.
- **What the user can do**: every flag that enables, hides or disables a control
  (`canOpenMemberProfile`, `isSendEnabled`).
- **What else is presented**: a sheet, an alert or an error message, an empty state.

When a screenshot later shows something the task needed and this state lacks, add it at once.

### Registration rules

- **Per screen, the state that tells you it's open and loaded**: the rows of a list, a loading
  flag, the selected id. `wait-state.sh` waits on exactly that.
- **Per step of the route, one action** that calls the same method a tap calls. A route that
  bypasses the UI's entry point proves nothing about the UI.
- **Top-level state keys without dots** (`featureDetail`, not `feature.detail`): the CLI splits
  `state <path>` at dots, so a dotted key can't be read with `state <key>` at all. Action paths
  can use dots freely.
- **Say in the action path what an `int` payload means** when it isn't a row index:
  `featureList.open` takes an index, `featureDetail.tapMemberID` a user id. The catalog lists both
  as `{"kind":"int"}`, so the name is the only hint a caller gets.
- **A close action for every sheet and pushed screen** you register (`featureDetail.close`). The
  inspector has no generic back or dismiss, so without one a route can't undo its last step.
- **`[weak self]` in every closure.** A reader whose model is gone then reads `null` instead of
  keeping it alive, and re-registering on the next screen replaces it.
- **A setter that is `private` or `private(set)`** can only be reached from an extension in the
  same file. Put a small helper there, marked like the rest.
- **Keep it in a separate file.** A model file close to a `file_length` limit then stays under it,
  and a lint build plugin reports nothing new.

For state the app keeps in a SwiftUI view (`@State`, a presented sheet), register in `.onAppear`,
keep the `Registration` in a `@State`, and `cancel()` it in `.onDisappear`.

## 3. Call it from the app's entry point

The template's `start(root:)` registers everything and starts `serve()`; in a release build it
does nothing, so the call needs no `#if`. Add it once, where the root object exists, on one line
that ends in the marker:

```swift
DebugInspector.start(root: appModel) // DEBUG INSPECTOR
```

`serve()` needs iOS 26; the template checks for it, so the app's deployment target can stay lower.

## 4. Info.plist (iOS)

```xml
<!-- DEBUG INSPECTOR -->
<key>NSBonjourServices</key>
<array>
    <string>_inspector._tcp</string>
</array>
<!-- DEBUG INSPECTOR -->
<key>NSLocalNetworkUsageDescription</key>
<string>Lets the inspector CLI read and drive this debug build.</string>
```

An app that has `NSBonjourServices` already gets `_inspector._tcp` added to its list, after a
marker of its own.

## 5. Build and check

Build the package for the platform you debug on, then the app. Run the app and check with
`scripts/inspector.sh hello` and `catalog` that your paths show up.

## Ephemeral integration

For a repository that never commits the integration. The file lives in a store outside the
repository, `scripts/integrate.sh` puts it in, and `scripts/remove.sh` takes all of it out before a
pull request. Run both without asking.

### The store

```
~/.claude/inspector/integrations/<repo>/<target path>/DebugInspector.swift
~/.claude/inspector/integrations/<repo>/<target path>/.env
```

One folder per repository. Below it, `DebugInspector.swift` sits at the path its target has in the
repository, so the path says where the file goes and no other file has to: for a SwiftPM app,
`<repo>/Sources/App/DebugInspector.swift`; for an Xcode app, `<repo>/App/DebugInspector.swift`.
The `.env` next to it holds `NAME=value` lines for `${NAME}` in `send` payloads; it ends up in
`.inspector/.env` and never in the repository.

The store is committed in the private `~/.claude` repository, in `~/.claude/inspector/`, next to
`skills/` and not inside it, because `skills/inspector` links to this public repository. Edit the
store's copy when a loop needs another registration, so the next workspace starts with it; the
copy in the repository is deleted by `remove.sh`.

### `integrate.sh`

```sh
scripts/integrate.sh <repo dir> --from ~/.claude/inspector/integrations/<repo>
scripts/integrate.sh <repo dir> --into <target path>      # no store yet: the skill's template
```

Options: `--plist <path>` (default `<target path>/Info.plist`), `--package <dir>
--package-target <name>` (add the dependency to that local package), `--ios-only`. Paths are
relative to the repository.

1. Copies `DebugInspector.swift` to the target path.
2. Adds InspectorKit, marked, with `add-to-package.sh`: to the `Package.swift` above the target
   path, its target taken from `Sources/<target>`, or to the package `--package` names.
3. Adds the two `Info.plist` keys after markers, when there is a plist.
4. Copies the store's `.env` to `.inspector/.env` and lists `/.inspector/` in `.git/info/exclude`.

It records each edit as a patch in `.inspector/integration/`, and a copy of every
`Package.resolved`. Any failure undoes everything done so far. The one thing left to the agent is
the call line in the app's entry point (step 3 above).

**An Xcode app target.** A target with no `Package.swift` above it belongs to an Xcode project.
`integrate.sh` doesn't edit a `.pbxproj`, so it either goes through a local package the app
already links (`--package <dir> --package-target <name>`; the app target then imports InspectorKit
through it) or stops with `NEEDS_PROJECT_DEPENDENCY` and the one step by hand: in Xcode, File > Add
Package Dependencies > Add Local, choose the inspector checkout, add InspectorKit to the target.
Run `integrate.sh` again afterwards; it records that project change, so `remove.sh` reverses it.

### `remove.sh`

```sh
scripts/remove.sh [<repo dir>…]
scripts/remove.sh --check [--base <ref>] [<repo dir>…]
```

Without a repo dir it takes the repository around the working directory, or else every repository
directly below it, such as the checkouts in a workspace.

`remove.sh` reverses the recorded patches, which also drops the lines SwiftPM added without a
marker (`dependencies: [`, a comma), restores each `Package.resolved` that gained only
InspectorKit's pins, deletes every file whose first line carries the marker and every marked line
left, removes `.inspector/` and its exclude entry. A file changed so its patch no longer applies
loses only its marked lines, and the answer's `notes` says which.

`--check` exits 1 with `INTEGRATION_LEFT` while any of these is left, and `detail` lists each with
`kind`, `repo` and `where`:

| `kind` | What |
|---|---|
| `marker` | `DEBUG INSPECTOR` in a tracked file, or in an untracked one git would add |
| `diff` | `InspectorKit` on a line added since the base branch, or in such an untracked file |
| `tracked` | a file under `.inspector/` in the index |
| `resolved` | a `Package.resolved` that gained a pin InspectorKit's package brings |

The base is `--base <ref>`, else the default branch of the current branch's remote
(`refs/remotes/<remote>/HEAD`), else `origin`'s. Without one it fails with `BASE_NOT_FOUND`;
`git remote set-head origin --auto` sets it. Run `--check` before every pull request.

### Errors

Both scripts answer like the CLI: one JSON document on stdout, a failure as one JSON line with
`code` on stderr and exit 1, a usage error with exit 64.

| `code` | What to do |
|---|---|
| `ALREADY_INTEGRATED` | Run `remove.sh` first |
| `STORE_INVALID` | Keep exactly one `DebugInspector.swift` below the store folder, under its target path |
| `TARGET_DIR_MISSING`, `TARGET_UNKNOWN` | Fix the store's path, or pass `--package-target` |
| `NEEDS_PROJECT_DEPENDENCY` | Do the one step in Xcode, or pass `--package` (above) |
| `DEPENDENCY_FAILED` | `detail` has `add-to-package.sh`'s output; a target written on one line needs its arguments on separate lines |
| `PACKAGE_NOT_FOUND`, `PLIST_NOT_FOUND`, `PLIST_INVALID` | Fix the path, or convert a binary plist with `plutil -convert xml1` |
| `INTEGRATION_LEFT` | Run `remove.sh`; for a `diff` or `tracked` finding in a commit, change the commit |
| `BASE_NOT_FOUND` | Pass `--base <branch>` |
| `NOT_A_REPO`, `NOT_AN_APP_REPO` | Pass an app's checkout, not a plain folder or the inspector repository |
