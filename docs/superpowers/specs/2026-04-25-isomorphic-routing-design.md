# Isomorphic routing design

**Status:** draft
**Author:** dave (with claude)
**Date:** 2026-04-25
**Bean:** libero-nm1e
**Follow-up bean:** libero-ah9l (SSR convenience helpers)

## Background

The `examples/ssr_hydration` example demonstrates SSR-with-hydration end to end, but the per-route plumbing is hand-written in two places:

1. `examples/ssr_hydration/src/ssr_hydration.gleam:render_ssr` — for each route, fetch data via `ssr.call`, build a `Model`, render the lustre view, embed flags, build the HTML document.
2. `examples/ssr_hydration/clients/web/src/router.gleam` — a thin browser-only wrapper around `pushState` / `popstate` / link-click interception.

Both grow linearly with the number of routes. There's no shared abstraction for "given a URL, render the page the SPA would render at that route."

## Goals

A user can deep-link any URL the SPA serves and get a server-rendered first paint. After hydration the SPA owns the model and handles subsequent navigation normally.

The libero piece is a runtime helper that composes existing primitives (`ssr.call`, `encode_flags`, `decode_flags`) into one entry point. It is opinionated about the SSR-with-hydration shape but stays out of the way for everything else (browser routing → modem; browser plumbing → existing lustre/modem patterns).

## Non-goals

- **Isomorphic loaders.** Client-side navigation does not re-invoke the server's loader. The SPA handles in-app data fetching with its existing rpc patterns. (Could be a follow-up bean if real apps want it.)
- **Codegen.** Routes, parsers, and loaders are user-written Gleam. Codegen here would buy nothing the type system isn't already providing.
- **Form-POST-to-route / non-GET pages.** v1 supports GET only.
- **Browser routing primitives.** Modem owns click interception, pushState, popstate. Libero does not reinvent these.
- **A new `libero/page` namespace.** Five functions, all about SSR — they live in `libero/ssr` alongside the existing primitives.

## Architecture

### Pieces and ownership

**Shared (compiles to BEAM + JS), user-written:**
- `Route` type — sum type with constructor params for path/query data
- `parse_route(uri: Uri) -> Result(Route, Nil)` — pattern-match on path segments
- `route_to_path(route: Route) -> String` — straight construction (user `percent_encode`s any user-supplied strings)
- `Model` type — must be wire-encodable end-to-end (no functions, no live JS Dynamic)
- `view(model) -> Element(msg)` — pure; no FFI calls inside

**Server, user-written:**
- `load(req, route, state) -> Result(Model, Response)` — fetches data via `ssr.call`, builds Model. On `Error(response)`, libero returns that response directly (loader owns auth redirects, soft 404s, custom error pages).
- `render(route, model) -> Element(msg)` — full document tree. User composes `view(model)` inside their HTML shell along with `ssr.boot_script(...)` for the flag-embedding script.

**Server, libero-provided:**
- `ssr.handle_request(req, parse, load, render, state) -> Response` — orchestrates parse → load → render → wrap.
- `ssr.boot_script(client_module, flags) -> Element(msg)` — encoded-flags script element.

**Client, user-written (~5 lines, scaffolded for new apps):**
- `init` decodes flags, returns `(Model, modem.init(...))` for subsequent navigation.

### View purity discipline

Views must not call FFI. The Erlang target compiles JS-only `@external` functions but crashes at runtime if invoked. The rule is enforced by:
- Package boundaries: the `shared/` Gleam crate's `gleam.toml` only depends on cross-target packages.
- Convention: shared views never import from `clients/web/`.
- An SSR smoke test per route in CI catches regressions.

### Escape hatches for client-only behavior

Three patterns, in order of reach:
1. **Placeholder + effect** — view renders an empty container (`html.div([attribute.id("map")], [])`); client init runs an effect that calls FFI to populate it. Server emits empty div, client fills it post-hydration.
2. **Custom element / web component** — wrap JS-only behavior as a custom element registered in the client bundle. View emits `html.element("rich-editor", [...])`. Browser instantiates it; lustre does not need to know. (Same pattern lustre's own server components use for the `<lustre-server-component>` bridge.)
3. **`hydrated: Bool` flag** — model has `hydrated: Bool` (False during SSR, flipped True in client init); view branches on it for subtrees where SSR and client renders differ significantly. Causes a flash on hydration; use sparingly.

The user-facing rule is narrow: **no FFI in `view`**. Effects and custom elements are invisible to the server.

## API

### `ssr.handle_request`

```gleam
pub fn handle_request(
  req req: Request(Connection),
  parse parse: fn(Uri) -> Result(route, Nil),
  load load: fn(Request(Connection), route, state) -> Result(model, Response(ResponseData)),
  render render: fn(route, model) -> Element(msg),
  state state: state,
) -> Response(ResponseData)
```

**Flow:**
1. If `req.method != Get`, return 405 with empty body.
2. Construct `Uri` from `req.path` and `req.query`.
3. `parse(uri)` → `Error(Nil)`: return 404 with empty body. Custom 404 pages: handle the catch-all in your mist router and only call `handle_request` for routes you recognize.
4. `load(req, route, state)` → `Error(response)`: return that response.
5. `render(route, model)` → `Element(msg)`.
6. `element.to_document_string(rendered)` → String.
7. Return 200 with `content-type: text/html` and `mist.Bytes(bytes_tree.from_string(...))` body.

### `ssr.boot_script`

```gleam
pub fn boot_script(
  client_module client_module: String,
  flags flags: a,
) -> Element(msg)
```

Returns a `lustre/element.fragment([...])` of two script elements:
```html
<script>window.__LIBERO_FLAGS__ = "<base64-etf>";</script>
<script type="module">
  import { main } from "<client_module>";
  main();
</script>
```

Implementation calls `encode_flags(flags)` internally. The base64 string is safe inside the JS string literal.

### `libero/ssr` after this change

- `call` — kept. Loaders use it.
- `encode_flags` — kept. `boot_script` uses it; users may call directly for custom shells.
- `decode_flags` — kept. Client `init` uses it.
- `document` — **removed.** The canned `(title, body, flags, client_module)` shell can't express what real apps need (curling/v3's admin shell has conditional `<html>` attributes, multiple stylesheets with cache-busting, vendor scripts, custom elements, etc.). Replaced by user-written `render` + `boot_script`.
- `handle_request` — **new.**
- `boot_script` — **new.**

### Example user code

**Shared route parser** (`shared/views.gleam`, additions to existing example):
```gleam
pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    [] | ["inc"] -> Ok(IncPage)
    ["dec"] -> Ok(DecPage)
    _ -> Error(Nil)
  }
}
```

**Server entry** (replaces `render_ssr` and the per-route case in `ssr_hydration.gleam`):
```gleam
fn handle(req: Request(Connection), state: HandlerContext) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["ws"] -> ws.upgrade(...)
    ["rpc"] -> handle_rpc(req, state, logger)
    ["web", ..] -> serve_static(req)
    _ -> ssr.handle_request(
      req:,
      parse: views.parse_route,
      load: load_page,
      render: render_page,
      state:,
    )
  }
}

fn load_page(_req, route, state) -> Result(Model, Response(ResponseData)) {
  use counter <- result.try(
    ssr.call(
      handle: dispatch.handle,
      state:,
      module: "shared/messages",
      msg: GetCounter,
      expect: result.unwrap(_, 0),
    )
    |> result.map_error(fn(_) { server_error_response() })
  )
  Ok(Model(route:, counter:))
}

fn render_page(_route, model: Model) -> Element(Msg) {
  html.html([attribute.attribute("lang", "en")], [
    html.head([], [
      html.title([], "Counter"),
      html.link([attribute.rel("stylesheet"), attribute.href("/web/app.css")]),
    ]),
    html.body([], [
      html.div([attribute.id("app")], [views.view(model)]),
      ssr.boot_script(client_module: "/web/app.mjs", flags: model),
    ]),
  ])
}
```

**Client init** (`clients/web/src/app.gleam`, simplified from existing):
```gleam
pub fn main() {
  let app = lustre.application(init, update, views.view)
  let assert Ok(_) = lustre.start(app, "#app", get_flags())
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(Msg)) {
  let assert Ok(model) = libero_ssr.decode_flags(flags)
  #(model, modem.init(fn(uri) {
    case views.parse_route(uri) {
      Ok(route) -> NavigateTo(route)
      Error(_) -> NoOp
    }
  }))
}

@external(javascript, "./flags_ffi.mjs", "getFlags")
fn get_flags() -> Dynamic
```

The hand-rolled `clients/web/src/router.gleam` (pushState/popstate/click interception wrappers) **deletes entirely** — modem replaces it.

### Route params

Params work entirely through the user's `Route` type — no library support needed. Constructors carry the param data; `parse` extracts; `to_path` formats. Example:

```gleam
pub type Route {
  Post(id: Int)
  UserProfile(slug: String, tab: ProfileTab)
  Search(query: String, page: Int)
}

pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    ["posts", id_str] -> int.parse(id_str) |> result.map(Post)
    ["users", slug] -> Ok(UserProfile(slug, ProfileOverview))
    ["search"] -> {
      let params = uri.parse_query(option.unwrap(uri.query, "")) |> result.unwrap([])
      let q = list.key_find(params, "q") |> result.unwrap("")
      let p = list.key_find(params, "p") |> result.try(int.parse) |> result.unwrap(1)
      Ok(Search(q, p))
    }
    _ -> Error(Nil)
  }
}
```

Documentation note: `to_path` should `uri.percent_encode` any user-supplied string. Easy footgun.

## Testing

### `ssr.handle_request` (unit, four cases)

1. Non-GET method → 405 with empty body.
2. `parse` returns `Error(Nil)` → 404 with empty body.
3. `load` returns `Error(response)` → that exact response is returned.
4. `load` returns `Ok(model)` → 200 with `content-type: text/html` and body containing `to_document_string(render(route, model))`.

Pure orchestration: fake the callbacks, assert on the returned `Response`. No mist server needed.

### `ssr.boot_script` (unit)

1. Round-trip: encode a known record, parse the embedded base64 from the rendered script element, `decode_flags` returns the input.
2. Output contains the configured `client_module` path verbatim.
3. Base64 string is properly quoted (no JS string-literal escape issues).

### Cross-target shared module

The load-bearing claim of this design: shared `parse_route` + `view` compiles and runs identically on BEAM and JS. Mirror the wire E2E test fixture pattern:

- Test fixture with `shared/` crate containing a small Route + `parse_route` + `view`.
- Build for both targets, assert no compile errors.
- Run `parse_route` on BEAM with sample `Uri` values; assert results match what JS produces for the same `Uri`.

### Example as integration test

Migrate `examples/ssr_hydration` to `handle_request`. Migration itself validates the design:
- Old `render_ssr` (~30 lines per-route boilerplate) deletes.
- New `handle_request(...)` call (~10 lines) replaces it.
- Hand-rolled browser `router.gleam` deletes; modem replaces it.
- Server still serves `/inc` and `/dec`, flags hydrate, navigation works.

Smoke test: boot the example server, GET `/inc`, assert response body contains the rendered counter HTML and a boot script with valid base64 flags.

### What's not tested

- Browser modem behavior (third-party).
- Lustre rendering (third-party).
- mist HTTP transport (third-party).

## Open questions

None blocking. Convenience helpers (`not_found_response`, `redirect`, `server_error_response`) are deferred to libero-ah9l once real-app patterns emerge.

## Implementation order

1. Add `boot_script` to `libero/ssr` (uses existing `encode_flags`).
2. Add `handle_request` to `libero/ssr` (orchestration only, no new primitives).
3. Add modem to libero's recommended deps; document the browser-routing story.
4. Migrate `examples/ssr_hydration` server to `handle_request`.
5. Migrate `examples/ssr_hydration` client to use modem; delete hand-rolled `router.gleam`.
6. Remove `ssr.document`.
7. Cross-target shared-module test fixture.
8. Make SSR-hydrated SPA the default `libero new` shape. **Remove the existing `--web` flag** (which currently scaffolds SPA-only, no SSR) — the new default subsumes and improves on what it did, so it has no remaining purpose.

   New default `libero new myapp` produces: a one-route Route enum, `parse_route`, `route_to_path` in `shared/`; `ssr.handle_request` wired in `server/main.gleam` with stub `load_page` and `render_page`; modem-based client `init` in `clients/web/`. Working end-to-end out of the box.

   Add `--no-client` opt-out flag for the rare case (server-only project, non-web client coming separately): skips the `clients/web/` crate, omits `ssr.handle_request` and SSR-related imports from `server/main.gleam`, drops `Route`/`view` from `shared/` (keeps Msg + messages). Easy to add the client back later by hand or via a future `libero add web` command.
