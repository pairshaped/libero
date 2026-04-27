//// The structured Gleam type representation libero uses for both
//// shared-type discovery (walker) and handler signature scanning
//// (scanner). Lifting it out of either module lets both produce and
//// consume the same shape, and lets codegen pattern-match structurally
//// instead of re-parsing strings.

import gleam/bool
import gleam/list
import gleam/string

/// Names of Gleam types that libero treats as builtin: not user-defined,
/// not requiring atom registration, and not from the shared/ tree. Both
/// the scanner and the walker consult this list, so they agree on what
/// counts as a primitive across the codegen pipeline.
pub const builtin_type_names = [
  "Int", "Float", "String", "Bool", "Nil", "BitArray", "List", "Result",
  "Option", "Dict",
]

/// True if `name` is one of the builtin Gleam type names libero recognises.
pub fn is_builtin(name: String) -> Bool {
  list.contains(builtin_type_names, name)
}

/// Map a builtin Gleam type name (and its parameters) to the
/// corresponding FieldType. Returns Error(Nil) when the name isn't a
/// recognised builtin or the parameter arity doesn't match. The caller
/// supplies `recurse` to convert each parameter (typically a
/// `glance.Type`) into a FieldType, keeping this module independent of
/// glance. Used by scanner and walker so the builtin dispatch lives in
/// one place.
pub fn builtin_field_type(
  name name: String,
  parameters parameters: List(a),
  recurse recurse: fn(a) -> FieldType,
) -> Result(FieldType, Nil) {
  case name, parameters {
    "Int", [] -> Ok(IntField)
    "Float", [] -> Ok(FloatField)
    "String", [] -> Ok(StringField)
    "Bool", [] -> Ok(BoolField)
    "BitArray", [] -> Ok(BitArrayField)
    "Nil", [] -> Ok(NilField)
    "List", [elem] -> Ok(ListOf(element: recurse(elem)))
    "Option", [inner] -> Ok(OptionOf(inner: recurse(inner)))
    "Result", [ok, err] -> Ok(ResultOf(ok: recurse(ok), err: recurse(err)))
    "Dict", [key, value] -> Ok(DictOf(key: recurse(key), value: recurse(value)))
    _, _ -> Error(Nil)
  }
}

/// A Gleam type, resolved to a structured form. Module-qualified
/// references (e.g. `types.Item` written in user code) are resolved
/// to their canonical module path (e.g. `shared/types`) at production
/// time; downstream consumers can rely on `module_path` being the
/// import-stable name without re-doing alias resolution.
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
  NilField
  /// A type variable (generic parameter) that survives to runtime.
  /// Cannot be encoded over the wire; codegen emits a runtime error.
  TypeVar(name: String)
}

/// Render a FieldType as the user-readable Gleam type syntax it came
/// from. UserType uses the LAST segment of the module path so the
/// output matches what the user originally wrote (e.g. `types.Item`,
/// not `shared/types.Item`). Used by codegen to embed types in
/// generated Gleam source.
pub fn to_gleam_source(ft: FieldType) -> String {
  case ft {
    IntField -> "Int"
    FloatField -> "Float"
    StringField -> "String"
    BoolField -> "Bool"
    BitArrayField -> "BitArray"
    NilField -> "Nil"
    TypeVar(name:) -> name
    ListOf(element:) -> "List(" <> to_gleam_source(element) <> ")"
    OptionOf(inner:) -> "Option(" <> to_gleam_source(inner) <> ")"
    ResultOf(ok:, err:) ->
      "Result(" <> to_gleam_source(ok) <> ", " <> to_gleam_source(err) <> ")"
    DictOf(key:, value:) ->
      "Dict(" <> to_gleam_source(key) <> ", " <> to_gleam_source(value) <> ")"
    TupleOf(elements:) ->
      "#(" <> string.join(list.map(elements, to_gleam_source), ", ") <> ")"
    UserType(module_path:, type_name:, args: []) ->
      last_segment(module_path) <> "." <> type_name
    UserType(module_path:, type_name:, args:) ->
      last_segment(module_path)
      <> "."
      <> type_name
      <> "("
      <> string.join(list.map(args, to_gleam_source), ", ")
      <> ")"
  }
}

/// Walk a FieldType and collect every UserType reference it contains
/// (including transitive ones). Returns `#(module_path, type_name)`
/// tuples in discovery order. Used by codegen to determine which
/// shared modules to import.
pub fn collect_user_types(ft: FieldType) -> List(#(String, String)) {
  case ft {
    UserType(module_path:, type_name:, args:) -> [
      #(module_path, type_name),
      ..list.flat_map(args, collect_user_types)
    ]
    ListOf(element:) -> collect_user_types(element)
    OptionOf(inner:) -> collect_user_types(inner)
    ResultOf(ok:, err:) ->
      list.append(collect_user_types(ok), collect_user_types(err))
    DictOf(key:, value:) ->
      list.append(collect_user_types(key), collect_user_types(value))
    TupleOf(elements:) -> list.flat_map(elements, collect_user_types)
    IntField
    | FloatField
    | StringField
    | BoolField
    | BitArrayField
    | NilField
    | TypeVar(_) -> []
  }
}

/// True if `predicate` returns True for `ft` or any FieldType nested
/// within it. Used by codegen to ask questions like "does this type
/// transitively contain Option?" without substring-scanning.
pub fn contains(ft: FieldType, predicate: fn(FieldType) -> Bool) -> Bool {
  use <- bool.guard(when: predicate(ft), return: True)
  case ft {
    ListOf(element:) -> contains(element, predicate)
    OptionOf(inner:) -> contains(inner, predicate)
    ResultOf(ok:, err:) -> contains(ok, predicate) || contains(err, predicate)
    DictOf(key:, value:) ->
      contains(key, predicate) || contains(value, predicate)
    TupleOf(elements:) -> list.any(elements, fn(e) { contains(e, predicate) })
    UserType(args:, ..) -> list.any(args, fn(a) { contains(a, predicate) })
    IntField
    | FloatField
    | StringField
    | BoolField
    | BitArrayField
    | NilField
    | TypeVar(_) -> False
  }
}

/// Last `/`-separated segment of a module path, or the path itself if
/// no separator is present. Used wherever codegen needs the "short"
/// module name for aliases or display.
pub fn last_segment(module_path: String) -> String {
  case string.split(module_path, "/") {
    [] -> module_path
    parts ->
      case list.last(parts) {
        Ok(seg) -> seg
        Error(Nil) -> module_path
      }
  }
}
