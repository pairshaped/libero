---
# libero-ltno
title: Auto-registration on first send
status: completed
type: feature
priority: normal
created_at: 2026-04-16T00:45:47Z
updated_at: 2026-04-16T00:47:45Z
---

Make codec registration automatic by calling register_all() lazily from the generated send stubs, so users never need to call it manually. register_all() becomes idempotent with a JS-side guard.
