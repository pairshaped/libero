---
# libero-rxj9
title: 'I1: split codegen.gleam (won''t do — see body)'
status: scrapped
type: task
created_at: 2026-04-25T21:57:01Z
updated_at: 2026-04-25T21:57:01Z
---

Code review I1 suggested splitting `src/libero/codegen.gleam` (~2000
lines, 29 pub fn) into 4-5 focused modules. **Decision: won't do.**

Rationale:
- None of the actual bugs we've fixed (C1 eager-guard recursion, C2
  transport-failure typing, C3 dispatch unknown-variant, j18s
  path-prefix) would have been prevented by smaller files. They were
  logic bugs, not navigation bugs.
- Splitting would force ~10 internal helpers (handler_alias,
  to_pascal_case, parse_result_type, split_top_level_commas,
  extract_module_qualifiers, format_*, etc.) to become `pub` so they
  can be shared across files. Gleam has no package-private visibility,
  so this leaks internals into the public API.
- Gleam compiles per-package, not per-file. No build speedup.
- 2000 lines is normal for a codegen module — templating is verbose.
- LSP/grep find functions just as well across 2000 lines as 500.
- Splitting would make I3 (structural ADT refactor) harder by spreading
  the change across more files.

If a real navigation problem emerges (e.g. specific functions become
hard to find or the file genuinely makes refactors painful), revisit
then with concrete evidence. Until then, the cost outweighs the benefit.
