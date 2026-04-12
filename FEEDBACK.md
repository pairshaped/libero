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

### 3. ~~Silent failure when @inject label doesn't match~~ FIXED

When a Wire parameter's rendered type matches an `@inject` function's return type but the label doesn't match, libero now emits a `LikelyInjectTypo` error with a suggested fix. This catches typos like `tzdb` vs `tz_db` at generation time instead of producing silently wrong code.

### 4. ~~`InternalError(trace_id)` is opaque to the client~~ FIXED

Added a `message: String` field to `InternalError`, populated with a default client-safe string ("Something went wrong, please try again.") in the generated dispatch. Consumers can pattern-match on `message` to show users something meaningful without leaking trace IDs or stack traces into the UI.

### 5. ~~Killing parent build doesn't always kill libero child process~~ FIXED

Root cause was #1 (missing `halt(0)` on success). Additionally, `main()` now installs SIGTERM and SIGHUP handlers via a spawned Erlang signal loop that calls `halt(1)` on receipt, so libero exits cleanly even when killed mid-generation.

### 6. ~~Dependency invalidation is consumer-managed~~ FIXED

Added a "Build integration" section to the README documenting that consumer staleness checks must also watch `@inject` modules, not just `@rpc` files. The inject module's mtime should be included in any stamp-based invalidation logic.

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
