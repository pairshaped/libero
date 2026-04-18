# Typed Decoders Design

## Summary

Replace libero's global constructor registry on the JS client with typed, per-type decoders generated from the discovered message type graph. The registry conflates variants that share an atom name across modules (e.g. `line_item.Paid`, `account_credit.Paid`, `order.Paid` all register under `"paid"`); typed decoders carry type context at every decode point, so the ambiguity disappears.

This is a client-side codegen rework. The ETF wire format does not change. No application code changes on consumers once they regenerate.

## Problem

Libero's current client-side decoder uses a single global `Map<atom_name, Constructor>`. When walker discovers variants across multiple shared modules, each calls `registerConstructor(atom_name, Ctor)`; the last write for a given atom wins.

Concrete failure today in the curling v3 codebase: `shared/line_item.Status.Paid`, `shared/account_credit.Status.Paid`, and `shared/order.Status.Paid` all snake-case to the atom `paid`. All three register under `"paid"`, and `shared/order.Paid` ends up as the final resident. When the server sends a `LineItem` whose `status` field is `line_item.Paid`, the decoder constructs an `order.Paid` instead. Pattern matching on `line_item.Paid`/`Submitted`/`Pending` fails and the exhaustive match falls through to the `Cancelled` arm — every row in the Registrations admin list shows "Cancelled".

The Gleam-to-Erlang compilation path produces identical bare atoms for same-named variants across modules (`-type status() :: pending | paid | submitted | cancelled.`), and `erlang:term_to_binary/1` cannot distinguish them. So the wire format itself has no room to disambiguate. Disambiguation must happen in the decoder using type context from the call site.

## Goals

- Remove the global constructor registry on the JS client. Decoding routes through typed, per-type decoder functions.
- Each field of each discovered type is decoded by a decoder that knows exactly which type it's producing.
- Generic types (`List(X)`, `Option(X)`, `Result(X, Y)`, `Dict(K, V)`, tuples) are handled by parameterized combinators.
- Zero application-code change on consumers. Regenerating after the upgrade is all that's required.
- The fix ships with an automated regression test that fails under the current registry and passes with the typed decoders.

## Non-goals

- Changing the wire format. ETF via `term_to_binary` / custom JS encoder stays.
- Changing the Erlang server-side path. Pattern matching on bare atoms still works there because Gleam's compiled Erlang code treats all `paid` atoms interchangeably, and the server isn't ambiguously decoding typed values across modules in practice.
- Preserving backwards compatibility with consumers pinned to pre-typed-decoder libero. Clean break. (Libero master has no version-bump yet; v4.0 will absorb this work.)
- Supporting types that libero's walker cannot statically resolve. If a type can't be reached from `MsgFromClient`/`MsgFromServer`, it doesn't cross the wire. This matches today's behaviour.

## Design

### Walker output

The walker graph shifts from a flat `List(DiscoveredVariant)` to a tree-shaped `List(DiscoveredType)`. Each type carries its variants, and each variant carries field types with resolved module references.

```gleam
pub type DiscoveredType {
  DiscoveredType(
    module_path: String,          // e.g. "shared/line_item"
    type_name: String,            // e.g. "Status"
    variants: List(DiscoveredVariant),
    type_params: List(String),    // e.g. ["a", "b"] for Result(a, b); [] for Status
  )
}

pub type DiscoveredVariant {
  DiscoveredVariant(
    variant_name: String,         // e.g. "Paid"
    atom_name: String,            // e.g. "paid"
    fields: List(FieldType),      // field types in declaration order
  )
}

pub type FieldType {
  /// A concrete user-defined type resolved to module + name.
  /// `args` captures type-parameter instantiation, e.g. `List(Int)`
  /// is `UserType("gleam/list", "List", [IntField])`.
  UserType(module_path: String, type_name: String, args: List(FieldType))
  /// Built-in generic types libero handles natively.
  ListOf(element: FieldType)
  OptionOf(inner: FieldType)
  ResultOf(ok: FieldType, err: FieldType)
  DictOf(key: FieldType, value: FieldType)
  TupleOf(elements: List(FieldType))
  /// Leaf primitives.
  IntField
  FloatField
  StringField
  BoolField
  BitArrayField
  /// Type-variable reference for generic type definitions.
  /// Resolved at each instantiation site.
  TypeVar(name: String)
}
```

Type aliases are resolved during walking (replaced with the aliased shape). Recursive types terminate the walk via the existing `visited` set.

### Generated client module

Each consumer gets a single generated decoder module replacing the old register module:

- `rpc_decoders.gleam` — thin Gleam wrapper around the FFI for types the Gleam side needs.
- `rpc_decoders_ffi.mjs` — the functional heart; one exported decoder per discovered type.

Naming: `decode_<module_snake>_<type_snake>`, where `/` and `@` in the module path become `_`. Example: `shared/line_item.Status` becomes `decode_shared_line_item_status`.

A typical enum decoder:

```js
import * as line_item from "../../../../shared/shared/line_item.mjs";

export function decode_shared_line_item_status(term) {
  if (term === "paid") return new line_item.Paid();
  if (term === "submitted") return new line_item.Submitted();
  if (term === "pending") return new line_item.Pending();
  if (term === "cancelled") return new line_item.Cancelled();
  throw new DecodeError("unknown shared/line_item.Status atom: " + term);
}
```

A record decoder:

```js
export function decode_shared_line_item_line_item(term) {
  // term is [atom, field0, field1, ...]; atom is "line_item".
  return new line_item.LineItem(
    term[1],                                           // id: Int
    term[2],                                           // order_id: Int
    decode_shared_line_item_kind(term[3]),             // kind: Kind
    // ... and so on
    decode_shared_line_item_status(term[15]),          // status: Status
    // ...
  );
}
```

A multi-variant record type with tagged tuples dispatches on the leading atom:

```js
export function decode_shared_account_credit_status(term) {
  const tag = term[0] ?? term;  // bare atom or tagged tuple
  switch (tag) {
    case "paid": return new account_credit.Paid(/* ...fields from term[1..]... */);
    case "refunded": return new account_credit.Refunded(/* ... */);
    default: throw new DecodeError("unknown shared/account_credit.Status tag: " + tag);
  }
}
```

### Generic combinators

A static prelude at `src/libero/decoders_prelude.mjs` ships with libero and is imported by every generated decoder module. It supplies the primitive and generic combinators:

```js
export const decode_int = (term) => term;
export const decode_string = (term) => term;
export const decode_float = (term) => term;
export const decode_bool = (term) => term === "true" ? true : false;
export const decode_bit_array = (term) => term;

export function decode_list_of(elementDecoder, term) {
  // term is a gleam/list.List; walk and re-construct.
  const items = listToArray(term);
  return arrayToList(items.map(elementDecoder));
}

export function decode_option_of(innerDecoder, term) {
  // `none` bare atom or ["some", inner]
  if (term === "none") return new None();
  return new Some(innerDecoder(term[1]));
}

export function decode_result_of(okDecoder, errDecoder, term) {
  const tag = term[0];
  if (tag === "ok") return new Ok(okDecoder(term[1]));
  if (tag === "error") return new Error(errDecoder(term[1]));
  throw new DecodeError("not a Result: " + String(tag));
}

export function decode_dict_of(keyDecoder, valueDecoder, term) {
  // term is a gleam/dict.Dict (backed by a Map on JS)
  const entries = dictEntries(term);
  return entriesToDict(entries.map(([k, v]) => [keyDecoder(k), valueDecoder(v)]));
}

export function decode_tuple_of(elementDecoders, term) {
  return elementDecoders.map((decoder, i) => decoder(term[i]));
}

export class DecodeError extends Error {
  constructor(message) {
    super(message);
    this.name = "DecodeError";
  }
}
```

Application of combinators is inlined at call sites. Example: a field of type `List(Option(String))` becomes:

```js
(t) => decode_list_of((inner) => decode_option_of(decode_string, inner), t)
```

Inlining keeps the generator straightforward and avoids needing first-class curried decoders.

### Message-level entry points

Each message module gets a per-variant decoder for its `MsgFromServer`. The RPC envelope handler routes the incoming wire value to the right variant decoder based on the leading atom, then dispatches to the payload decoder via the variant's signature:

```js
export function decode_msg_from_server(term) {
  const tag = term[0];
  switch (tag) {
    case "item_registrations_loaded":
      return new ItemRegistrationsLoaded(
        decode_result_of(
          (t) => decode_list_of(decode_shared_registration_registration, t),
          decode_string,
          term[1],
        ),
      );
    case "item_registration_updated":
      return new ItemRegistrationUpdated(
        decode_result_of(
          decode_shared_registration_registration,
          decode_string,
          term[1],
        ),
      );
    // ...one arm per MsgFromServer variant...
    default: throw new DecodeError("unknown MsgFromServer variant: " + String(tag));
  }
}
```

`wire.coerce` (used by `to_remote` and `to_result` in `libero/remote_data`) calls `decode_msg_from_server` once per incoming envelope. The current generic decoder in `rpc_ffi.mjs` is replaced by this typed entry point.

### Encoder

The encoder path is untouched. `encode_value` in `rpc_ffi.mjs` already uses `snakeCase(value.constructor.name)` to produce bare atoms. That's symmetric with what Erlang's `term_to_binary` emits. No module disambiguation is needed because the Erlang side already trusts the wire atom and the JS side no longer uses a global registry to decode it.

### Error handling

Decoders throw `DecodeError` on malformed input. The envelope entry point (`wire.coerce` → `decode_msg_from_server`) catches the error and converts it to `Failure(FrameworkFailure("decode error: <details>"))` in the `RemoteData`. Consumers see the failure through their existing `to_remote`/`to_result` call sites and the `RpcFailure` type.

Decoder call sites do not return `Result`; they throw. This keeps the generated code readable and small. The single catch at the envelope boundary gives correct propagation without infecting every nested call.

### File layout changes in libero

- `src/libero/walker.gleam` — emit `DiscoveredType` graph; keep `DiscoveredVariant` as a sub-type.
- `src/libero/codegen.gleam` — replace `write_register_ffi`/`write_register_gleam` with `write_decoders_ffi`/`write_decoders_gleam`; update per-RPC message decoder emission to call the typed decoders.
- `src/libero/rpc_ffi.mjs` — delete the global registry (`registry`, `registerConstructor`), delete the atom-dispatch branch of `decodeTerm` that consults the registry; the decoder becomes generic-only (decoding to plain JS values). Typed reconstruction happens in the generated `rpc_decoders_ffi.mjs`.
- `src/libero/decoders_prelude.mjs` — new static file with primitives and generic combinators. Copied into consumer output alongside the generated decoders (or referenced by relative import from libero's package path).

Generated consumer output changes:

- `rpc_register.gleam` → replaced by `rpc_decoders.gleam`
- `rpc_register_ffi.mjs` → replaced by `rpc_decoders_ffi.mjs`
- `rpc_atoms.erl` — retained as-is; the Erlang side still uses atoms for its own pattern matching.

## Testing

Three layers, all automated.

### Walker unit tests

Given a parsed `glance.Module` fixture (or small inline AST), assert that `walk_message_registry_types` returns the expected `List(DiscoveredType)` graph. Cases to cover:

- Plain enum (no fields)
- Enum with fields of primitive types
- Enum with fields of other user-defined types (cross-module references)
- Recursive type (e.g., a linked-list type that references itself)
- Generic type with one parameter (`Option(a)`)
- Generic type with two parameters (`Result(ok, err)`)
- Nested generics (`List(Option(String))`)
- Type alias (skipped; the walker returns the aliased shape)
- Fields of built-in generics (`List`, `Option`, `Result`, `Dict`, tuple)

### Codegen golden tests

Given a hand-written `DiscoveredType` graph, run `write_decoders_ffi` and snapshot the emitted file. Regenerating the snapshots must be a one-command operation (e.g. `gleam test -- --update-snapshots`). Cover:

- Enum → `decode_*` function with a switch on the atom
- Record → constructor call with per-field decoder applications
- Multi-variant tagged tuple → switch on leading atom with per-variant constructor calls
- Type instantiated with a generic wrapper (`List(Option(Int))`) → inlined combinator application

### Collision regression test

A dedicated fixture under `test/fixtures/collision/`:

- `shared/a.gleam` defines `pub type Status { Pending Paid Submitted Cancelled }`.
- `shared/b.gleam` defines `pub type Status { Pending Paid Submitted Cancelled }` (same shape, different module).
- `shared/messages.gleam` defines `MsgFromServer` with two variants: `LoadA(Result(a.Status, String))` and `LoadB(Result(b.Status, String))`.

The test:

1. Runs libero's codegen against this fixture.
2. Compiles the generated `rpc_decoders_ffi.mjs`.
3. Feeds a synthetic wire term (a simulated `LoadA(Ok(Paid))` followed by a `LoadB(Ok(Paid))`) through `decode_msg_from_server`.
4. Asserts the first result is an `a.Paid` instance and the second is a `b.Paid` instance (via `instanceof` checks against the respective module classes).

Under the current global-registry implementation, both would be the same class (whichever won the registration race). Under the typed decoders, they are distinct. This is the direct regression test the maintainer asked for.

### End-to-end smoke via todos examples

Existing `todos` and `todos-hydration` examples exercise the full pipeline (client ↔ Erlang server). Update both to use the new decoders and verify they still pass their existing round-trip tests. This catches integration-level breakage that unit tests wouldn't.

## Migration within libero

1. Land the new walker output (`DiscoveredType` graph). Unit tests cover it.
2. Add `decoders_prelude.mjs` and golden codegen tests for typed decoders.
3. Wire the new decoder path into `wire.coerce` (keep the old registry path behind a feature-flag temporarily so tests can run side-by-side if needed).
4. Update the todos and todos-hydration examples. Verify round-trip.
5. Land the collision regression test fixture + test.
6. Delete the global registry from `rpc_ffi.mjs` and the old `write_register_*` codegen. Update README and LLM_USERS.md.

Consumer migration (v3): regenerate by running `bin/dev` (triggers libero codegen). No application code changes.

## Open questions

None at spec time. Implementation plan will surface any detail questions.

## Out of scope

- SSR hydration decoders. The `ssr.gleam` + `ssr_ffi.mjs` path has its own decoding concerns but is symmetric enough that the same typed-decoder shape should apply. Addressed in a follow-up once the RPC path is proven.
- Server-side Erlang collision handling. The Erlang side currently works because same-named variants compile to the same atom and pattern matching treats them interchangeably. If a future use case needs module-distinct variants on the server side, that's a separate design.
- Per-consumer optimization (tree-shaking, lazy decoders). Generated output is expected to be moderate in size. Revisit if perf becomes a concern.
