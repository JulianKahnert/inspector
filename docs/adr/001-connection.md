# Connection: a swappable transport, JSON over TCP found through Bonjour by default

The network layer is a protocol: `InspectorTransport` carries one `Request` to the app and one `Response` back, and nothing above it knows how. The package ships one conformer, `BonjourTransport`, built on the Network framework's `NetworkListener` and `NetworkConnection`. It speaks JSON over plain TCP and is found through Bonjour. It does not use HTTP or distributed actors.

## The transport contract

A transport implements two calls (`Sources/InspectorKit/Transport/InspectorTransport.swift`):

- `serve(_:)` on the app side answers every incoming request until its task is cancelled.
- `send(_:)` on the CLI side delivers one request and returns its response.

That is the whole contract: request and response, nothing pushed. A transport never streams events to the CLI. Following the app live means asking `state` again, and every answer is the whole current state, so a missed poll loses no information. Whether a transport opens one connection per request or keeps one open is its own business. `BonjourTransport` opens one per request.

This fits how an agent uses the CLI: it runs one command through a shell tool and reads stdout only once the process ends. A command that waits for something polls inside that one call, which is still a single tool call for the agent.

An app picks a different transport with `serve(app:over:)`. The CLI, the wire messages and every registration stay the same.

## The default: `BonjourTransport`

The app advertises the service type `_inspector._tcp`. Each connection frames messages with `Coder(…, using: .json)` over `TCP()`, so one message is one JSON document. `NetworkListener`, `NetworkConnection` and `Coder` need iOS 26 and macOS 26, which is why `BonjourTransport` and `serve(app:)` are the only symbols gated with `@available(iOS 26, macOS 26, *)`.

### Naming and finding an app

- The app advertises under the Bonjour instance name `<app> @ <device>`: the name `Hello.app` reports and the device name. Two inspectable apps on one Mac, or on one iPhone, stay distinguishable in any Bonjour browser.
- `inspector apps` browses for `_inspector._tcp`, sends `hello` to every endpoint it finds, and prints one JSON array with each endpoint's Bonjour name, `app`, `pid` and `provider`. An endpoint that does not answer is listed as not live. This is a CLI command, not a fifth wire operation: the protocol keeps its four (`hello`, `catalog`, `state`, `send`).
- `--app NAME` selects an app by its full instance name or by its `<app>` part. When several apps match and no `--app` narrows them down, the command fails with `AMBIGUOUS_APP` instead of picking one, and the error's `detail` lists the instance names it found, the way `didYouMean` lists candidates for an unknown path.
- Discovery gives up after about 5 s and fails with `APP_NOT_FOUND`, so a CLI call with no app to talk to returns an error instead of hanging. The same code covers an `--app` that matches none of the apps found.
- Once the app is found, the exchange is bounded too: an app that stops answering, for example at a breakpoint, ends in `TIMEOUT`. The bound is 5 s, and for a `send` the settle timeout it asks for (`timeoutMs`, else the app's default of 5 s) plus 5 s, so the CLI never gives up before the app does.
- All three codes are `ErrorCode` cases (`appNotFound`, `ambiguousApp`, `timeout`), although only the CLI raises them. An agent then branches on `error.code` for every failure, in the same JSON shape, instead of parsing a message.

### Who can reach the app

Anyone on the same network. Bonjour advertises the app to every device on the local network, and `BonjourTransport` authenticates nobody, so any client that speaks the protocol can read the registered state and send the registered actions. This is accepted because inspector is meant for debug builds ([ADR 002](002-no-debug-release-decision.md)), and a physical iOS device can only be reached over the network. On a shared office or conference network it means that a colleague's CLI can steer your debug build.

## Considered

- **HTTP.** It would make the app reachable with `curl`, but the CLI is already the client, and an agent gains nothing from `curl`. The Network framework has no HTTP server, so the request parsing would be hand-written, since the package takes no dependencies.
- **WebSocket** (`NWProtocolWebSocket`). The Network framework supports it natively, but its main strength is server push, which the contract rules out.
- **Pushing events to the CLI.** A one-shot CLI call cannot receive anything after it exits, so push would only reach a long-running `watch` process, and every line it prints costs the agent context. A dropped stream loses events silently, where a repeated `state` request always returns the current truth, and push needs reconnects, backpressure and subscription state in the app. Polling inside one CLI call keeps it a single tool call without any of that. Push would pay off for many events per second, such as frame or scroll events, which an agent working in seconds does not need.
- **Distributed actors.** They bind both ends to the same Swift types, while the wire protocol is data, so that a client in another language or an integration for another framework can speak it. They also need a custom `DistributedActorSystem`, which is more code than the whole transport.
- **A Unix-domain socket in `$TMPDIR` as the default.** It keeps the app private to the user, but it cannot reach an app on a physical iOS device. It remains a candidate for a later, additional transport for the Mac and the simulator, where it would take the app off the local network.
- **A pairing token** that the app logs and the CLI sends along. It closes the network exposure, but every agent session would have to fetch the token first.
- **A protocol version in every message**, rejected on a mismatch or negotiated in `hello`. There is no long-term contract to keep: the reader is an agent that adapts to a changed message, and whoever needs a fixed protocol pins the package version.

## Consequences

- A debug build that serves is open to the local network. The recommendation to serve only from debug builds ([ADR 002](002-no-debug-release-decision.md)) is what limits the exposure.
