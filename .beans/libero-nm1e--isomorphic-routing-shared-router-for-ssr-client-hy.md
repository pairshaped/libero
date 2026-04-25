---
# libero-nm1e
title: 'Isomorphic routing: shared router for SSR + client hydration'
status: todo
type: feature
created_at: 2026-04-17T05:25:39Z
updated_at: 2026-04-17T05:25:39Z
---

Design a shared routing layer that maps URLs to data requirements and views, running on both BEAM (SSR) and JS (client). Any URL can be deep-linked with server-rendered content that hydrates seamlessly.

Key pieces:
- Shared router: URL -> Route (cross-target)
- Per-route data requirements: Route -> list of ssr.call messages to fetch
- Per-route views: Route -> view function to render
- Server runs router on any request, fetches data, renders, serves HTML
- Client runs same router after hydration for subsequent navigation

Builds on libero/ssr helpers (call, encode_flags, decode_flags, document).
