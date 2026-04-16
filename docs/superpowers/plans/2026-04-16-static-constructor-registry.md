# Static Constructor Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move framework constructor registrations (Ok, Error, Some, None, DecodeError, list/dict helpers) from dynamic imports in `rpc_ffi.mjs` into the generated `rpc_register_ffi.mjs`, eliminating circular deps, try/catch blocks, and fragile relative paths.

**Architecture:** The codegen already generates `rpc_register_ffi.mjs` with app-specific constructor registrations. We extend it to also emit static imports for universal framework types (prelude, error, wire, option, dict). Then we strip the dynamic import bootstrap block from `rpc_ffi.mjs` and add a `setGleamCustomType` export so the generated code can set it. All framework types are always emitted (no conditional detection needed — they're cheap and universal).

**Tech Stack:** Gleam (codegen), JavaScript (rpc_ffi.mjs), gleeunit (tests)

---

### File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/libero/rpc_ffi.mjs` | Modify (lines 50, 682-752) | Remove dynamic import bootstrap block; add `setGleamCustomType` export |
| `src/libero/codegen.gleam` | Modify (`write_register_ffi`, lines 374-468) | Emit framework type static imports and registration calls |
| `test/libero/codegen_test.gleam` | Modify | Add test verifying framework types in generated register FFI |
| `examples/todos/client/src/client/generated/libero/rpc_register_ffi.mjs` | Regenerated | Verify output includes framework registrations |

---

### Task 1: Add `setGleamCustomType` export to `rpc_ffi.mjs`

**Files:**
- Modify: `src/libero/rpc_ffi.mjs:50-64`

- [ ] **Step 1: Add the setter function**

After the existing `setDictFromList` export (line 62-64), add:

```javascript
export function setGleamCustomType(ctor) {
  GleamCustomType = ctor;
}
```

This lets the generated register file set `GleamCustomType` without importing the prelude directly from `rpc_ffi.mjs`.

- [ ] **Step 2: Verify no tests break**

Run: `gleam test`
Expected: All existing tests pass (this is purely additive).

- [ ] **Step 3: Commit**

```bash
git add src/libero/rpc_ffi.mjs
git commit -m "Add setGleamCustomType export to rpc_ffi.mjs"
```

---

### Task 2: Remove dynamic import bootstrap from `rpc_ffi.mjs`

**Files:**
- Modify: `src/libero/rpc_ffi.mjs:682-752`

- [ ] **Step 1: Delete the entire auto-wire block**

Remove lines 682-752 (the comment block and all five try/catch + fire-and-forget import blocks). This is the section starting with `// ---------- Auto-wire Gleam prelude + libero framework types ----------` and ending just before `// ---------- WebSocket ----------`.

The block to remove:

```javascript
// ---------- Auto-wire Gleam prelude + libero framework types ----------
// ... (everything through line 752)
```

- [ ] **Step 2: Verify no tests break**

Run: `gleam test`
Expected: All existing tests pass. The removed code only runs in browser JS context, not in Gleam/Erlang tests.

- [ ] **Step 3: Commit**

```bash
git add src/libero/rpc_ffi.mjs
git commit -m "Remove dynamic import bootstrap from rpc_ffi.mjs

Framework constructor registration moves to the generated
rpc_register_ffi.mjs in the next commit."
```

---

### Task 3: Extend `write_register_ffi` to emit framework registrations

**Files:**
- Modify: `src/libero/codegen.gleam:374-468` (the `write_register_ffi` function)

- [ ] **Step 1: Write a failing test**

Add to `test/libero/codegen_test.gleam`:

```gleam
pub fn register_ffi_contains_framework_types_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(
      shared_src: "examples/todos/shared/src/shared",
    )
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let config =
    config.build_config(
      ws_mode: config.WsFullUrl(url: "ws://localhost:8080/ws"),
      namespace: option.None,
      client_root: "build/.test_register_ffi",
      shared_root: Ok("../shared"),
      server_root: Ok("."),
    )
  let assert Ok(Nil) =
    codegen.write_register(config: config, discovered: discovered)
  let assert Ok(content) =
    simplifile.read(
      "build/.test_register_ffi/src/client/generated/libero/rpc_register_ffi.mjs",
    )

  // Must import framework setter functions
  let assert True =
    string.contains(content, "setListCtors")
  let assert True =
    string.contains(content, "setDictFromList")
  let assert True =
    string.contains(content, "setGleamCustomType")

  // Must import from gleam prelude
  let assert True =
    string.contains(content, "gleam.mjs")
  // Must import from libero/wire (DecodeError)
  let assert True =
    string.contains(content, "wire.mjs")
  // Must import from libero/error
  let assert True =
    string.contains(content, "error.mjs")
  // Must import from gleam_stdlib/gleam/option
  let assert True =
    string.contains(content, "option.mjs")
  // Must import from gleam_stdlib/gleam/dict
  let assert True =
    string.contains(content, "dict.mjs")

  // Must register Ok/Error
  let assert True =
    string.contains(content, "registerConstructor(\"ok\"")
  let assert True =
    string.contains(content, "registerConstructor(\"error\"")
  // Must register Some/None
  let assert True =
    string.contains(content, "registerConstructor(\"some\"")
  let assert True =
    string.contains(content, "registerConstructor(\"none\"")
  // Must register DecodeError
  let assert True =
    string.contains(content, "registerConstructor(\"decode_error\"")
  // Must register framework error variants
  let assert True =
    string.contains(content, "registerConstructor(\"app_error\"")

  // Cleanup
  let assert Ok(Nil) =
    simplifile.delete_all(["build/.test_register_ffi"])
}
```

Add these imports at the top of the test file (if not already present):

```gleam
import gleam/option
import libero/config
import libero/walker
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test -- --only register_ffi_contains_framework_types`
Expected: FAIL — generated file doesn't contain framework registrations yet.

- [ ] **Step 3: Implement framework registration in `write_register_ffi`**

In `src/libero/codegen.gleam`, modify the `write_register_ffi` function. The `libero_import` line (398-400) currently imports only `registerConstructor` and `registerFloatFields`. Expand it to also import `setListCtors`, `setDictFromList`, and `setGleamCustomType`.

Replace the current `libero_import` (lines 397-400):

```gleam
  let libero_import =
    "import { registerConstructor, registerFloatFields } from \""
    <> prefix
    <> "libero/libero/rpc_ffi.mjs\";"
```

With:

```gleam
  let libero_import =
    "import { registerConstructor, registerFloatFields, setListCtors, setDictFromList, setGleamCustomType } from \""
    <> prefix
    <> "libero/libero/rpc_ffi.mjs\";"
```

Then add the framework imports and registration calls. Insert these after `libero_import` and before the `module_imports`:

```gleam
  // Static imports for universal framework types.
  let framework_imports =
    [
      "import { Ok, Error, CustomType, Empty, NonEmpty } from \""
        <> prefix
        <> "gleam.mjs\";",
      "import { DecodeError } from \""
        <> prefix
        <> "libero/libero/wire.mjs\";",
      "import { AppError, MalformedRequest, UnknownFunction, InternalError } from \""
        <> prefix
        <> "libero/libero/error.mjs\";",
      "import { Some, None } from \""
        <> prefix
        <> "gleam_stdlib/gleam/option.mjs\";",
      "import { from_list as dictFromList } from \""
        <> prefix
        <> "gleam_stdlib/gleam/dict.mjs\";",
    ]
  let framework_register_calls =
    [
      "  // Framework types",
      "  setGleamCustomType(CustomType);",
      "  setListCtors(Empty, NonEmpty);",
      "  setDictFromList(dictFromList);",
      "  registerConstructor(\"ok\", Ok);",
      "  registerConstructor(\"error\", Error);",
      "  registerConstructor(\"some\", Some);",
      "  registerConstructor(\"none\", None);",
      "  registerConstructor(\"decode_error\", DecodeError);",
      "  registerConstructor(\"app_error\", AppError);",
      "  registerConstructor(\"malformed_request\", MalformedRequest);",
      "  registerConstructor(\"unknown_function\", UnknownFunction);",
      "  registerConstructor(\"internal_error\", InternalError);",
    ]
```

Then update the `content` template to include them. Replace the current content assembly (lines 446-465):

```gleam
  let all_calls =
    list.flatten([framework_register_calls, register_calls, float_field_calls])
  let content = "// Code generated by libero. DO NOT EDIT.
//
// Registers framework and application custom types for wire codec
// reconstruction. Framework types (Ok, Error, Some, None, etc.) are
// always included. Application types are discovered by walking the
// MsgFromClient/MsgFromServer type graphs at generation time.
//
// Called automatically by generated send functions. Idempotent -
// safe to call multiple times (only runs registration once).

" <> libero_import <> "\n" <> string.join(framework_imports, "\n") <> "\n" <> string.join(
      module_imports,
      "\n",
    ) <> "

let registered = false;

export function registerAll() {
  if (registered) return;
  registered = true;
" <> string.join(
      all_calls,
      "\n",
    ) <> "\n}\n"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test`
Expected: All tests pass, including the new `register_ffi_contains_framework_types_test`.

- [ ] **Step 5: Commit**

```bash
git add src/libero/codegen.gleam test/libero/codegen_test.gleam
git commit -m "Emit framework constructor registrations in generated rpc_register_ffi.mjs

Moves Ok, Error, Some, None, DecodeError, list/dict helpers, and
GleamCustomType from dynamic imports in rpc_ffi.mjs into the
generated register file as static imports. Eliminates circular
dependency workarounds, try/catch blocks, and fragile paths into
gleam_stdlib internals."
```

---

### Task 4: Regenerate the todos example and verify

**Files:**
- Regenerated: `examples/todos/client/src/client/generated/libero/rpc_register_ffi.mjs`

- [ ] **Step 1: Run the codegen for the todos example**

Run from the `examples/todos/server` directory:

```bash
cd examples/todos/server && gleam run -m libero -- --ws-url=ws://localhost:8080/ws --shared=../shared --server=.
```

- [ ] **Step 2: Inspect the generated file**

Read `examples/todos/client/src/client/generated/libero/rpc_register_ffi.mjs` and verify it contains:
- Static imports from `gleam.mjs`, `wire.mjs`, `error.mjs`, `option.mjs`, `dict.mjs`
- Framework registration calls (Ok, Error, Some, None, DecodeError, etc.)
- `setListCtors`, `setDictFromList`, `setGleamCustomType` calls
- App-specific registrations (Todo, TodoParams, etc.) still present

- [ ] **Step 3: Commit the regenerated example**

```bash
git add examples/todos/client/src/client/generated/libero/rpc_register_ffi.mjs
git commit -m "Regenerate todos example with static framework registrations"
```

---

### Task 5: Final verification

- [ ] **Step 1: Run full test suite**

Run: `gleam test`
Expected: All tests pass.

- [ ] **Step 2: Verify rpc_ffi.mjs no longer has dynamic imports**

Grep `rpc_ffi.mjs` for `await import` and `import(` — should return zero matches (excluding regular `import` statements at the top of the file, if any).
