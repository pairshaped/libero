//// Snapshot tests for FieldType helpers used by codegen to format types
//// as Gleam source and to detect imports/transitive type usage.

import birdie
import libero/field_type.{
  BitArrayField, BoolField, DictOf, FloatField, IntField, ListOf, NilField,
  OptionOf, ResultOf, StringField, TupleOf, UserType,
}

pub fn to_gleam_source_renders_int_test() {
  birdie.snap(
    field_type.to_gleam_source(IntField),
    title: "int to_gleam_source",
  )
}

pub fn to_gleam_source_renders_string_test() {
  birdie.snap(
    field_type.to_gleam_source(StringField),
    title: "string to_gleam_source",
  )
}

pub fn to_gleam_source_renders_nil_test() {
  birdie.snap(
    field_type.to_gleam_source(NilField),
    title: "nil to_gleam_source",
  )
}

pub fn to_gleam_source_renders_bool_test() {
  birdie.snap(
    field_type.to_gleam_source(BoolField),
    title: "bool to_gleam_source",
  )
}

pub fn to_gleam_source_renders_bitarray_test() {
  birdie.snap(
    field_type.to_gleam_source(BitArrayField),
    title: "bitarray to_gleam_source",
  )
}

pub fn to_gleam_source_renders_float_test() {
  birdie.snap(
    field_type.to_gleam_source(FloatField),
    title: "float to_gleam_source",
  )
}

pub fn to_gleam_source_renders_list_test() {
  birdie.snap(
    field_type.to_gleam_source(ListOf(IntField)),
    title: "list to_gleam_source",
  )
}

pub fn to_gleam_source_renders_option_test() {
  birdie.snap(
    field_type.to_gleam_source(OptionOf(StringField)),
    title: "option to_gleam_source",
  )
}

pub fn to_gleam_source_renders_result_test() {
  birdie.snap(
    field_type.to_gleam_source(ResultOf(IntField, StringField)),
    title: "result to_gleam_source",
  )
}

pub fn to_gleam_source_renders_dict_test() {
  birdie.snap(
    field_type.to_gleam_source(DictOf(StringField, IntField)),
    title: "dict to_gleam_source",
  )
}

pub fn to_gleam_source_renders_tuple_test() {
  birdie.snap(
    field_type.to_gleam_source(TupleOf([IntField, StringField])),
    title: "tuple to_gleam_source",
  )
}

pub fn to_gleam_source_renders_user_type_with_last_segment_test() {
  birdie.snap(
    field_type.to_gleam_source(UserType("shared/types", "Item", [])),
    title: "user_type to_gleam_source",
  )
}

pub fn to_gleam_source_renders_nested_test() {
  let nested =
    ResultOf(
      ListOf(UserType("shared/types", "Item", [])),
      UserType("shared/types", "ItemError", []),
    )
  birdie.snap(
    field_type.to_gleam_source(nested),
    title: "nested to_gleam_source",
  )
}

// -- collect_user_types --

pub fn collect_user_types_returns_empty_for_primitives_test() {
  let assert [] = field_type.collect_user_types(IntField)
  let assert [] = field_type.collect_user_types(ListOf(StringField))
}

pub fn collect_user_types_returns_user_type_test() {
  let assert [#("shared/types", "Item")] =
    field_type.collect_user_types(UserType("shared/types", "Item", []))
}

pub fn collect_user_types_recurses_into_wrappers_test() {
  let nested =
    ResultOf(
      ListOf(UserType("shared/widgets", "Widget", [])),
      UserType("shared/widgets", "Error", []),
    )
  let refs = field_type.collect_user_types(nested)
  let assert [#("shared/widgets", "Widget"), #("shared/widgets", "Error")] =
    refs
}

pub fn collect_user_types_recurses_into_dict_and_tuple_test() {
  let nested =
    DictOf(
      StringField,
      TupleOf([
        UserType("shared/a", "X", []),
        UserType("shared/b", "Y", []),
      ]),
    )
  let assert [#("shared/a", "X"), #("shared/b", "Y")] =
    field_type.collect_user_types(nested)
}

// -- contains --

pub fn contains_finds_option_test() {
  let assert True =
    field_type.contains(ResultOf(OptionOf(IntField), NilField), fn(t) {
      case t {
        OptionOf(_) -> True
        _ -> False
      }
    })
}

pub fn contains_returns_false_when_absent_test() {
  let assert False =
    field_type.contains(ResultOf(IntField, NilField), fn(t) {
      case t {
        OptionOf(_) -> True
        _ -> False
      }
    })
}

pub fn contains_finds_dict_test() {
  let assert True =
    field_type.contains(ListOf(DictOf(StringField, IntField)), fn(t) {
      case t {
        DictOf(_, _) -> True
        _ -> False
      }
    })
}
