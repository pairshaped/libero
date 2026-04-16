---
# libero-u6p9
title: Server push over WebSocket
status: todo
type: feature
priority: normal
created_at: 2026-04-16T01:35:15Z
updated_at: 2026-04-16T02:38:14Z
---

Server push over WebSocket, always available, zero cost if unused.

No special shared type needed. Codegen always generates on_push in client stubs alongside send_to_server. Wire protocol tags frames as response vs push. JS runtime routes push frames to the on_push handler if registered, silently drops them if not. Tree shaking removes on_push from the bundle if never called.

Server side: libero/push is a regular module — import it if you need it. Provides push.join(topic) to subscribe the current WebSocket process to a pg group, and push.broadcast(topic, msg) to send a MsgFromServer to all subscribers.

Three pieces of real work:
1. Wire protocol — add a tag byte to distinguish response vs push frames
2. Client JS runtime (rpc_ffi.mjs) — handle push frames separately from FIFO response queue
3. Server module (libero/push) — pg group management for join/broadcast, ~50 lines of Erlang FFI

No conditional codegen, no PushedFromServer type, no convention signal. Push is just there — use it or ignore it.
