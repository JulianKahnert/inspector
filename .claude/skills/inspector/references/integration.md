# Integrating inspector into an app or a feature package for debugging

Mark every added line with `// DEBUG INSPECTOR` (in a plist, `<!-- DEBUG INSPECTOR -->`), so
`scripts/find-debug-markers.sh` finds all of it when the integration comes out again.

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
wrapper. An app that adds packages only in the Xcode project needs the local package added in
Xcode by hand; the script can't edit a `.pbxproj`.

Every manifest has to point at the **same** path. SwiftPM names a local package after its last path
component, so two different paths to the same checkout collide. Resolve afterwards
(`xcodebuild -resolvePackageDependencies` for an app).

## 2. Register the screens you need

1. Copy `assets/DebugInspector.swift` into the target that owns the models, and fill its
   placeholders. Drop the extensions you don't need; copy one per further screen.
2. Call `registerInspector()` at the end of each model's init, wrapped in
   `#if canImport(InspectorKit)` (the snippet is in the template's header).

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

## 3. Serve from the app

In the app's startup, once:

```swift
#if DEBUG // DEBUG INSPECTOR
if #available(iOS 26, *) { // DEBUG INSPECTOR
    Task { // DEBUG INSPECTOR
        do { // DEBUG INSPECTOR
            try await Inspector.shared.serve() // DEBUG INSPECTOR
        } catch { // DEBUG INSPECTOR
            <#log the error with the app's logger#> // DEBUG INSPECTOR
        } // DEBUG INSPECTOR
    } // DEBUG INSPECTOR
} // DEBUG INSPECTOR
#endif // DEBUG INSPECTOR
```

The availability check is needed while the app's deployment target is below iOS 26.

## 4. Info.plist (iOS)

```xml
<!-- DEBUG INSPECTOR -->
<key>NSBonjourServices</key>
<array>
    <string>_inspector._tcp</string>
</array>
<!-- DEBUG INSPECTOR -->
<key>NSLocalNetworkUsageDescription</key>
<string>DEBUG INSPECTOR: lets the inspector CLI read and drive this debug build.</string>
```

## 5. Build and check

Build the package for the platform you debug on, then the app. Run the app and check with
`scripts/inspector.sh hello` and `catalog` that your paths show up.

## Removing it again

Run `scripts/find-debug-markers.sh <app dir> <package dir>`. Delete the files it lists first, then
remove the marked lines, revert the plist keys, and resolve packages again. SwiftPM added a comma
to the line before each manifest entry; the trailing comma it leaves behind is valid Swift. Once
the script finds no markers and both builds pass, the integration is gone.
