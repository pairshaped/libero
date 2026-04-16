---
# libero-77nq
title: Version mismatch detection
status: todo
type: feature
created_at: 2026-04-16T00:45:06Z
updated_at: 2026-04-16T00:45:06Z
---

Detect client/server version drift and trigger a client reload instead of silent decode failures. Inspired by elm-webapp's ClientServerVersionMismatch pattern. The server could embed a build hash in the WebSocket handshake or first response frame; the client checks it against its own hash and forces a page reload if they diverge.
