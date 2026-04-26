---
# libero-ah9l
title: SSR convenience helpers (not_found, redirect, server_error)
status: todo
type: feature
created_at: 2026-04-26T03:18:27Z
updated_at: 2026-04-26T03:18:27Z
---

Once `libero/ssr.handle_request` lands and we have real apps using it, common patterns will emerge for the `Result(Model, Response)` error path: 404 with a custom body, 302 redirect to a login page, 500 with a generic error page.

Add convenience helpers in `libero/ssr` (or wherever lands) so users don't have to construct these by hand:

- `ssr.not_found_response(body: Element(msg)) -> Response(ResponseData)`
- `ssr.redirect(to: String) -> Response(ResponseData)` (302 by default; permanent variant?)
- `ssr.server_error_response(body: Element(msg)) -> Response(ResponseData)`

Wait until pain emerges from real usage before designing — easier to pick the right ergonomics once we've seen how loaders actually use them.

Depends on libero-nm1e (isomorphic routing) shipping first.
