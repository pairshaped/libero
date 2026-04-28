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

// -- is_builtin --

pub fn is_builtin_recognises_primitive_names_test() {
  let assert True = field_type.is_builtin("Int")
  let assert True = field_type.is_builtin("String")
  let assert True = field_type.is_builtin("Bool")
  let assert True = field_type.is_builtin("Float")
  let assert True = field_type.is_builtin("BitArray")
  let assert True = field_type.is_builtin("Nil")
  let assert True = field_type.is_builtin("List")
  let assert True = field_type.is_builtin("Result")
  let assert True = field_type.is_builtin("Option")
  let assert True = field_type.is_builtin("Dict")
}

pub fn is_builtin_rejects_user_type_names_test() {
  let assert False = field_type.is_builtin("Item")
  let assert False = field_type.is_builtin("WidgetParams")
  let assert False = field_type.is_builtin("")
}

// -- builtin_field_type error path --

pub fn builtin_field_type_rejects_non_builtin_name_test() {
  let assert Error(Nil) =
    field_type.builtin_field_type(
      name: "NotABuiltin",
      parameters: [],
      recurse: fn(_a) { field_type.IntField },
    )
}

pub fn builtin_field_type_rejects_result_with_wrong_arity_test() {
  let assert Error(Nil) =
    field_type.builtin_field_type(
      name: "Result",
      parameters: [],
      recurse: fn(_a) { field_type.IntField },
    )
}

pub fn builtin_field_type_rejects_option_with_extra_params_test() {
  let assert Error(Nil) =
    field_type.builtin_field_type(
      name: "Option",
      parameters: [1, 2],
      recurse: fn(_a) { field_type.IntField },
    )
}

// -- last_segment --

pub fn last_segment_returns_last_part_of_path_test() {
  let assert "types" = field_type.last_segment("shared/types")
  let assert "handler" = field_type.last_segment("server/handler")
}

pub fn last_segment_returns_whole_string_when_no_separator_test() {
  let assert "hello" = field_type.last_segment("hello")
}
