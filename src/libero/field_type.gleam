//// The structured Gleam type representation libero uses for both
//// shared-type discovery (walker) and handler signature scanning
//// (scanner). Lifting it out of either module lets both produce and
//// consume the same shape — and lets codegen pattern-match
//// structurally instead of re-parsing strings.

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

/// Placeholder FieldType useful for test fixtures where only the label
/// of a `HandlerEndpoint.params` entry matters (e.g. dispatch generation
/// tests that only check label destructure shape, not the type).
pub fn placeholder() -> FieldType {
  IntField
}
