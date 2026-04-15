# Feedback

A running log of issues, gotchas, and improvement ideas hit while using libero in real projects. Entries here become issues, PRs, and changelog entries over time.

The first batch of entries comes from the Curling IO v3 SPA port (late 2026), where libero is consumed as a git submodule and used to wire the admin panel's RPC layer. Future entries should come from any consumer that hits something surprising or time-wasting.

Add to this file whenever you hit something surprising, time-wasting, or improvable about libero. Keep entries short: one paragraph plus a severity tag.

Severity tags:
- BLOCKING: stops forward progress until worked around
- HIGH: causes lost time or confusion every time it happens
- MEDIUM: annoying but not time-consuming
- LOW: nice-to-have polish

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

Added `--write-inputs` flag: when passed, libero writes a `.inputs` manifest listing every source file it scanned (one per line, sorted). Consumer build scripts can diff this against a stamp file for reliable staleness checks. Also documented the manual watch list approach in the README's "Build integration" section.

### 7. ~~`LikelyInjectTypo` check is too aggressive~~ FIXED

The type-only check from issue #3 now also requires the label to be within Levenshtein distance 2 of the inject function's name. This catches real typos (`tzdb`/`tz_db` = distance 1) while ignoring unrelated labels that happen to share a common type (`key`/`lang` = distance 3+).

### 8. ~~`--ws-url` bakes a subdomain into the compiled client~~ FIXED

Added `--ws-path` flag as an alternative to `--ws-url`. When used, the generated `rpc_config.gleam` resolves the full WebSocket URL at runtime from `window.location` (scheme + host + path), so one compiled bundle works across all subdomains. Breaking change: `rpc_config.ws_url` is now a function (`rpc_config.ws_url()`) instead of a constant, for both modes.

### 9. ~~Walker hangs silently~~ FIXED (exponential blowup from eager bool.guard evaluation)

Walker hung indefinitely when a consumer had multiple modules reachable from @rpc signatures. Symptom looked like a name-collision issue but the real root cause was unrelated.

Root cause: `do_walk` and `process_type_ast` both used `bool.guard(when:, return: ...)` where the `return:` argument was a recursive call to `do_walk`. Because Gleam evaluates function arguments eagerly, the recursive `do_walk` fired on EVERY call regardless of the `when:` condition. Each call to `do_walk` effectively ran `do_walk(rest_queue)` as a side effect of constructing the `bool.guard` arguments, before the skip check even ran. The result was exponential blowup: each level of the BFS forked into redundant chains that all eventually ran. For a graph with N reachable types the walker did O(2^N) work and hung long before finishing.

With the v3 consumer, 8 seed types and ~20 reachable types produced millions of redundant process_type_ast calls. Looked like a hang, was actually just very slow exponential work.

Fix: replace `bool.guard(when:, return: expr)` with `bool.lazy_guard(when:, return: fn() { expr })` in both call sites. `lazy_guard` takes a thunk and only evaluates it when the condition matches. This is the correct primitive whenever the `return` expression has side effects or is expensive. Two sites in `src/libero.gleam`:
- `do_walk`: visited-set skip check (line ~803)
- `process_type_ast`: is_alias early return (line ~944)

With the fix, the v3 consumer's full 8-section type graph (33 @rpc functions, 104 variants) processes in well under a second, as expected.

Lesson: any `bool.guard` with a non-trivial `return:` expression is a latent bug. A good audit for libero: `grep -n "bool.guard" src/libero.gleam` and confirm each `return:` is either a constant or a trivially-cheap expression with no recursive calls or side effects. When in doubt, use `lazy_guard`.

## Ideas for future libero capabilities

### Structured deprecation support

As `@rpc` signatures evolve during a large port, consumers occasionally change a signature without immediately updating every generated client (e.g. during a refactor). Libero could support `@deprecated("message")` on `@rpc` functions and generate a warning in the client stubs.

### Typed dispatch mode

Libero currently generates a single `handle_<namespace>` function that takes binary data. This works but means every dispatch is a runtime binary decode. A typed dispatch mode (one Gleam function per `@rpc` that takes decoded params and returns encoded result) would be useful for testing: consumers could call the RPC layer directly in tests without going through the binary encoder/decoder.

### Test helpers

Every `@rpc` function tends to want integration tests on the consumer side. Libero could generate test fixtures - e.g. a mock session builder, a way to call RPCs with decoded params directly, and a way to assert on the response shape.

### Schema snapshot for client-generated types

Libero walks the `@rpc` type graph and generates registration code so the client can decode all referenced types. If the server's type graph changes (e.g. adding a variant to a shared error type), the client needs a full regen. A schema snapshot file that libero compares against would catch drift at CI time instead of runtime.

### Helper extraction for per-section boilerplate

Consumers building typical admin CRUD sections end up writing the same `rpc_error_to_string` pattern in every section: unwrap `AppError(e)` / `InternalError(trace_id)` / `UnknownFunction(name)` / `MalformedRequest` into a string. Libero could emit a helper that handles the non-app cases uniformly so consumers only write the `AppError(e)` branch.

## Adding to this doc

When you hit something, add an entry above the "Ideas for future libero capabilities" section with:
- A short title ending in `(SEVERITY)`
- Symptom: what you observed
- Impact: what it cost (if non-obvious)
- Hypothesis or workaround if you have one
- Suggestion if you have one

Keep entries grounded in what actually happened - speculation is fine but mark it as hypothesis.
