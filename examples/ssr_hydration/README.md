# SSR hydration example

A counter app that demonstrates server-side rendering (SSR) with client-side hydration and routing.

The server pre-renders the page HTML with real data so the browser displays content immediately. The client then hydrates the pre-rendered DOM (attaches event handlers, connects the WebSocket) and takes over as a normal SPA. This means no loading spinner and no blank page while JavaScript boots.

## What's in here

- `src/ssr_hydration.gleam` - server entry point with per-route SSR rendering
- `src/server/handler.gleam` - handles Increment, Decrement, and GetCounter messages
- `src/ets_store.gleam` - simple ETS-backed integer storage
- `shared/src/shared/messages.gleam` - message types shared between server and client
- `shared/src/shared/views.gleam` - view functions that compile to both Erlang (for SSR) and JavaScript (for the client)
- `clients/web/src/app.gleam` - Lustre client that hydrates the SSR HTML
- `clients/web/src/router.gleam` - browser routing (pushState, popstate)

## How it works

The server uses `libero/ssr` to:

1. Call the handler directly (no network) via `ssr.call` to fetch the current counter value
2. Render the view to HTML on the server using the shared view functions
3. Encode the counter value as flags with `ssr.encode_flags`
4. Send a complete HTML document with `ssr.document`

The client reads the embedded flags in `init`, renders the same view, and Lustre hydrates the existing DOM instead of replacing it.

View functions live in `shared/` so they compile to both Erlang and JavaScript. This is the key to SSR: the same view code runs on both sides.

## Running it

```sh
gleam run -m libero -- build
gleam run
```

Open http://localhost:8080 in your browser. The page renders server-side on first load, then the client takes over.

## Running tests

```sh
gleam test
```

Tests cover the handler logic, SSR HTML output, and the full SSR rendering pipeline.
