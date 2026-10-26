# Coding standards

What code in this repo has to look like. Read it before writing code; a reviewer checks a diff against it.

## Shared standards

The shared standards are generated from the Obsidian vault into `docs/coding-standards/` and never edited in the repo. Start at [docs/coding-standards/readme.md](docs/coding-standards/readme.md).

<!-- BEGIN shared file list: written by sync-coding-standards.py -->
- [`docs/coding-standards/general.md`](docs/coding-standards/general.md)
- [`docs/coding-standards/logging.md`](docs/coding-standards/logging.md)
- [`docs/coding-standards/macos-design.md`](docs/coding-standards/macos-design.md)
- [`docs/coding-standards/readme.md`](docs/coding-standards/readme.md)
- [`docs/coding-standards/swift-deprecations.md`](docs/coding-standards/swift-deprecations.md)
- [`docs/coding-standards/swift-testing.md`](docs/coding-standards/swift-testing.md)
- [`docs/coding-standards/swift.md`](docs/coding-standards/swift.md)
<!-- END shared file list -->

## This repo

### Architecture

One rule shapes every change: `InspectorKit` is **framework-neutral and dependency-free**. The wire
protocol is five operations (`hello`, `catalog`, `state`, `send`, `wait`), and actions are catalog
data: a new action never needs CLI code or a new message type. A framework integration is another
`Inspectable` conformer outside this package, never a special case inside it
([Two protocols](README.md#two-protocols)).

### What may be `public`

Anything not in this table stays `internal` or `private`. Adding to it is an API decision, not a
refactor.

| Audience | Public |
|---|---|
| App and feature packages | `Inspector` (`shared`, `init`, `state`, both `action`s, both `serve`s), `Registration`, `BonjourTransport(name:)`, `TypeSchema`, `SchemaDescribable` |
| Integrations | `Inspectable`, `Catalog`, `ActionNode`, `JSONValue` (+ accessors, and `contains(_:)`, the match rule the CLI re-checks a `send --until` answer with), `InspectorError`, `ErrorCode` |
| Transports / CLIs | `InspectorTransport`, `BonjourTransport.instanceNames(browsingFor:)`, `Request`, `Response`, `SendRequest`, `WaitRequest`, `SendResult`, `Hello`, `JSONDiffEntry`, `WireJSON` |

`TupleField` and `TupleInput` are public because `TypeSchema.tuple` carries them.
Every public symbol has a `///` comment; the DocC build must stay free of warnings.

### Conventions

- Swift tools 6.3, every target on the `.standard` concurrency profile in `Package.swift`.
- Platforms iOS 18 and macOS 26. Only `BonjourTransport` and `serve(app:)` need iOS 26, gated with
  `@available(iOS 26, macOS 26, *)`.
- No dependencies in `InspectorKit`, including the swift-docc-plugin; the `inspector` CLI target
  alone uses swift-argument-parser, at a released version.
- Code, comments and docs in English.
- No `tca` or other framework names in code or comments. The README names TCA once, as a future
  integration.
- `Inspector` is a `final class` with a `Mutex` so registration stays synchronous from
  `@MainActor` inits; the lock is never held across an `await`.
