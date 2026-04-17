# Libero Framework Design

**Date:** 2026-04-17
**Status:** Draft

## Problem

Libero is too hard to use. A developer trying it for the first time faces: three-package setup, CLI codegen flags, handler wiring, message conventions, WebSocket plumbing, and generated code management. The cumulative weight kills adoption before anyone gets to the good parts.

The core innovation — ETF RPC with no JSON codecs — is simple and powerful. Everything built on top of it added complexity that obscures that value.

## Vision

Libero becomes a full-stack Gleam framework. One project, one command to run. Define your messages, write your handlers, Libero handles everything between your code and the wire.

**One-liner:** Like server components, but your client is a real SPA with typed RPC — and the same server logic works for REST, desktop, and CLI clients out of the box.

**When to use Libero instead of server components:**
- You need a real SPA (offline, low-latency UI, mobile)
- You want multiple client types (web + CLI + desktop) from one server
- You want clear client/server state boundaries
- You want typed end-to-end communication without JSON codecs

## Project Structure

```
my_app/
  src/
    core/
      todos.gleam                ← messages + types
      todos_handler.gleam        ← business logic, DB access
      db.gleam                   ← data access
    clients/
      web/
        app.gleam                ← Lustre SPA (user code)
        generated/               ← Libero-managed stubs
      cli/
        main.gleam               ← CLI app (user code)
        generated/               ← Libero-managed stubs
  gleam.toml
  libero.toml
```

### The rules

- `src/core/` is the server. Erlang target. Contains messages, types, business logic, handlers, DB access. Libero scans here for message types (`MsgFromClient`/`MsgFromServer`).
- `src/clients/` contains named consumer apps. Each has a compilation target declared in `libero.toml`. Libero generates typed stubs into each client's `generated/` directory.
- Developers organize `core/` however they want. Libero only cares about finding message types.

### What goes where

| Code | Location | Why |
|------|----------|-----|
| Message types | `src/core/` (any file) | Defines the server contract |
| Domain types | `src/core/` | Used by messages, handlers, clients |
| Handlers | `src/core/` | Implements the message contract |
| DB access, SQL | `src/core/` | Server-only concern |
| Business logic | `src/core/` | Server-only concern |
| SPA pages/views | `src/clients/<name>/` | Client-specific UI |
| CLI logic | `src/clients/<name>/` | Client-specific logic |
| RPC stubs | `src/clients/<name>/generated/` | Auto-generated, never edited |

## Configuration

```toml
# libero.toml
name = "my_app"
port = 3000

[server]
rest = true                    # expose handlers as JSON HTTP endpoints + OpenAPI spec

[clients.web]
target = "javascript"

[clients.cli]
target = "erlang"

[clients.ssr]
target = "erlang"
```

### Client targets

A client is a named consumer app with a compilation target. The target tells Libero what language to generate stubs in and what wire format to use.

Currently supported targets:
- `javascript` — ETF codec via JS FFI, WebSocket transport, Lustre effects
- `erlang` — native ETF, HTTP POST transport

Future targets (additive, no framework changes needed):
- `swift`, `kotlin`, etc. — requires an ETF codec for that platform + a code generator backend

The `rest` server flag exposes handlers as JSON HTTP endpoints with an auto-generated OpenAPI spec. This serves any client without codegen (Python, Go, curl, etc.).

### Client types are not special

`web`, `cli`, `storefront` — these are just names. The framework doesn't have a fixed set of client types. A client is a name + a target. `libero add` creates the entry and scaffolds the directory.

## CLI

### `libero new <name>`

Creates a new Libero project:
- Scaffolds `src/core/` with a starter message module and handler
- Creates `gleam.toml` and `libero.toml`
- No clients by default — add them with `libero add`

### `libero add <name> --target <target>`

Adds a client to the project:
- Adds `[clients.<name>]` section to `libero.toml`
- Creates `src/clients/<name>/` directory
- Generates a starter app if the directory is empty (one-time scaffold)
- Generates typed stubs into `src/clients/<name>/generated/`

### `libero gen`

Regenerate stubs after message type changes:
- Scans `src/core/` for message types
- Generates stubs into each client's `generated/` directory
- Generates server dispatch into `src/core/generated/`

### `libero build`, `libero run`, `libero test`, etc.

All other commands proxy to `gleam` verbatim. Arguments are passed through unchanged:

```
libero build                    → gleam build
libero run                      → gleam run
libero test                     → gleam test
libero build --target javascript → gleam build --target javascript
libero deps download            → gleam deps download
```

The developer uses `libero` as their single CLI. Only `new`, `add`, and `gen` do Libero-specific work. Everything else is `gleam` underneath.

## Code Generation

### What gets generated

**Per client (into `src/clients/<name>/generated/`):**
- Typed send functions (one per message module)
- Transport wiring (WebSocket for JS, HTTP for Erlang)
- Type registration (JS ETF codec needs constructor registration)
- RPC config (connection URL/path)

**Server-side (into `build/`, hidden from developer):**
- Dispatch table (routes incoming messages to handlers)
- Server bootstrap (Mist HTTP + WebSocket setup)
- REST routes + OpenAPI spec (if `rest = true`)
- Atom pre-registration (Erlang safety for ETF decoding)

### Generation rules

| What | When generated | Overwrites? |
|------|---------------|-------------|
| Starter app (`app.gleam`, `main.gleam`) | `libero new` / `libero add` only | Never — skipped if file exists |
| Client stubs (`generated/`) | Every `libero build` / `libero dev` / `libero gen` | Always — developer never edits |
| Server dispatch/bootstrap | Every build | Always — hidden in `build/` |

Generated files in `generated/` directories include a header comment: `// This file is auto-generated by Libero. Do not edit.`

## Developer Workflow

### Getting started

```
$ libero new my_app
$ cd my_app
$ libero add storefront --target javascript
$ libero dev
→ Server running at http://localhost:3000
→ Watching for changes...
```

This runs immediately — starter handler + starter SPA.

### Adding a feature

1. Define messages in `src/core/todos.gleam` (`MsgFromClient`, `MsgFromServer`)
2. Write handler in `src/core/todos_handler.gleam`
3. Extend client UI in `src/clients/storefront/app.gleam`
4. `libero dev` picks up changes automatically

### Adding a new client

```
$ libero add cli --target erlang
```

Adds the config entry, scaffolds `src/clients/cli/` with a starter app and generated stubs. Extend from there.

## Progressive Complexity

| Level | What you write | What you get |
|-------|---------------|--------------|
| **Server only** | Messages + handlers | Typed RPC server, callable via HTTP/ETF |
| **+ REST** | `rest = true` in toml | JSON HTTP endpoints + OpenAPI spec |
| **+ SPA** | `libero add storefront --target javascript` | Full Lustre SPA with typed WebSocket RPC |
| **+ CLI** | `libero add cli --target erlang` | BEAM CLI client with typed stubs |
| **+ Push** | Use push API in handlers | Real-time broadcast to connected clients |
| **+ SSR** | `libero add ssr --target erlang` | Server-side rendering client |
| **+ Static** | `libero add public --target static` (future) | Static site generation with data injection |

Each level adds to what's there. Nothing breaks, nothing gets rewritten.

## What Changes from Current Libero

| Today | Framework |
|-------|-----------|
| Three packages the developer manages | One project, Libero manages build packages |
| Manual codegen with CLI flags | Automatic, part of `libero build` / `libero dev` |
| Developer wires Mist/WebSocket | Libero owns server bootstrap |
| Developer writes Lustre entry point | Generated starter (extendable, never overwritten) |
| Config via CLI flags (`--ws-path`, `--shared`, etc.) | Config via `libero.toml` |
| "Library you import" | "Framework you scaffold with" |
| README explains machinery | Docs lead with "define messages, write handlers" |

## What Stays the Same

- ETF wire format
- `MsgFromClient` / `MsgFromServer` convention
- WebSocket transport for JS clients
- HTTP POST for Erlang/REST clients
- Lustre as the SPA framework
- Scanner + codegen internals (hidden, not removed)
- Push model (BEAM process groups)
- `RemoteData` pattern for async UI state
- Error envelope (`RpcError` with 4 variants)

## Scope and Non-Goals

### In scope
- Project scaffolding CLI (`new`, `add`, `dev`, `build`, `gen`)
- `libero.toml` configuration
- Automatic codegen (no manual CLI flags)
- Server bootstrap ownership (Mist, WebSocket, HTTP dispatch)
- Client starter app generation
- Multi-client support with per-client targets

### Out of scope (for now)
- Hydration / isomorphic views (deferred — needs target-sharing solution)
- Static site generation client target
- Non-Gleam code generation targets (Swift, Kotlin)
- Database/migration management (use parrot or another tool)
- CSS/asset pipeline
- Authentication framework

### Open questions for implementation
- How does the developer customize server behavior (middleware, custom routes, SSR hooks) when Libero owns the bootstrap? Likely a convention-based hook system or a config callback, but the exact mechanism is TBD during implementation planning.
