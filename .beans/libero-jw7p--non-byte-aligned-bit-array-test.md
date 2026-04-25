---
# libero-jw7p
title: 'Wire E2E: non-byte-aligned bit_array test case'
status: blocked
type: test
created_at: 2026-04-25T20:00:00Z
updated_at: 2026-04-25T20:00:00Z
---

Gleam's type system has no surface-level syntax for non-byte-aligned bit arrays, so we can't write a handler that echoes `BitArray(3)` (3 bits, not 3 bytes). ETF codec supports non-byte-aligned bit strings at the Erlang level, but there's no way to express the input or output type in Gleam handler signatures.

Blocked on Gleam adding bit_array literal syntax or a BitArray constructor that accepts non-byte-aligned sizes.
