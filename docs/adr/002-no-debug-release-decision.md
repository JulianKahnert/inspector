# inspector leaves the debug-or-release decision to the app, and recommends debug only

`InspectorKit` contains no `#if DEBUG`. Registering state and actions and calling `serve()` work the same in every build configuration, and whether a release build carries inspector is the app's decision. The recommendation is to use it in debug builds only, with the app guarding its own call sites. Opt-in helpers that do nothing when the package is compiled without `DEBUG` are a possible later addition.

## The core stays neutral

A debug-only rule inside the core would decide for every app, including one that ships inspector on purpose in an internal build. So the core does not decide. The `#if DEBUG` around `serve()` in the README and in the `Inspector` doc comment is an example the app copies, not a check the package runs.

## The recommendation: debug builds only

A serving app is open to anyone on the local network ([ADR 001](001-connection.md)), and the catalog lets any client change the app's state. Neither belongs in a build that reaches customers.

The only way to leave nothing of inspector in a release binary is to guard every call site in the app:

```swift
#if DEBUG
registration = Inspector.shared.state("chat.draft") { @MainActor [weak self] in
  self?.draft ?? ""
}
#endif
```

Without the guard, the registrations run in a release build too: they cost a lock and a dictionary entry each, and nothing serves them unless the app calls `serve()`.

## A later option: opt-in helpers without runtime overhead

The package could add helpers whose bodies are empty unless the package is compiled with `DEBUG`, which works because a source package is built in the app's configuration (verified on 2026-09-25 with Xcode 27 RC and Swift 6.4). They would still leave the package code and the app's closures in the binary, and custom configurations such as "Staging" are bucketed as release by an undocumented Xcode rule ([Swift Forums](https://forums.swift.org/t/swift-package-manager-and-custom-build-configurations/29181)). Whether to add them belongs to [ADR 003](003-app-api.md).

## Considered

- **Inert in release by default.** It contradicts the neutral core: the framework would decide for every app.
- **A macro that expands to nothing in release.** It would also remove the closures, but macros need swift-syntax, and the package takes no dependencies.

## Consequences

- A release build that registers without a guard ships those registrations. Nothing warns about it.
- Keeping inspector out of a release build is work at every call site until helpers exist.
