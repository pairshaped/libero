# History

How Libero got to its current shape: the phases, the forks we didn't take, and what's still open. This is a narrative companion to the README, not a changelog. For release notes see the git log.

## Why this exists

The question that started it: *if your Gleam SPA and your Gleam server are the same language with the same types, why are you building REST endpoints and hand-writing JSON codecs on both sides?*

REST made sense when the server and the client spoke different languages. You serialized at the boundary because you had to. That cost is pure overhead when both sides are Gleam. The types are already shared through the `shared/` package. The wire just needs to round-trip primitives and custom types without either side having to re-derive the schema.

Libero fell out of answering that question all the way.

## Phases

### Phase 1: The inspiration and the sketch (pre-code)

The idea started as frustration with how much ceremony REST adds to a same-language stack. Every endpoint you want to call from the SPA requires:

1. A route on the server (`POST /api/records`)
2. A request decoder on the server (`gleam/json` destructuring, error handling, validation)
3. A response encoder on the server (more `gleam/json`, more error paths)
4. A matching request encoder on the client (hand-written, has to stay in sync)
5. A matching response decoder on the client (hand-written, has to stay in sync)
6. Manual error handling at every step, with no guarantee the server's `SaveError` variants match what the client handles

All of that is purely because HTTP is language-agnostic. For a REST API that serves third-party consumers (iOS app, partner integrations, curl scripts) that work is mandatory. For a Gleam client calling a Gleam server, it's all overhead. Both sides know the types. The types are literally imported from `shared/`. The serialization is reinventing something the compiler already has.

The obvious prior art was worth studying.

**Meteor.** The 2010s "full-stack reactive" framework. Client-side code could call server methods directly via `Meteor.call('method-name', args, callback)`, and Meteor handled the wire. What we liked: the ergonomics of "just call the function". What we didn't take: Meteor was JavaScript on both sides, not a typed language, and the reactive data-sync story (live queries, publication model) was a separate layer we didn't want to inherit.

**Phoenix LiveView.** Elixir's answer: the server owns the view state and pushes HTML diffs over a WebSocket. What we liked: the WebSocket-as-transport decision, the single-connection lifecycle, the intuition that same-origin stateful sockets are simpler than stateless HTTP for same-app traffic. What we didn't take: LiveView keeps the view state on the server. We wanted the opposite, where the SPA owns its model and the server answers discrete RPCs.

**tRPC (TypeScript).** End-to-end typed RPC for TypeScript projects. What we liked: the "define once, call from anywhere" ergonomic, the idea that a code generator can bridge two sides of a language boundary without either side hand-writing schemas. What we didn't take: tRPC leans on TypeScript's structural typing and package-boundary imports; Gleam's nominal types and its package model wanted a different shape.

**Omnimessage (Gleam).** The closest existing thing in the Gleam ecosystem. Omnimessage models client/server communication as a single bidirectional `Msg` channel: the same `Msg` type flows on both sides, with variants tagged as client-only, server-only, or shared. The shared variants drive state synchronization (the server is the source of truth, the client merges incoming updates). Omnimessage is published on hex as `omnimessage_lustre` plus `omnimessage_server`, and we evaluated it carefully. What we liked: the recognition that REST is overkill for a Gleam-to-Gleam stack, the validation that a Lustre `Msg`-shaped wire actually works, and the careful thinking about transport health as a first-class concern. What we didn't take: omnimessage asks you to hand-write an encoder/decoder for your `Msg` type, where Libero wanted that to be generated. Omnimessage's bidirectional shared-`Msg` model is great for chat apps and state-sync use cases, but our project's calls are mostly discrete request/response operations (save this record, fetch that list, run this calculation), so a strict RPC model with a typed `Result(T, RpcError(E))` envelope per call fit better than a stream of merge-able shared messages. Different sweet spots, both valid.

The doc sketched a few architectural dimensions.

**One package vs. many.** Should the server and client be one Gleam package (with both `erlang` and `javascript` targets building from the same source tree) or separate packages sharing a `shared/` package? Considered both. Separate packages won: the server pulls in Erlang-target deps (Wisp, Mist, sqlight) that the client has no business seeing, and the client pulls in JS-target deps (Lustre, FFI shims) that the server doesn't need. A single cross-target package would need target gating on every import. Three separate packages with a `shared/` for common types is cleaner and matches what we were already doing in our project.

**Server process spectrum.** Where does each RPC live on the "stateful service ↔ stateless function" line? In our case (mostly CRUD plus a few stateful workflows like payments), almost every RPC is a pure function of request plus session. That's the shape Libero optimizes for: stateless RPCs, session context threaded via `/// @inject`, no per-connection mutable state on the server beyond what the WebSocket handler owns.

**Wire transport.** WebSocket won over HTTP-per-call for three reasons. A persistent connection has lower per-call overhead. Same-origin WebSockets avoid the CORS song and dance. A bidirectional channel leaves room for future server-push features (notifications, live updates) without redesigning the wire. RPCs are still strict request/response today and Libero doesn't use the bidirectional nature, but the door is open.

A later update to the design doc added notes about the WCCG context protocol (mentioned by Hayleigh) and the ETF-vs-JSON wire format tradeoff. Most of those notes became moot once the prototype shipped and empirical answers replaced the theoretical ones.

The observation that let the project start in code: nobody in the Gleam ecosystem had built this yet, and Lustre's Elm architecture (`Model` / `Msg` / `Effect`) composes cleanly with a request/response RPC model. An RPC call is just `Effect(msg)` where `msg` carries `Result(T, RpcError(E))`. No special Lustre machinery required.

### Phase 2: The proof of concept

A throwaway test bed. Three Gleam packages (`server/`, `client/`, `shared/`) mirroring our project's layout, a Wisp+Mist HTTP/WS server, a Lustre SPA, a SQLite-backed records/notes CRUD app. Built to prove out the wire format and the codegen without committing to a library shape. The proof of concept lived its entire life as a local-only prototype. Never published, never deployed, never meant to be.

### Phase 3: The wire format detour

First wire implementation used ETF (Erlang Term Format). Binary, compact, beam-native. `term_to_binary` on the server, a hand-rolled ~300-line JS decoder on the client to rebuild Gleam custom types from the raw ETF bytes. Worked fine, round-tripped cleanly.

Then Louis mentioned offhand: *"I'd recommend JSON over ETF, it's much faster. Native `JSON.parse` beats any hand-rolled binary decoder in the browser."* Never formally benchmarked, but the intuition held up under inspection:

- Browser `JSON.parse` is written in C++ and has been tuned for two decades.
- Our ETF decoder was ~300 lines of JavaScript doing byte-level work.
- JSON is `tcpdump`-friendly in a way ETF isn't.
- The custom-type shape `{"@": "record", "v": [...]}` is small enough to keep the payload size comparable.

Switched to JSON. Decoder shrunk to ~50 lines: parse with `JSON.parse`, walk the tree, rebuild Gleam custom types via a constructor registry registered at app startup. Result: smaller code, faster decode, easier debugging.

The ETF branch still exists somewhere in the git history. v3 switched back to ETF after the JSON detour proved unnecessary for a same-language stack.

### Phase 4: From hand-written dispatch to annotation-driven codegen

The first pass had a hand-written dispatch table (`case fn_name { "records.save" -> records.save(...) }`) and hand-written client stubs (`pub fn save(...) -> Effect(msg) { rpc.call_by_name(...) }`). Tedious. Every new RPC function meant editing three files.

What we wanted: mark a `pub fn` as exposed and let a generator do the rest.

A TOML config listing RPC names by string was rejected. Config-over-code loses the type system and adds a coordination step.

A Gleam attribute or macro doesn't exist in the language.

A doc comment marker (`/// @rpc`) worked. Gleam's parser discards doc comments from the AST, but a simple text preprocessing step can extract them before handing the source to `glance`. Grep-able, in-source, minimal.

Went with the doc comment marker. The generator (`libero/src/libero.gleam`) walks `src/server/**`, finds every `pub fn` preceded by `/// @rpc`, and emits both the dispatch case and the client stub. Types flow through automatically because the generator runs the same `glance` parser the Gleam compiler uses.

### Phase 5: Session context and `/// @inject`

Plain RPC functions have no business knowing about HTTP sessions, database connections, or user IDs. But the server does need those values, and the generator has to thread them from the WebSocket handler into each RPC call.

A TOML config for inject rules was rejected for the same reason as the RPC registry. Config-over-code loses the types.

An implicit thread-local "current session" was rejected because it breaks purity, testability, and Gleam's functional model.

Doc comment markers on inject functions (`/// @inject`) won. Consistent with `@rpc`, keeps everything in-source.

The session type is inferred from the first inject function's signature. Every inject fn takes `Session -> FieldType`, and the generator walks them to build a map from label to inject fn. At dispatch time, an RPC function's first labeled argument whose name matches an inject fn gets the injected value. The rest are coerced from the wire.

The happy consequence: admin and public SPAs can have totally different Session types (admin carries `User + Connection`, public carries a cart cookie) and Libero infers each one independently.

### Phase 6: The error envelope

Every response is `Result(T, RpcError(E))` where `RpcError(e)` has four variants:

- `AppError(e)` is the server function's own domain error (`DuplicateEmail`, `NotFound`, whatever).
- `MalformedRequest` is returned when the wire envelope couldn't be decoded.
- `UnknownFunction(name)` is returned when the dispatch table has no matching case (deployment skew).
- `InternalError(trace_id)` is returned when the server function panicked, with a correlation id.

Two design decisions worth calling out.

**The `Never` type for bare-T returns.** Server functions that return a bare `T` (no `Result`) get `RpcError(Never)` on the client side. `Never` is uninhabited, so the `AppError(_)` pattern-match arm is statically unreachable and consumers can omit it. Gleam's exhaustiveness checker doesn't perfectly propagate the uninhabitedness through type variables, so a wildcard fallback is still needed, but that's good enough.

**PanicInfo bubbles up separately.** When a server RPC panics, libero's `trace.try_call` catches it, generates a trace_id, and returns both an `InternalError(trace_id)` envelope AND a `PanicInfo` value (trace_id, function name, stringified reason) to the WebSocket handler. The handler logs the PanicInfo via whatever logger the consumer uses: `wisp.log_error`, Sentry, Datadog, stdout, anything. Libero has zero logging dependencies. This was a late course correction. An earlier draft had libero call `wisp.log_error` directly, which would have coupled the library to the web framework. The bubble-up design means libero stays web-framework-agnostic.

### Phase 7: Multi-SPA namespaces

Our project has an admin SPA and (eventually) a public SPA sharing one server package. Each SPA has its own Lustre app, its own set of `@rpc` functions, potentially its own Session type, and its own WebSocket endpoint.

The naive approach would duplicate Libero's entire pipeline per SPA. What we actually built:

- A `--namespace=admin` flag to the generator.
- A directory convention where `src/server/<ns>/**` is the scan root for namespace `<ns>`.
- Wire names prefixed with the namespace, so `admin.items.save` and `public.items.save` never collide.
- A dispatch entry point renamed to `handle_admin` or `handle_public`.
- Generated output under `generated/libero/<ns>/` to keep namespaces physically isolated.
- `PanicInfo.fn_name` inheriting the prefix so log correlation works across SPAs.

The design came out of a long brainstorming session about how our project would adopt Libero. Our admin tree is nested three levels deep (`admin/items/variants.gleam`, `admin/orders/create.gleam`, and so on), so the generator also had to switch from a flat top-level scan to a recursive walker that skips `generated/` and symlinks.

### Phase 8: Extraction and standalone-ization

Libero lived inside the proof of concept for a while as `lib/libero/`. Once the design stabilized, it was extracted into its own repo at `github.com/pairshaped/libero`. Further work:

- Added glinter as a dev dependency so Libero lints itself without needing a parent project.
- Added a unit test suite for `libero/wire` and `libero/trace`, the pure building blocks most likely to regress silently.
- Built the FizzBuzz example (`examples/fizzbuzz/`) to serve as the library's runnable reference.
- Retired the proof of concept. It was never meant to be a published thing, and the fizzbuzz example covers everything a minimal demo needs.

### Phase 9: v3, message types and naming

v3 replaced the `@rpc` annotation-driven model with a convention-based message type approach. Instead of annotating individual functions, you define `MsgFromClient` and `MsgFromServer` types in a shared module and Libero generates the dispatch and stubs from those.

The naming drew from elm-webapp and Lamdera. Every function name tells you who's sending and who's receiving:

- `send_to_server(msg:)`, client sends to server
- `update_from_client(msg:)`, server handles client message
- `update_from_server(handler:)`, client handles server push
- `push.send_to_client(client_id:, ...)` / `push.send_to_clients(topic:, ...)`, server pushes to client(s)

Other v3 changes:

- **Auto-registration.** Codec registration (the `register_all()` call that maps constructor atoms to JS classes) now happens automatically on the first `send_to_server` call. Users never need to call it manually. The generated `registerAll()` JS function is idempotent.

- **Wire protocol tagging.** Server-to-client frames now carry a 1-byte prefix: `0x00` for responses (matched FIFO to pending callbacks) and `0x01` for pushes (routed to the module's `update_from_server` handler). This lets request/response and server push coexist on the same WebSocket.

- **Server push.** The `libero/push` module uses BEAM pg (process groups) for topic-based subscriptions. WebSocket connection processes join topics via `push.join(topic:)` and receive push frames that they forward to the browser. Targeted pushes to individual clients use `push.register(client_id:)` and `push.send_to_client(client_id:, ...)`. Both use the same pg mechanism. A targeted push is just a group with one member.

- **HTTP POST transport.** The server's `dispatch.handle(state:, data:)` takes `BitArray` in and returns `BitArray` out, so it works with any transport. Adding an HTTP POST route for CLI clients is a few lines of Wisp code. No Libero changes needed.

- **CLI example.** A BEAM CLI client at `examples/todos/cli/` that sends `MsgFromClient` messages over HTTP POST using native `term_to_binary`. No Libero dependency on the client side. Demonstrates the full CRUD loop with command-line argument parsing.

- **ETS-backed store.** The todos example moved from per-connection in-memory state to a shared ETS table, so both WebSocket (browser) and HTTP (CLI) clients see the same data. `SharedState` became a unit type. The handler is stateless, actual state lives in ETS.
