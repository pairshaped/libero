# Libero v3 Architecture

## Overview

Libero is a type-safe RPC and messaging framework for Gleam applications with separate client, server, and shared packages. It uses Erlang Term Format (ETF) over WebSocket for efficient binary serialization, with codegen that produces typed dispatch and transport glue from shared type definitions.

v2 uses annotation-based codegen (`@rpc`, `@inject`). v3 replaces this with a message-type-driven approach where the entire framework surface is two type names: `ToServer` and `ToClient`.

## v2 (Current): Annotation-Based RPC

Server functions are annotated with `@rpc`. The codegen scans for these annotations, generates client stub modules, and generates a dispatch function that routes wire calls to the correct server function. An `@inject` system extracts session context (database connection, authenticated user, language, etc.) from an immutable session built at WebSocket connection time.

This works, but has friction:
- Annotations are scattered across server modules. Seeing the full API means grepping for `@rpc`.
- The `@inject` system requires a label-matching map and per-function signature scanning.
- The codegen generates a client stub module per server module. The client must import these generated modules and wire up `on_response` callbacks for each call.

## v3 (Vision): Message-Type-Driven

### The Convention

The codegen scans all modules in `shared/` for types named `ToServer` and `ToClient`. Any module exporting these types is a message module. Everything else in `shared/` is just domain types, untouched by the codegen.

- `ToServer`: messages the client sends to the server (replaces `@rpc`)
- `ToClient`: messages the server sends to the client (responses and push)

That is the entire framework convention. Two type names.

### File Organization

The developer decides how to organize message modules. Libero does not enforce a directory structure. One file, split by domain, split by direction: all valid. The type names are the convention, not the file layout.

```
// Starting simple (one file):
shared/src/shared/
  message.gleam             -- ToServer + ToClient for everything

// Growing by domain:
shared/src/shared/
  discounts.gleam           -- ToServer + ToClient alongside domain types
  accounts.gleam            -- ToServer + ToClient alongside domain types
  items.gleam               -- ToServer + ToClient alongside domain types
```

### Domain-Organized Example

A domain module contains types and wire messages together.

```gleam
// shared/src/shared/discounts.gleam

pub type Discount { ... }
pub type DiscountParams { ... }
pub type DiscountError { ... }

pub type ToServer {
  Save(id: Int, params: DiscountParams)
  Delete(id: Int)
  LoadAll
}

pub type ToClient {
  Saved(Discount)
  Deleted(id: Int)
  AllLoaded(List(Discount))
  Error(DiscountError)
}
```

This looks like a normal Lustre module with two message types instead of one. No new concepts to learn.

**Client-side update:**

```gleam
// client/src/client/discounts.gleam
import shared/discounts

pub type Msg {
  // Local UI messages (never cross wire)
  UserClickedDelete(id: Int)
  UserEditedName(String)

  // Server responses
  FromServer(discounts.ToClient)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserClickedDelete(id) -> #(
      Model(..model, deleting: Some(id)),
      discounts.send(discounts.Delete(id:)),
    )
    FromServer(discounts.Deleted(id)) -> #(
      remove_from_list(model, id),
      effect.none(),
    )
    FromServer(discounts.Error(err)) -> #(
      Model(..model, error: Some(err)),
      effect.none(),
    )
  }
}
```

**Server-side handler:**

```gleam
// server/src/server/discounts_handler.gleam
import shared/discounts

pub fn handle(msg: discounts.ToServer, state: SharedState) -> Result(discounts.ToClient, AppError) {
  case msg {
    discounts.Delete(id:) -> {
      use _ <- result.try(core_discounts.delete(db: state.db, org: state.org, id:))
      Ok(discounts.Deleted(id))
    }
    discounts.Save(id:, params:) -> {
      use discount <- result.try(core_discounts.save(db: state.db, org: state.org, id:, params:))
      Ok(discounts.Saved(discount))
    }
    discounts.LoadAll -> {
      use all <- result.try(core_discounts.list_all(db: state.db, org: state.org))
      Ok(discounts.AllLoaded(all))
    }
  }
}
```

### Why Only Two Type Names

A full-stack Gleam project with `client/`, `server/`, and `shared/` packages already has implicit separation:

- Client model: Lustre `Model` in `client/`
- Server state: defined in `server/`
- Client-only messages: Lustre `Msg` in `client/`
- Server-only messages: internal messages in `server/`

The package split handles four of the six concerns. Only the two wire types need a naming convention: `ToServer` (what crosses the wire going up) and `ToClient` (what crosses the wire going down).

### ToClient: Responses and Push

`ToClient` serves two purposes:

1. **Response**: the server handles a `ToServer` message and returns a `ToClient` value. This works over both WebSocket and HTTP.
2. **Push**: the server sends a `ToClient` message without a preceding request. WebSocket-only.

Same type, two delivery modes. HTTP clients (CLI, SDK, agents) only receive responses. WebSocket clients can also receive unsolicited push. No separate types needed for this distinction.

### Multi-Client Support

The same message types work over multiple transports:

- **WebSocket clients**: `discounts.send(msg)` over a persistent connection
- **HTTP clients**: POST the `ToServer` message as the request body, receive `ToClient` as the response

Same handler function, different transport. The server dispatch is identical regardless of how the message arrived.

### What Gets Generated

The codegen runs before `gleam build`, producing normal Gleam source files that the compiler type-checks alongside application code:

- **`send` functions** on the client: per-module ETF-encode and send over WebSocket
- **Server dispatch**: deserializes incoming WS/HTTP binary, routes to the correct domain handler, encodes response (with panic catching and trace IDs)
- **Client dispatch**: decodes incoming `ToClient` messages, routes to the correct domain handler
- **Wire codecs**: ETF codec registration for all types reachable from `ToServer` and `ToClient` across all modules

### Compile-Time Safety

Because generated files exist on disk before compilation, the Gleam compiler type-checks the entire chain:

- Add a new `ToServer` constructor but forget to handle it: **exhaustive pattern match error**
- Handler returns a type that does not match `ToClient`: **type mismatch error**
- Client calls `discounts.send` with the wrong type: **type mismatch error**
- A shared type referenced in a message changes shape: **errors propagate to both sides**

The codegen produces typed glue. The compiler validates everything. No runtime surprises.

### What v3 Eliminates from v2

| v2 | v3 |
|---|---|
| `@rpc` annotation on each server function | `ToServer` constructors define the interface |
| `@inject` annotation + inject module | Server handler receives state directly |
| Generated client stub modules | Client calls `discounts.send(msg)` |
| Dispatch with per-function label matching | Pattern match on `ToServer` per domain |
| `rpc_register` for JS codec registration | Still needed: ETF codec registration for JS target |

### Why Not Stateful Processes

We evaluated a stateful process-per-client model (similar to Phoenix Channels or LiveView). The `@inject` system already defines what a process would hold: database connection, authenticated user, org context, language, preferences. A stateful process would hold the same data, just mutably.

The conclusion: no client type benefits from per-account server state.

- **Admin UI**: CRUD operations are stateless request/response. UI state (drag-and-drop, form inputs, animations) belongs on the client.
- **CLI/SDK**: stateless HTTP with bearer tokens. No persistent connection.
- **Live event viewers**: need server push, but as a broadcast (one game process, many subscribers), not per-account sessions. SSE via Mist's built-in `server_sent_events` API handles this.

Server push for per-account context changes (role revoked, preferences changed mid-session) is not worth the lifecycle complexity. Handle it on the next RPC failure.

### Open Questions

- **Send function naming**: `discounts.send` vs other verbs. TBD.
- **SharedState passing**: server handlers need session context (db connection, authenticated user, language). Convention: first argument typed `SharedState`, or the dispatch wrapper provides it.
- **HTTP transport**: same `ToServer` types served over HTTP POST for CLI/SDK clients. Same handler, different entry point.
