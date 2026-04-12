# Feedback

A running log of issues, gotchas, and improvement ideas hit while using libero in real projects. This is the intake queue for libero evolution — entries here become issues, PRs, and changelog entries over time.

The first batch of entries comes from the Curling IO v3 SPA port (late 2026), where libero is consumed as a git submodule and used to wire the admin panel's RPC layer. Future entries should come from any consumer that hits something surprising or time-wasting.

Add to this file whenever you hit something surprising, time-wasting, or improvable about libero. Keep entries short — one paragraph plus a severity tag.

Severity tags:
- **BLOCKING** — stops forward progress until worked around
- **HIGH** — causes lost time or confusion every time it happens
- **MEDIUM** — annoying but not time-consuming
- **LOW** — nice-to-have polish

## Known issues

### 1. ~~Libero hangs at 99% CPU after code generation~~ FIXED

The success path in `main()` returned `Nil` without calling `halt(0)`. The BEAM VM stays alive when `main` returns if any OTP processes or schedulers are running. Added `halt(0)` on the success path to match the error path's `halt(1)`.

### 2. ~~`--ws-url` parameter on a code generator is confusing~~ FIXED

Clarified CLI help text, generated config comments, and README to make it clear that `--ws-url` is the client's runtime WebSocket endpoint, not a generator input. Libero does not connect to this URL; it writes it into the generated `rpc_config.gleam`.

### 3. Silent failure when @inject label doesn't match (HIGH)

**Symptom:** If an `@rpc` function has a parameter whose label doesn't exactly match an `@inject` function name, libero silently doesn't inject anything — it treats the parameter as a wire parameter and requires the client to send it. No warning, no error, just wrong generated code.

**Example:** Naming a parameter `tzdb tzdb:` instead of `tz_db tz_db:` silently produces a generated client that expects the caller to pass a `TzDatabase` over the wire. This was only caught when the generated client-side function signature looked wrong.

**Suggestion:** Libero should either (a) warn when a parameter type matches a known inject function but the label doesn't, or (b) error out when a non-inject parameter has a type that can't cross the wire (`sqlight.Connection`, `tz_database.TzDatabase`, etc.).

### 4. `InternalError(trace_id)` is opaque to the client (MEDIUM)

**Symptom:** When a server-side `@rpc` function panics or raises an error that isn't in its declared error type, the client receives `InternalError(trace_id: "...")`. The trace_id helps find the error server-side, but the client has no way to show a useful message to the user.

**Current workaround:** Every SPA page has `InternalError(trace_id:) -> "Internal error (trace " <> trace_id <> ")"` — useful to developers, useless to end users.

**Suggestion:** Either include a client-safe error message in `InternalError` (e.g. "Internal server error, please retry"), or let the server-side `@rpc` function opt into sending structured error details. Alternatively, support logging trace_ids to a debug sink without surfacing them in the message.

### 5. Killing parent build doesn't always kill libero child process (HIGH)

**Symptom:** When a consumer's build script is interrupted (Ctrl-C or SIGTERM from a sandbox), its libero child process sometimes survives and continues spinning at 99% CPU. This compounds issue #1 — each interrupted run leaks a stuck libero process.

**Suggestion:** Libero should set up `SIGTERM` / `SIGINT` handling to exit cleanly when its parent dies. Alternatively (or additionally), consumers' build scripts should trap and propagate signals to child processes, but that's consumer code — libero should defend itself too.

### 6. Dependency invalidation is consumer-managed (LOW)

**Symptom:** Adding a new `@inject` function to the consumer's inject module doesn't invalidate libero's generated output unless the consumer knows to delete their stamp file manually. Consumer build scripts typically watch `.gleam` files under the RPC root for staleness, but logically any change to inject function signatures affects every generated dispatch case.

**Impact:** Easy to forget after adding an inject. The v3 port hit this when adding `tz_db` and `storage_config` injects.

**Suggestion:** Either (a) mention this in libero docs so consumers know to watch their inject module too, (b) have libero itself track input file mtimes and short-circuit when nothing's stale, so consumers don't need to stamp-manage.

## Ideas for future libero capabilities

### Structured deprecation support

As `@rpc` signatures evolve during a large port, consumers occasionally change a signature without immediately updating every generated client (e.g. during a refactor). Libero could support `@deprecated("message")` on `@rpc` functions and generate a warning in the client stubs.

### Typed dispatch mode

Libero currently generates a single `handle_<namespace>` function that takes binary data. This works but means every dispatch is a runtime binary decode. A typed dispatch mode (one Gleam function per `@rpc` that takes decoded params and returns encoded result) would be useful for testing: consumers could call the RPC layer directly in tests without going through the binary encoder/decoder.

### Test helpers

Every `@rpc` function tends to want integration tests on the consumer side. Libero could generate test fixtures — e.g. a mock session builder, a way to call RPCs with decoded params directly, and a way to assert on the response shape.

### Schema snapshot for client-generated types

Libero walks the `@rpc` type graph and generates registration code so the client can decode all referenced types. If the server's type graph changes (e.g. adding a variant to a shared error type), the client needs a full regen. A schema snapshot file that libero compares against would catch drift at CI time instead of runtime.

### Helper extraction for per-section boilerplate

Consumers building typical admin CRUD sections end up writing the same `rpc_error_to_string` pattern in every section: unwrap `AppError(e)` / `InternalError(trace_id)` / `UnknownFunction(name)` / `MalformedRequest` into a string. Libero could emit a helper that handles the non-app cases uniformly so consumers only write the `AppError(e)` branch.

## Adding to this doc

When you hit something, add an entry above the "Ideas for future libero capabilities" section with:
- A short title ending in `(SEVERITY)`
- **Symptom:** what you observed
- **Impact:** what it cost (if non-obvious)
- **Hypothesis** or **Workaround** if you have one
- **Suggestion** if you have one

Keep entries grounded in what actually happened — speculation is fine but mark it as hypothesis.
