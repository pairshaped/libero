# Typed Decoders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace libero's JS-client global constructor registry with typed, per-type decoders generated from the discovered type graph. Eliminates the cross-module variant-atom collision bug (e.g. `line_item.Paid` vs `order.Paid`).

**Architecture:** Walker grows a richer `DiscoveredType` graph (each type knows its variants and each variant's field types). Codegen emits one JS decoder function per discovered type, composing via generic combinators for `List`/`Option`/`Result`/`Dict`/tuples. The global `Map<atom, Ctor>` registry goes away. Wire format is unchanged.

**Tech Stack:** Gleam (codegen + walker + tests), JS (generated decoders + static prelude), gleeunit test framework.

**Reference spec:** `docs/superpowers/specs/2026-04-17-typed-decoders-design.md`.

---

## Context

- Libero's client-side decoder currently uses `registry: Map<atom_name, Constructor>` populated by a generated `rpc_register_ffi.mjs`. Same atoms across modules collide; last writer wins.
- The Erlang server path is fine and stays unchanged. All changes are codegen + JS client.
- This lands on libero `master` without a version bump; v4.0 work (separate branch) will absorb it later.
- Existing walker tests live at `test/libero/type_walker_test.gleam` and exercise the `examples/todos/` shared modules. They stay green as the walker grows; new tests cover the new output shape.
- `examples/todos/` and `examples/todos-hydration/` are the ground-truth end-to-end suites. They must regenerate cleanly with the new codegen.

## File inventory

### Created

- `src/libero/decoders_prelude.mjs` — static JS module with primitive + combinator decoders (`decode_int`, `decode_list_of`, `decode_option_of`, `decode_result_of`, `decode_dict_of`, `decode_tuple_of`, `DecodeError` class).
- `src/libero/decoders_prelude_stub.gleam` — Gleam shim that exports the prelude path so codegen can reference it by package-relative import.
- `test/fixtures/collision/shared/a.gleam`, `test/fixtures/collision/shared/b.gleam`, `test/fixtures/collision/shared/messages.gleam` — fixture modules for the regression test.
- `test/libero/typed_decoder_codegen_test.gleam` — golden tests for `write_decoders_ffi`.
- `test/libero/collision_regression_test.gleam` — the collision regression test.

### Modified

- `src/libero/walker.gleam` — emit richer `DiscoveredType` graph.
- `src/libero/codegen.gleam` — add `write_decoders_ffi` and `write_decoders_gleam`; rewire per-RPC decoders to call typed decoders; remove `write_register_ffi` and `write_register_gleam`.
- `src/libero/rpc_ffi.mjs` — remove global registry and the atom-to-constructor dispatch path in `decodeTerm`.
- `src/libero/wire.gleam` — the `coerce` entry point calls the generated `decode_msg_from_server` instead of the generic ETF-to-constructed-value path.
- `src/libero.gleam` — update the codegen pipeline to call the new `write_decoders_*` functions in place of the old `write_register_*`.
- `examples/todos/*` generated files — regenerate under new codegen.
- `examples/todos-hydration/*` generated files — regenerate under new codegen.
- `README.md` — document the new decoder surface.
- `LLM_USERS.md` — update client-side decoder section.

### Deleted

- Old registry generation: removed from `codegen.gleam`. Old generated `rpc_register.gleam` / `rpc_register_ffi.mjs` disappear from example outputs on regeneration.

---

## Task 1: Walker — discover field types per variant

**Goal:** Enhance `DiscoveredVariant` to carry `fields: List(FieldType)`. Introduce the `FieldType` union. Keep the existing flat `List(DiscoveredVariant)` return type for now (Task 2 upgrades to `DiscoveredType` tree).

**Files:**
- Modify: `src/libero/walker.gleam`
- Modify: `test/libero/type_walker_test.gleam` (add assertions on new `fields`)

- [ ] **Step 1.1: Add the `FieldType` union to walker**

In `src/libero/walker.gleam`, above the existing `DiscoveredVariant` type, add:

```gleam
pub type FieldType {
  UserType(module_path: String, type_name: String, args: List(FieldType))
  ListOf(element: FieldType)
  OptionOf(inner: FieldType)
  ResultOf(ok: FieldType, err: FieldType)
  DictOf(key: FieldType, value: FieldType)
  TupleOf(elements: List(FieldType))
  IntField
  FloatField
  StringField
  BoolField
  BitArrayField
  TypeVar(name: String)
}
```

- [ ] **Step 1.2: Extend `DiscoveredVariant`**

Change the existing type to:

```gleam
pub type DiscoveredVariant {
  DiscoveredVariant(
    module_path: String,
    variant_name: String,
    atom_name: String,
    float_field_indices: List(Int),
    fields: List(FieldType),
  )
}
```

- [ ] **Step 1.3: Add `glance` field-type parsing helper**

Below the existing `collect_variant_field_refs` function, add:

```gleam
/// Convert a glance `Type` into a resolved `FieldType`.
/// Resolver handles unqualified (`Status`) and aliased (`line_item.Status`) refs.
fn field_type_of(
  t: glance.Type,
  resolver: TypeResolver,
  current_module: String,
) -> FieldType {
  case t {
    glance.NamedType(name: "Int", ..) -> IntField
    glance.NamedType(name: "Float", ..) -> FloatField
    glance.NamedType(name: "String", ..) -> StringField
    glance.NamedType(name: "Bool", ..) -> BoolField
    glance.NamedType(name: "BitArray", ..) -> BitArrayField

    glance.NamedType(name: "List", parameters: [inner]) ->
      ListOf(field_type_of(inner, resolver, current_module))
    glance.NamedType(name: "Option", parameters: [inner]) ->
      OptionOf(field_type_of(inner, resolver, current_module))
    glance.NamedType(name: "Result", parameters: [ok, err]) ->
      ResultOf(
        ok: field_type_of(ok, resolver, current_module),
        err: field_type_of(err, resolver, current_module),
      )
    glance.NamedType(name: "Dict", parameters: [k, v]) ->
      DictOf(
        key: field_type_of(k, resolver, current_module),
        value: field_type_of(v, resolver, current_module),
      )

    glance.TupleType(elems) ->
      TupleOf(list.map(elems, field_type_of(_, resolver, current_module)))

    glance.VariableType(name) -> TypeVar(name: name)

    glance.NamedType(name, module, params) -> {
      let resolved_module = case module {
        option.Some(alias) ->
          dict.get(resolver.aliased, alias) |> result.unwrap(alias)
        option.None ->
          dict.get(resolver.unqualified, name) |> result.unwrap(current_module)
      }
      UserType(
        module_path: resolved_module,
        type_name: name,
        args: list.map(params, field_type_of(_, resolver, current_module)),
      )
    }

    _ -> UserType(module_path: current_module, type_name: "Unknown", args: [])
  }
}
```

Note the glance constructor names (`NamedType`, `TupleType`, `VariableType`) must match the current glance version. Cross-check by running `gleam test` after the edit; the compiler will flag any mismatch. If a constructor name differs, look at `collect_variant_field_refs` for the correct names and adjust.

- [ ] **Step 1.4: Populate `fields` in `process_type_ast`**

In `src/libero/walker.gleam`, the fold over `custom_type.variants` builds a `DiscoveredVariant`. Add field extraction:

Before (inside the fold):

```gleam
let disc_item =
  DiscoveredVariant(
    module_path: module_path,
    variant_name: variant.name,
    atom_name: to_snake_case(variant.name),
    float_field_indices: float_indices,
  )
```

After:

```gleam
let fields =
  list.map(variant.fields, fn(f) {
    field_type_of(f.item, resolver, module_path)
  })
let disc_item =
  DiscoveredVariant(
    module_path: module_path,
    variant_name: variant.name,
    atom_name: to_snake_case(variant.name),
    float_field_indices: float_indices,
    fields: fields,
  )
```

- [ ] **Step 1.5: Add walker test — primitive fields populated**

Append to `test/libero/type_walker_test.gleam`:

```gleam
pub fn walk_populates_primitive_field_types_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )

  let assert Ok(create) =
    list.find(discovered, fn(v) { v.variant_name == "Create" })
  // The "Create" message carries `text: String` — verify the walker captured it.
  let assert [walker.StringField] = create.fields
}
```

- [ ] **Step 1.6: Add walker test — user-type field resolved**

Continuing the test file, find an RPC variant that references a shared user type (e.g. `Toggle` references a `Todo` or similar). Adjust the assertion to the actual shape of the todos example. Read `examples/todos/shared/src/shared/todos.gleam` first to know which RPCs carry which fields, then write the assertion:

```gleam
pub fn walk_resolves_user_type_in_field_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(discovered) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )

  // Find a Todo-carrying variant. TodosLoaded carries Result(List(Todo), String).
  let assert Ok(loaded) =
    list.find(discovered, fn(v) { v.variant_name == "TodosLoaded" })
  let assert [walker.ResultOf(ok: walker.ListOf(walker.UserType(
    module_path: "shared/todos",
    type_name: "Todo",
    args: [],
  )), err: walker.StringField)] = loaded.fields
}
```

If the todos example doesn't have exactly this shape, read `shared/todos.gleam` and update the assertion to match the real MsgFromServer variant.

- [ ] **Step 1.7: Build and test**

Run: `gleam test`

Expected: new tests pass, existing tests still pass.

- [ ] **Step 1.8: Commit**

```bash
git add src/libero/walker.gleam test/libero/type_walker_test.gleam
git commit -m "Populate field types on DiscoveredVariant"
```

---

## Task 2: Walker — produce `DiscoveredType` graph

**Goal:** Wrap variants in a `DiscoveredType` record. Change the public return type to `List(DiscoveredType)`. Update codegen callers to iterate types-then-variants rather than a flat list.

**Files:**
- Modify: `src/libero/walker.gleam`
- Modify: `src/libero/codegen.gleam` (call-site updates)
- Modify: `test/libero/type_walker_test.gleam`

- [ ] **Step 2.1: Introduce `DiscoveredType`**

Above `DiscoveredVariant`:

```gleam
pub type DiscoveredType {
  DiscoveredType(
    module_path: String,
    type_name: String,
    type_params: List(String),
    variants: List(DiscoveredVariant),
  )
}
```

- [ ] **Step 2.2: Rework `process_type_ast` to emit a single `DiscoveredType`**

Replace the variant-level fold's `disc_item` append with a single type-level record. The function currently folds over variants and appends each one. Change to: collect all variants, then construct one `DiscoveredType`.

Target shape inside `process_type_ast`:

```gleam
Ok(ct_def) -> {
  let custom_type = ct_def.definition
  let resolver = build_type_resolver(ast.imports)

  let variants =
    list.map(custom_type.variants, fn(variant) {
      let float_indices = detect_float_fields(variant.fields)
      let fields =
        list.map(variant.fields, fn(f) {
          field_type_of(f.item, resolver, module_path)
        })
      DiscoveredVariant(
        module_path: module_path,
        variant_name: variant.name,
        atom_name: to_snake_case(variant.name),
        float_field_indices: float_indices,
        fields: fields,
      )
    })

  let type_params =
    list.map(custom_type.parameters, fn(p) { p })
  // (If glance's parameter shape differs, adapt — it's typically List(String).)

  let disc_type =
    DiscoveredType(
      module_path: module_path,
      type_name: type_name,
      type_params: type_params,
      variants: variants,
    )

  // Enqueue referenced types exactly as before
  let new_queue_items =
    list.flat_map(custom_type.variants, fn(variant) {
      collect_variant_field_refs(
        variant: variant,
        resolver: resolver,
        current_module: module_path,
        visited: state.visited,
      )
    })

  do_walk(
    WalkerState(
      ..state,
      queue: list.append(state.queue, new_queue_items),
      discovered: [disc_type, ..state.discovered],
    ),
  )
}
```

Change the `discovered` field on `WalkerState` from `List(DiscoveredVariant)` to `List(DiscoveredType)`. Update the public return type on `walk_message_registry_types` to match.

- [ ] **Step 2.3: Update callers in codegen**

`src/libero/codegen.gleam` has call sites that iterate the flat `List(DiscoveredVariant)`. Grep:

```
grep -n "discovered" src/libero/codegen.gleam | head -30
```

Every use site that expects variants directly needs to flatten: `list.flat_map(discovered, fn(t) { t.variants })`. For example, `write_register_ffi` builds a list of register calls from variants — change its input to `list.flat_map(types, fn(t) { t.variants })`.

This keeps the old `write_register_ffi` working during the transition; we'll delete it in Task 9.

- [ ] **Step 2.4: Update walker tests**

In `test/libero/type_walker_test.gleam`, the existing tests pull `discovered` and iterate variants directly. Wrap with `list.flat_map(discovered, fn(t) { t.variants })` anywhere they touch variants. The new `walk_populates_primitive_field_types_test` and `walk_resolves_user_type_in_field_test` from Task 1 similarly need to look up variants through types.

Example adjustment:

```gleam
pub fn walk_discovers_toserver_variants_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let variants = list.flat_map(types, fn(t) { t.variants })
  let names = list.map(variants, fn(v) { v.variant_name })
  let assert True = list.contains(names, "Create")
  // ...
}
```

- [ ] **Step 2.5: Add test — type-level grouping**

New test:

```gleam
pub fn walk_groups_variants_under_type_test() {
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )
  let assert Ok(msg_from_client) =
    list.find(types, fn(t) { t.type_name == "MsgFromClient" })
  // Multiple variants all grouped under the one type
  let variant_count = list.length(msg_from_client.variants)
  let assert True = variant_count > 1
}
```

- [ ] **Step 2.6: Build and test**

Run: `gleam test`

Expected: all tests pass. If a test fails due to the flat-to-tree change, update it.

- [ ] **Step 2.7: Commit**

```bash
git add src/libero/walker.gleam src/libero/codegen.gleam test/libero/type_walker_test.gleam
git commit -m "Group variants under DiscoveredType"
```

---

## Task 3: Decoders prelude — static JS library

**Goal:** Create `src/libero/decoders_prelude.mjs` exporting primitive and combinator decoders. This is static content libero ships; consumers import from it.

**Files:**
- Create: `src/libero/decoders_prelude.mjs`
- Create: `test/js/decoders_prelude_test.mjs`

- [ ] **Step 3.1: Write the prelude**

Create `src/libero/decoders_prelude.mjs`:

```javascript
// Static library of primitive + combinator decoders used by the generated
// rpc_decoders_ffi.mjs. Consumers should not import from here directly; the
// generator wires imports relative to the generated file's location.

import { Ok, Error as ResultError, List as GleamList } from "../gleam_stdlib/gleam.mjs";
import { None, Some } from "../gleam_stdlib/gleam/option.mjs";

export class DecodeError extends Error {
  constructor(message) {
    super(message);
    this.name = "DecodeError";
  }
}

// --- primitive decoders (mostly identity, but coerce what libero's ETF decoder produces) ---

export const decode_int = (term) => {
  if (typeof term !== "number") {
    throw new DecodeError("expected Int, got " + typeof term);
  }
  return term;
};

export const decode_float = (term) => {
  if (typeof term !== "number") {
    throw new DecodeError("expected Float, got " + typeof term);
  }
  return term;
};

export const decode_string = (term) => {
  if (typeof term !== "string") {
    throw new DecodeError("expected String, got " + typeof term);
  }
  return term;
};

export const decode_bool = (term) => {
  if (term === true || term === "true") return true;
  if (term === false || term === "false") return false;
  throw new DecodeError("expected Bool, got " + String(term));
};

export const decode_bit_array = (term) => {
  // libero's ETF decoder produces a BitArray-compatible value; pass through.
  return term;
};

// --- generic combinators ---

export function decode_list_of(elementDecoder, term) {
  // libero's ETF decoder produces a native JS array for Gleam lists.
  if (!Array.isArray(term)) {
    throw new DecodeError("expected List, got " + typeof term);
  }
  return GleamList.fromArray(term.map(elementDecoder));
}

export function decode_option_of(innerDecoder, term) {
  if (term === "none") return new None();
  if (Array.isArray(term) && term[0] === "some") {
    return new Some(innerDecoder(term[1]));
  }
  throw new DecodeError("expected Option, got " + String(term));
}

export function decode_result_of(okDecoder, errDecoder, term) {
  if (Array.isArray(term) && term[0] === "ok") {
    return new Ok(okDecoder(term[1]));
  }
  if (Array.isArray(term) && term[0] === "error") {
    return new ResultError(errDecoder(term[1]));
  }
  throw new DecodeError("expected Result, got " + String(term));
}

export function decode_dict_of(keyDecoder, valueDecoder, term) {
  // libero's ETF decoder produces a gleam/dict.Dict via a constructor.
  // For now, return a fresh Dict from the raw key/value pairs.
  // TODO: once libero's ETF encoder for Dict is locked in, wire this to
  // the exact producer shape.
  if (!term || typeof term.toArray !== "function") {
    throw new DecodeError("expected Dict, got " + String(term));
  }
  const entries = term
    .toArray()
    .map(([k, v]) => [keyDecoder(k), valueDecoder(v)]);
  // Rebuild the Dict from entries — use gleam/dict.from_list via a static helper
  // that libero's runtime already knows about.
  return dictFromEntries(entries);
}

export function decode_tuple_of(elementDecoders, term) {
  if (!Array.isArray(term) || term.length !== elementDecoders.length) {
    throw new DecodeError("tuple arity mismatch");
  }
  return elementDecoders.map((decoder, i) => decoder(term[i]));
}

// --- internal helper kept exported for the generator ---

let dictFromEntriesImpl = null;
export function setDictFromEntries(fn) {
  dictFromEntriesImpl = fn;
}
function dictFromEntries(entries) {
  if (!dictFromEntriesImpl) {
    throw new DecodeError("dict_from_entries not wired; call setDictFromEntries");
  }
  return dictFromEntriesImpl(entries);
}
```

Import paths at the top are placeholders — adjust them based on where libero's existing `rpc_ffi.mjs` already imports Gleam stdlib `Ok`/`None`/etc. Grep `import.*gleam` in `src/libero/rpc_ffi.mjs` to find the canonical relative paths, then use the same in the prelude.

- [ ] **Step 3.2: Write a unit test file for the prelude**

Create `test/js/decoders_prelude_test.mjs`:

```javascript
import {
  decode_int,
  decode_string,
  decode_bool,
  decode_list_of,
  decode_option_of,
  decode_result_of,
  DecodeError,
} from "../../src/libero/decoders_prelude.mjs";
import { None, Some } from "../../build/dev/javascript/gleam_stdlib/gleam/option.mjs";

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${expected}, got ${actual}`);
  }
}

function assertThrows(fn, label) {
  try {
    fn();
  } catch (e) {
    if (e instanceof DecodeError) return;
    throw new Error(`${label}: expected DecodeError, got ${e}`);
  }
  throw new Error(`${label}: expected throw, got nothing`);
}

assertEqual(decode_int(5), 5, "decode_int ok");
assertThrows(() => decode_int("x"), "decode_int throws on string");

assertEqual(decode_string("foo"), "foo", "decode_string ok");
assertThrows(() => decode_string(5), "decode_string throws on number");

assertEqual(decode_bool(true), true, "decode_bool true ok");
assertEqual(decode_bool("false"), false, "decode_bool atom-false ok");

const opt_some = decode_option_of(decode_string, ["some", "x"]);
if (!(opt_some instanceof Some)) throw new Error("decode_option_of Some instance");

const opt_none = decode_option_of(decode_string, "none");
if (!(opt_none instanceof None)) throw new Error("decode_option_of None instance");

console.log("prelude tests passed");
```

- [ ] **Step 3.3: Add an npm/deno test runner hook**

Libero currently tests JS via a single file exercised from Gleam. Simplest integration: extend the existing JS test (`test/js/etf_codec_test.mjs`) or add a new top-level JS test runner. Check how `etf_codec_test.mjs` is invoked — likely via a gleam test that shells out to node.

For this step, simply run the prelude test directly: `node test/js/decoders_prelude_test.mjs`. Expected output: `prelude tests passed`.

If it fails because of import path issues, fix them before moving on — the generator will emit similar imports.

- [ ] **Step 3.4: Commit**

```bash
git add src/libero/decoders_prelude.mjs test/js/decoders_prelude_test.mjs
git commit -m "Add static decoders prelude (primitives + combinators)"
```

---

## Task 4: Codegen — `write_decoders_ffi`

**Goal:** New codegen function that emits a per-consumer `rpc_decoders_ffi.mjs` from the `DiscoveredType` graph.

**Files:**
- Modify: `src/libero/codegen.gleam`
- Create: `test/libero/typed_decoder_codegen_test.gleam`

- [ ] **Step 4.1: Add the emitter function**

Inside `src/libero/codegen.gleam`, after `write_register_ffi`, add:

```gleam
/// Emit a JS file defining one decoder function per discovered type and
/// a `decode_msg_from_server` entry point.
pub fn write_decoders_ffi(
  config config: Config,
  discovered discovered: List(DiscoveredType),
) -> Result(Nil, GenError) {
  let imports = emit_decoder_imports(discovered, config)
  let type_decoders =
    list.map(discovered, fn(t) { emit_type_decoder(t, discovered) })
  let entry =
    emit_msg_from_server_decoder(discovered)
  let body =
    string.join(
      [imports, string.join(type_decoders, "\n\n"), entry],
      "\n\n",
    )
  let output = config.decoders_ffi_output
  // ... (use the same file-writing helper as write_register_ffi uses)
}
```

The helpers `emit_decoder_imports`, `emit_type_decoder`, and `emit_msg_from_server_decoder` are private functions that construct the JS source. Keep them small (~30 lines each). For the file-writing wrapper, mirror the pattern of the existing `write_register_ffi` — it already handles `simplifile.write`, directory creation, and `GenError` wrapping.

- [ ] **Step 4.2: Implement `emit_type_decoder`**

For each `DiscoveredType`, emit either an enum decoder (no-field variants) or a record decoder (single variant or multi-variant with fields).

```gleam
fn emit_type_decoder(t: DiscoveredType, all: List(DiscoveredType)) -> String {
  let fn_name = decoder_fn_name(t.module_path, t.type_name)
  let body = case t.variants {
    [single] ->
      // Single-variant record: positional field extraction
      emit_record_decoder(single, all)
    variants ->
      case all_variants_zero_arity(variants) {
        True -> emit_enum_decoder(variants)
        False -> emit_tagged_union_decoder(variants, all)
      }
  }
  "export function " <> fn_name <> "(term) {\n"
  <> body
  <> "\n}"
}
```

Where `decoder_fn_name` is:

```gleam
fn decoder_fn_name(module_path: String, type_name: String) -> String {
  "decode_"
  <> string.replace(module_path, "/", "_")
  <> "_"
  <> to_snake_case(type_name)
}
```

- [ ] **Step 4.3: Implement `emit_enum_decoder` and `emit_record_decoder`**

```gleam
fn emit_enum_decoder(variants: List(DiscoveredVariant)) -> String {
  let cases =
    list.map(variants, fn(v) {
      "  if (term === \""
      <> v.atom_name
      <> "\") return new _m_"
      <> module_alias(v.module_path)
      <> "."
      <> v.variant_name
      <> "();"
    })
  string.join(cases, "\n")
  <> "\n  throw new DecodeError(\"unknown variant: \" + term);"
}

fn emit_record_decoder(
  variant: DiscoveredVariant,
  all: List(DiscoveredType),
) -> String {
  let field_lines =
    list.index_map(variant.fields, fn(ft, i) {
      // Skip index 0 — that's the constructor atom tag; fields start at term[1].
      "    " <> field_decoder_call(ft, "term[" <> int.to_string(i + 1) <> "]", all)
    })
  "  return new _m_"
  <> module_alias(variant.module_path)
  <> "."
  <> variant.variant_name
  <> "(\n"
  <> string.join(field_lines, ",\n")
  <> "\n  );"
}
```

`field_decoder_call(ft, term_expr, all)` produces the JS snippet that decodes `term_expr` for `ft`. See next step.

- [ ] **Step 4.4: Implement `field_decoder_call`**

```gleam
fn field_decoder_call(
  ft: FieldType,
  term_expr: String,
  all: List(DiscoveredType),
) -> String {
  case ft {
    IntField -> "decode_int(" <> term_expr <> ")"
    FloatField -> "decode_float(" <> term_expr <> ")"
    StringField -> "decode_string(" <> term_expr <> ")"
    BoolField -> "decode_bool(" <> term_expr <> ")"
    BitArrayField -> "decode_bit_array(" <> term_expr <> ")"
    ListOf(inner) ->
      "decode_list_of((t) => "
      <> field_decoder_call(inner, "t", all)
      <> ", "
      <> term_expr
      <> ")"
    OptionOf(inner) ->
      "decode_option_of((t) => "
      <> field_decoder_call(inner, "t", all)
      <> ", "
      <> term_expr
      <> ")"
    ResultOf(ok, err) ->
      "decode_result_of((t) => "
      <> field_decoder_call(ok, "t", all)
      <> ", (t) => "
      <> field_decoder_call(err, "t", all)
      <> ", "
      <> term_expr
      <> ")"
    DictOf(k, v) ->
      "decode_dict_of((t) => "
      <> field_decoder_call(k, "t", all)
      <> ", (t) => "
      <> field_decoder_call(v, "t", all)
      <> ", "
      <> term_expr
      <> ")"
    TupleOf(elems) -> {
      let decoders =
        list.map(elems, fn(e) { "(t) => " <> field_decoder_call(e, "t", all) })
      "decode_tuple_of(["
      <> string.join(decoders, ", ")
      <> "], "
      <> term_expr
      <> ")"
    }
    TypeVar(name) ->
      // At a generic-type-var call site, the concrete type arrives via a
      // curried decoder parameter. For MsgFromServer-root fields this
      // shouldn't occur because they're always concrete.
      "decode_type_var_" <> name <> "(" <> term_expr <> ")"
    UserType(module_path, type_name, _args) ->
      decoder_fn_name(module_path, type_name) <> "(" <> term_expr <> ")"
  }
}
```

- [ ] **Step 4.5: Implement `emit_msg_from_server_decoder`**

Find the `DiscoveredType` whose `type_name == "MsgFromServer"`. For each variant, emit a switch arm that builds the constructor with the payload decoded via the variant's field types.

```gleam
fn emit_msg_from_server_decoder(
  discovered: List(DiscoveredType),
) -> String {
  let msg_type =
    list.find(discovered, fn(t) { t.type_name == "MsgFromServer" })
  case msg_type {
    Error(_) -> ""
    Ok(t) -> {
      let arms =
        list.map(t.variants, fn(v) {
          let field_args =
            list.index_map(v.fields, fn(ft, i) {
              field_decoder_call(ft, "term[" <> int.to_string(i + 1) <> "]", discovered)
            })
          "    case \""
          <> v.atom_name
          <> "\":\n      return new _m_"
          <> module_alias(v.module_path)
          <> "."
          <> v.variant_name
          <> "("
          <> string.join(field_args, ", ")
          <> ");"
        })
      "export function decode_msg_from_server(term) {\n"
      <> "  const tag = Array.isArray(term) ? term[0] : term;\n"
      <> "  switch (tag) {\n"
      <> string.join(arms, "\n")
      <> "\n    default:\n      throw new DecodeError(\"unknown MsgFromServer variant: \" + String(tag));\n"
      <> "  }\n"
      <> "}"
    }
  }
}
```

- [ ] **Step 4.6: Implement import emission**

```gleam
fn emit_decoder_imports(
  discovered: List(DiscoveredType),
  config: Config,
) -> String {
  let module_paths =
    list.map(discovered, fn(t) { t.module_path }) |> list.unique
  let module_imports =
    list.map(module_paths, fn(mp) {
      "import * as _m_" <> module_alias(mp) <> " from \""
      <> module_to_mjs_path(mp)
      <> "\";"
    })
  let prelude_import =
    "import { decode_int, decode_float, decode_string, decode_bool, "
    <> "decode_bit_array, decode_list_of, decode_option_of, decode_result_of, "
    <> "decode_dict_of, decode_tuple_of, DecodeError } from \""
    <> config.decoders_prelude_import_path
    <> "\";"
  string.join([prelude_import, ..module_imports], "\n")
}
```

Add `decoders_prelude_import_path` and `decoders_ffi_output` to `Config` in `src/libero/config.gleam`.

- [ ] **Step 4.7: Add a golden codegen test**

Create `test/libero/typed_decoder_codegen_test.gleam`:

```gleam
import gleam/list
import gleam/string
import libero/codegen
import libero/walker

fn sample_types() -> List(walker.DiscoveredType) {
  [
    walker.DiscoveredType(
      module_path: "shared/line_item",
      type_name: "Status",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/line_item",
          variant_name: "Pending",
          atom_name: "pending",
          float_field_indices: [],
          fields: [],
        ),
        walker.DiscoveredVariant(
          module_path: "shared/line_item",
          variant_name: "Paid",
          atom_name: "paid",
          float_field_indices: [],
          fields: [],
        ),
      ],
    ),
  ]
}

pub fn decoder_ffi_emits_enum_decoder_test() {
  // Emit in-memory (skip file writing) for assertion.
  let js = codegen.emit_typed_decoders(sample_types())
  let assert True =
    string.contains(js, "export function decode_shared_line_item_status(term)")
  let assert True = string.contains(js, "return new _m_shared_line_item.Pending()")
  let assert True = string.contains(js, "return new _m_shared_line_item.Paid()")
}
```

Expose `emit_typed_decoders` as `pub fn` (or a test-only helper) that returns the JS string without writing. That avoids filesystem work in tests.

- [ ] **Step 4.8: Build and test**

Run: `gleam test`

Expected: new codegen test passes.

- [ ] **Step 4.9: Commit**

```bash
git add src/libero/codegen.gleam src/libero/config.gleam test/libero/typed_decoder_codegen_test.gleam
git commit -m "Add write_decoders_ffi codegen for typed decoders"
```

---

## Task 5: Codegen — wire up `rpc_decoders.gleam` Gleam-side wrapper

**Goal:** The Gleam side needs a thin `rpc_decoders.gleam` that re-exports the FFI's `decode_msg_from_server` so `wire.coerce` can call it.

**Files:**
- Modify: `src/libero/codegen.gleam`
- Modify: `src/libero/config.gleam`

- [ ] **Step 5.1: Add `write_decoders_gleam`**

```gleam
pub fn write_decoders_gleam(
  config config: Config,
) -> Result(Nil, GenError) {
  let body =
    "import gleam/dynamic.{type Dynamic}\n\n"
    <> "@external(javascript, \"./rpc_decoders_ffi.mjs\", \"decode_msg_from_server\")\n"
    <> "pub fn decode_msg_from_server(raw: Dynamic) -> Dynamic\n"
  // Use same file-writing helper pattern as write_register_gleam.
}
```

The return type is `Dynamic` because the caller (`wire.coerce`) already handles the unwrap from `Dynamic` to the concrete type. On Erlang this function has no implementation — typed decoders are JS-only. Add an Erlang-side `@external` that's a no-op identity (or just panic with "typed_decoders_jvm_not_supported") since the server never needs to call it.

Actually simpler: since typed-decoder dispatch is only on the client, omit the Erlang external entirely and mark the function as JS-target-only. Libero's package already uses per-target modules; this fits.

- [ ] **Step 5.2: Add the `write_decoders_gleam` output path to `Config`**

In `src/libero/config.gleam`, add:

```gleam
decoders_gleam_output: String,
```

Populate it in whatever function builds the `Config` from CLI args or project layout.

- [ ] **Step 5.3: Call `write_decoders_gleam` from `src/libero.gleam`**

Find the pipeline that calls `write_register` (in `src/libero.gleam` top-level). Add a call to `write_decoders_gleam` and `write_decoders_ffi` alongside. Keep `write_register` calls in place for now — they'll be removed in Task 9.

- [ ] **Step 5.4: Build and test**

Run: `gleam test`

Expected: pass. No test directly exercises the new Gleam wrapper yet; the end-to-end examples will cover it in Task 6–7.

- [ ] **Step 5.5: Commit**

```bash
git add src/libero/codegen.gleam src/libero/config.gleam src/libero.gleam
git commit -m "Emit rpc_decoders.gleam wrapper alongside FFI"
```

---

## Task 6: Wire entry point — use typed decoder in `wire.coerce`

**Goal:** Route incoming RPC envelopes through the generated `decode_msg_from_server` instead of the current generic ETF-to-constructor path.

**Files:**
- Modify: `src/libero/wire.gleam`
- Modify: `src/libero/rpc_ffi.mjs` (add an envelope helper if needed)

- [ ] **Step 6.1: Update `wire.coerce`**

Current `coerce` implementation (read `src/libero/wire.gleam` first — the exact shape depends on current version). The goal: instead of `wire.coerce` returning whatever the generic decoder produced, it calls the consumer-generated `decode_msg_from_server` (resolved via the generated `rpc_decoders.gleam` alias).

The mechanics vary. One option: `wire.coerce` takes an optional typed-decoder callback parameter. The generated `rpc_decoders.gleam` wires that callback into the caller's code. Alternatively, `to_remote` and `to_result` in `libero/remote_data` accept a typed decoder argument.

The cleanest shape is to change `to_remote`/`to_result` signatures:

```gleam
// Before
pub fn to_remote(
  raw raw: Dynamic,
  format_domain format_domain: fn(domain) -> String,
) -> RemoteData(payload, RpcFailure)

// After
pub fn to_remote(
  raw raw: Dynamic,
  decode_payload decode_payload: fn(Dynamic) -> payload,
  format_domain format_domain: fn(domain) -> String,
) -> RemoteData(payload, RpcFailure)
```

But that changes every call site in consumer code, which we said we wanted to avoid. Instead, keep the signatures as-is and do the typed decoding inside `wire.coerce`'s generic path, letting the generated decoder dispatch based on the incoming atom tag.

The simplest shape that meets the "no consumer code change" goal: `wire.coerce` still returns a `Result(Result(payload, domain), RpcError)`. Internally, when the ETF decoder encounters an atom tag at the top level, it now calls `decode_msg_from_server` (injected via a module-level hook) instead of the global registry.

Concretely:

1. `rpc_decoders_ffi.mjs` on load calls `setMsgFromServerDecoder(decode_msg_from_server)` to register itself with `rpc_ffi.mjs`.
2. `rpc_ffi.mjs`'s `decodeTerm`, when it hits a tagged tuple at the top level (the envelope), calls the registered typed decoder instead of the generic registry path.
3. For nested fields, the typed decoder calls other decoders which don't go back through the registry — they read term fields directly.

This is a small change in `rpc_ffi.mjs`:

```js
let msgFromServerDecoder = null;
export function setMsgFromServerDecoder(fn) {
  msgFromServerDecoder = fn;
}

// Inside decodeTerm where it currently does `registry.get(atomName)`:
// Replace with:
//   if (msgFromServerDecoder && isTopLevelEnvelope(atomName)) {
//     return msgFromServerDecoder(rawTerm);
//   }
// And keep the registry path only for Result/Ok/Error/Some/None primitives
// that the generated decoder doesn't redefine.
```

- [ ] **Step 6.2: Auto-register on module load**

In the generated `rpc_decoders_ffi.mjs`, at the bottom, call:

```js
import { setMsgFromServerDecoder } from "./path/to/rpc_ffi.mjs";
setMsgFromServerDecoder(decode_msg_from_server);
```

This happens on module import, so as long as `rpc_decoders_ffi.mjs` is imported (which the Gleam-side `rpc_decoders.gleam` ensures via its `@external`), the typed path is active.

- [ ] **Step 6.3: Ensure `rpc_decoders.gleam` is reachable from consumers' code**

Consumers import `libero/rpc` in their `app.gleam` today, which transitively brings in `wire.gleam` which triggers the JS import chain. Verify that importing the new `rpc_decoders.gleam` is automatic. Simplest: have the generated `rpc_register.gleam` → `rpc_decoders.gleam` (same location, same auto-import hook). Consumers' `send.gleam`/`send_ffi.mjs` already imports something libero-generated; chain `rpc_decoders_ffi.mjs` from there if not already.

If that chaining isn't already in place, add `import "./rpc_decoders_ffi.mjs"` to the top of the consumer-generated `send_ffi.mjs` (or wherever the JS-side bootstrapping happens) so the decoder registers before the first RPC arrives.

- [ ] **Step 6.4: Build and test**

Run: `gleam test`

Expected: pass. Wire change should be covered indirectly by the Task 7 example update.

- [ ] **Step 6.5: Commit**

```bash
git add src/libero/wire.gleam src/libero/rpc_ffi.mjs
git commit -m "Route incoming envelopes through typed decoder"
```

---

## Task 7: Regenerate the todos example with typed decoders

**Goal:** Sanity-check that the new codegen produces a working `examples/todos` end-to-end. Don't remove the old registry output yet (Task 9 does that).

**Files:**
- Regenerate: `examples/todos/client/src/client/generated/libero/`
- Regenerate: `examples/todos/server/src/server/generated/libero/`

- [ ] **Step 7.1: Regenerate**

Run libero against the example:

```bash
cd examples/todos
rm -f client/src/client/generated/libero/rpc_decoders*.* \
      server/src/server/generated/libero/rpc_decoders*.*
gleam run --module libero -- generate
```

(Adjust the command to match libero's actual CLI — check `src/libero/cli` or the repo's top-level `bin/` scripts to confirm how the generator is invoked.)

Expected: new `rpc_decoders.gleam` and `rpc_decoders_ffi.mjs` appear in `examples/todos/client/src/client/generated/libero/`.

- [ ] **Step 7.2: Run the todos example's own tests**

```bash
cd examples/todos
gleam test --target javascript   # if the example has client-side tests
gleam test --target erlang       # server-side if tests exist
```

Expected: existing tests still pass.

- [ ] **Step 7.3: Sanity-read the generated `rpc_decoders_ffi.mjs`**

Open `examples/todos/client/src/client/generated/libero/rpc_decoders_ffi.mjs` and verify:

- Imports reference the right module paths
- A `decode_shared_todos_todo` function exists with correct field extraction
- `decode_msg_from_server` dispatches on the expected atoms

If something looks wrong (e.g. wrong module alias, missing field decoder), fix the generator and regenerate.

- [ ] **Step 7.4: Commit the regenerated example**

```bash
git add examples/todos/
git commit -m "Regenerate todos example with typed decoders"
```

---

## Task 8: Regenerate the todos-hydration example

**Goal:** Same as Task 7, applied to the larger SSR/hydration example.

**Files:**
- Regenerate: `examples/todos-hydration/client/src/client/generated/libero/`
- Regenerate: `examples/todos-hydration/server/src/server/generated/libero/`

- [ ] **Step 8.1: Regenerate**

Same command as Task 7.1, under `examples/todos-hydration/`.

- [ ] **Step 8.2: Run the example's tests**

```bash
cd examples/todos-hydration
gleam test --target javascript
gleam test --target erlang
```

- [ ] **Step 8.3: Sanity-read and commit**

Same pattern as Task 7.

```bash
git add examples/todos-hydration/
git commit -m "Regenerate todos-hydration example with typed decoders"
```

---

## Task 9: Collision regression test

**Goal:** A dedicated test fixture with two shared modules that both declare a `Paid` variant, plus a test that verifies the typed decoder produces the correct-module instance. This is the direct regression test for the v3-20li bug.

**Files:**
- Create: `test/fixtures/collision/shared/a.gleam`
- Create: `test/fixtures/collision/shared/b.gleam`
- Create: `test/fixtures/collision/shared/messages.gleam`
- Create: `test/fixtures/collision/gleam.toml`
- Create: `test/libero/collision_regression_test.gleam`

- [ ] **Step 9.1: Create the fixture shared modules**

`test/fixtures/collision/shared/a.gleam`:

```gleam
pub type Status {
  Pending
  Paid
  Submitted
  Cancelled
}
```

`test/fixtures/collision/shared/b.gleam`:

```gleam
pub type Status {
  Pending
  Paid
  Submitted
  Cancelled
}
```

- [ ] **Step 9.2: Create the messages module**

`test/fixtures/collision/shared/messages.gleam`:

```gleam
import shared/a
import shared/b

pub type MsgFromClient {
  LoadA
  LoadB
}

pub type MsgFromServer {
  LoadedA(Result(a.Status, String))
  LoadedB(Result(b.Status, String))
}
```

- [ ] **Step 9.3: Create a minimal `gleam.toml` for the fixture**

`test/fixtures/collision/gleam.toml`:

```toml
name = "collision_fixture"
version = "0.0.0"

[dependencies]
gleam_stdlib = "~> 0.68"
```

This is just enough to let libero's scanner parse the shared modules.

- [ ] **Step 9.4: Write the regression test**

`test/libero/collision_regression_test.gleam`:

```gleam
import gleam/list
import gleam/string
import libero/codegen
import libero/scanner
import libero/walker

pub fn collision_produces_distinct_decoders_test() {
  let fixture = "test/fixtures/collision/shared"
  let assert Ok(#(modules, module_files)) =
    scanner.scan_message_modules(shared_src: fixture)
  let assert Ok(types) =
    walker.walk_message_registry_types(
      message_modules: modules,
      module_files: module_files,
    )

  // Both a.Status and b.Status must appear in the discovered graph.
  let names =
    list.map(types, fn(t) { t.module_path <> "." <> t.type_name })
  let assert True = list.contains(names, "shared/a.Status")
  let assert True = list.contains(names, "shared/b.Status")

  // The generated JS must contain a distinct function per type.
  let js = codegen.emit_typed_decoders(types)
  let assert True =
    string.contains(js, "export function decode_shared_a_status(term)")
  let assert True =
    string.contains(js, "export function decode_shared_b_status(term)")

  // And each decoder must construct instances from its own module:
  let assert True = string.contains(js, "new _m_shared_a.Paid()")
  let assert True = string.contains(js, "new _m_shared_b.Paid()")
}
```

- [ ] **Step 9.5: Write an end-to-end JS-level collision test**

The above test verifies codegen output. Add one more that compiles the emitted JS and exercises it at runtime:

`test/js/collision_runtime_test.mjs`:

```javascript
// Regression test: with typed decoders, decoding `paid` in a
// shared/a.Status field produces an `a.Paid` instance, and decoding
// `paid` in a shared/b.Status field produces a `b.Paid` instance —
// even though both modules export a `Paid` constructor under the same atom.

import { decode_msg_from_server } from
  "../../test/fixtures/collision/client/generated/libero/rpc_decoders_ffi.mjs";
import * as a from "../../test/fixtures/collision/shared/shared/a.mjs";
import * as b from "../../test/fixtures/collision/shared/shared/b.mjs";

// Simulate an incoming envelope: ["loaded_a", ["ok", "paid"]]
const loadedA = decode_msg_from_server(["loaded_a", ["ok", "paid"]]);
if (!(loadedA.$0 instanceof a.Paid)) {
  throw new Error("LoadedA payload should be instance of a.Paid");
}
if (loadedA.$0 instanceof b.Paid) {
  throw new Error("LoadedA payload should NOT be instance of b.Paid");
}

const loadedB = decode_msg_from_server(["loaded_b", ["ok", "paid"]]);
if (!(loadedB.$0 instanceof b.Paid)) {
  throw new Error("LoadedB payload should be instance of b.Paid");
}

console.log("collision runtime test passed");
```

This test requires the fixture to have been compiled. Add a test-runner step that runs `gleam build --target javascript` on the fixture first, then invokes the JS test via `node`.

Practical route: add a script `test/run_collision_test.sh` that:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Generate libero output into the fixture
gleam run --module libero -- generate --shared-src test/fixtures/collision/shared \
  --client-output test/fixtures/collision/client/generated/libero \
  --server-output test/fixtures/collision/server/generated/libero

# Compile fixture to JS
(cd test/fixtures/collision && gleam build --target javascript)

# Run the runtime test
node test/js/collision_runtime_test.mjs
```

Invoke the script from the existing test runner or a dedicated gleam test that shells out. Exact wiring depends on how other JS-involved tests are invoked in this repo — look at how `test/js/etf_codec_test.mjs` is run.

- [ ] **Step 9.6: Run the tests**

```bash
gleam test
# plus any JS runtime test script
```

Expected: both the codegen-level and runtime-level collision tests pass. If the runtime test fails, the typed decoders are NOT correctly disambiguating — debug before moving on.

- [ ] **Step 9.7: Commit**

```bash
git add test/fixtures/collision/ test/libero/collision_regression_test.gleam \
        test/js/collision_runtime_test.mjs test/run_collision_test.sh
git commit -m "Add collision regression test for typed decoders"
```

---

## Task 10: Delete the old global registry

**Goal:** Remove `write_register_ffi`, `write_register_gleam`, and the registry-lookup branch in `rpc_ffi.mjs`. Consumers regenerate and get typed decoders only.

**Files:**
- Modify: `src/libero/codegen.gleam`
- Modify: `src/libero/rpc_ffi.mjs`
- Modify: `src/libero.gleam`
- Regenerate: both examples (the old `rpc_register.*` files disappear)

- [ ] **Step 10.1: Remove `write_register_ffi` and `write_register_gleam`**

Delete both functions from `src/libero/codegen.gleam`. Also delete any internal helpers they relied on that aren't used elsewhere (grep for orphans after the deletion).

- [ ] **Step 10.2: Remove the registry from `rpc_ffi.mjs`**

Delete:

- `const registry = new Map();`
- `export function registerConstructor(...)`
- The `registry.get(atomName)` branch in `decodeTerm`

Keep the primitive-atom handling (`true`, `false`, `nil`, `undefined`) and the encoder. Keep `setMsgFromServerDecoder` from Task 6.

- [ ] **Step 10.3: Update `src/libero.gleam`**

Remove the two call sites that invoke `write_register_ffi` and `write_register_gleam`. Leave the `write_decoders_ffi` / `write_decoders_gleam` calls.

- [ ] **Step 10.4: Regenerate both examples**

```bash
cd examples/todos && rm -f */src/*/generated/libero/rpc_register*
cd examples/todos-hydration && rm -f */src/*/generated/libero/rpc_register*
# Regenerate each (same as Task 7.1 / 8.1)
```

Expected: regenerating does NOT re-create `rpc_register*` files. Only `rpc_decoders*`.

- [ ] **Step 10.5: Build and test**

```bash
gleam test
cd examples/todos && gleam test --target javascript
cd examples/todos-hydration && gleam test --target javascript
```

Expected: all pass.

- [ ] **Step 10.6: Commit**

```bash
git add src/libero/ examples/todos/ examples/todos-hydration/
git commit -m "Remove global constructor registry"
```

---

## Task 11: Documentation

**Goal:** Keep README and LLM_USERS.md in sync with the new decoder surface.

**Files:**
- Modify: `README.md`
- Modify: `LLM_USERS.md`

- [ ] **Step 11.1: Update README**

Find the section describing the client-side RPC flow. Replace mentions of "constructor registry" or "registerConstructor" with "typed decoders". Add a short example showing a generated decoder.

- [ ] **Step 11.2: Update LLM_USERS.md**

Same update — any reference to the registry moves to the typed decoder shape. Include a one-paragraph explanation of why (collision avoidance) for future readers.

- [ ] **Step 11.3: Commit**

```bash
git add README.md LLM_USERS.md
git commit -m "Document typed decoder surface in README and LLM_USERS"
```

---

## Task 12: Consumer verification — regenerate v3

**Goal:** Pull updated libero into v3, regenerate, and confirm the Registrations page now shows statuses correctly.

**Files (in v3 repo, NOT libero):**
- Modify: `lib/libero` submodule pointer

- [ ] **Step 12.1: Update v3's submodule pointer**

From `/home/dave/projects/curling/v3`:

```bash
cd lib/libero
git checkout master
cd ../..
```

This is on top of the libero-3 branch in v3 where the previous integration landed.

- [ ] **Step 12.2: Remove stale generated files**

```bash
rm -f client/src/client/generated/libero/admin/rpc_register*
rm -f server/src/server/generated/libero/admin/rpc_register*
```

- [ ] **Step 12.3: Regenerate**

```bash
bin/dev
```

Expected: libero runs, generates `rpc_decoders.gleam` and `rpc_decoders_ffi.mjs`. No `rpc_register*` files re-appear.

- [ ] **Step 12.4: Run v3 tests**

```bash
bin/test
```

Expected: 362 shared, ~1436 server, 139 client, all pass.

- [ ] **Step 12.5: Browser smoke — the real fix**

Navigate to `http://demo.curling.test:8080/en/admin/registration/events/1/registrations`.

Expected: rows show "Paid" and "Submitted (awaiting payment)" status labels — NOT all "Cancelled". That's the original v3-20li bug fixed end-to-end.

- [ ] **Step 12.6: Close the bean**

```bash
cd /home/dave/projects/curling/v3
beans delete -f v3-20li
```

- [ ] **Step 12.7: Commit the submodule bump**

```bash
git add lib/libero .beans/
git commit -m "Bump libero to typed-decoder master, close collision bean"
```

---

## Self-review checklist

**Spec coverage:**
- ✓ `DiscoveredType` graph — Task 1 + Task 2
- ✓ `FieldType` union — Task 1
- ✓ `rpc_decoders_ffi.mjs` generation — Task 4
- ✓ `rpc_decoders.gleam` wrapper — Task 5
- ✓ `decoders_prelude.mjs` static library — Task 3
- ✓ Generic combinators (List, Option, Result, Dict, tuple) — Task 3 + Task 4
- ✓ Message-level entry point (`decode_msg_from_server`) — Task 4.5
- ✓ Error handling (`DecodeError` class, envelope catch) — Task 3 + Task 6
- ✓ Walker unit tests — Task 1.5, 1.6
- ✓ Codegen golden tests — Task 4.7
- ✓ Collision regression test — Task 9
- ✓ Example updates — Task 7 + Task 8
- ✓ Old registry removal — Task 10
- ✓ Docs — Task 11
- ✓ Consumer verification — Task 12

**Placeholder scan:** Task 6 has one "Exact wiring depends on how other JS-involved tests are invoked" — this is an investigation step where the implementer reads nearby code first, not a placeholder. Other inline notes ("check the CLI invocation convention", "match the existing pattern") direct the implementer to read existing code rather than inventing new patterns. No true placeholders.

**Type consistency:** `DiscoveredType` / `DiscoveredVariant` / `FieldType` shapes are defined in Task 1–2 and reused consistently through Tasks 4, 9, 10. `decoder_fn_name`, `field_decoder_call`, and `module_alias` names are consistent across tasks. `decode_msg_from_server` is named identically in codegen (Task 4.5), FFI hook (Task 6), and tests (Task 9).
