import gleam/string
import libero/codegen
import libero/walker

fn sample_status_enum() -> List(walker.DiscoveredType) {
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

fn sample_record_type() -> List(walker.DiscoveredType) {
  [
    walker.DiscoveredType(
      module_path: "shared/todo",
      type_name: "Todo",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/todo",
          variant_name: "Todo",
          atom_name: "todo",
          float_field_indices: [],
          fields: [walker.StringField, walker.IntField, walker.BoolField],
        ),
      ],
    ),
  ]
}

fn sample_msg_from_server() -> List(walker.DiscoveredType) {
  [
    walker.DiscoveredType(
      module_path: "shared/messages",
      type_name: "MsgFromServer",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/messages",
          variant_name: "ItemsLoaded",
          atom_name: "items_loaded",
          float_field_indices: [],
          fields: [
            walker.ListOf(walker.UserType(
              module_path: "shared/item",
              type_name: "Item",
              args: [],
            )),
          ],
        ),
        walker.DiscoveredVariant(
          module_path: "shared/messages",
          variant_name: "StatusChanged",
          atom_name: "status_changed",
          float_field_indices: [],
          fields: [walker.StringField],
        ),
        walker.DiscoveredVariant(
          module_path: "shared/messages",
          variant_name: "Disconnected",
          atom_name: "disconnected",
          float_field_indices: [],
          fields: [],
        ),
        walker.DiscoveredVariant(
          module_path: "shared/messages",
          variant_name: "Refreshed",
          atom_name: "refreshed",
          float_field_indices: [],
          fields: [],
        ),
      ],
    ),
  ]
}

pub fn decoder_ffi_emits_enum_decoder_test() {
  let js = codegen.emit_typed_decoders(sample_status_enum())
  let assert True =
    string.contains(js, "export function decode_shared_line_item_status(term)")
  let assert True =
    string.contains(js, "return new _m_shared_line_item.Pending()")
  let assert True = string.contains(js, "return new _m_shared_line_item.Paid()")
}

pub fn enum_decoder_checks_atom_strings_test() {
  let js = codegen.emit_typed_decoders(sample_status_enum())
  let assert True = string.contains(js, "term === \"pending\"")
  let assert True = string.contains(js, "term === \"paid\"")
}

pub fn enum_decoder_throws_on_unknown_test() {
  let js = codegen.emit_typed_decoders(sample_status_enum())
  let assert True = string.contains(js, "throw new DecodeError")
}

pub fn record_decoder_calls_primitive_decoders_test() {
  let js = codegen.emit_typed_decoders(sample_record_type())
  let assert True =
    string.contains(js, "export function decode_shared_todo_todo(term)")
  let assert True = string.contains(js, "decode_string(term[1])")
  let assert True = string.contains(js, "decode_int(term[2])")
  let assert True = string.contains(js, "decode_bool(term[3])")
}

pub fn record_decoder_constructs_correct_variant_test() {
  let js = codegen.emit_typed_decoders(sample_record_type())
  let assert True =
    string.contains(js, "return new _m_shared_todo.Todo(")
}

pub fn msg_from_server_decoder_is_exported_test() {
  let js = codegen.emit_typed_decoders(sample_msg_from_server())
  let assert True =
    string.contains(js, "export function decode_msg_from_server(term)")
}

pub fn msg_from_server_switches_on_tag_test() {
  let js = codegen.emit_typed_decoders(sample_msg_from_server())
  let assert True = string.contains(js, "case \"items_loaded\":")
  let assert True = string.contains(js, "case \"status_changed\":")
  let assert True = string.contains(js, "case \"disconnected\":")
  let assert True = string.contains(js, "case \"refreshed\":")
}

pub fn msg_from_server_dispatches_all_four_variants_test() {
  let js = codegen.emit_typed_decoders(sample_msg_from_server())
  let assert True =
    string.contains(js, "return new _m_shared_messages.ItemsLoaded(")
  let assert True =
    string.contains(js, "return new _m_shared_messages.StatusChanged(")
  let assert True =
    string.contains(js, "return new _m_shared_messages.Disconnected()")
  let assert True =
    string.contains(js, "return new _m_shared_messages.Refreshed()")
}

pub fn msg_from_server_uses_list_decoder_for_list_field_test() {
  let js = codegen.emit_typed_decoders(sample_msg_from_server())
  let assert True = string.contains(js, "decode_list_of(")
  let assert True = string.contains(js, "decode_shared_item_item(t0)")
}

pub fn msg_from_server_delegates_to_per_type_decoder_test() {
  let js = codegen.emit_typed_decoders(sample_msg_from_server())
  // Entry point should delegate to the per-type decoder, not duplicate it
  let assert True =
    string.contains(js, "return decode_shared_messages_msg_from_server(term)")
}

pub fn no_msg_from_server_emits_no_entry_point_test() {
  let js = codegen.emit_typed_decoders(sample_status_enum())
  let assert False =
    string.contains(js, "export function decode_msg_from_server")
}

pub fn result_field_uses_result_decoder_test() {
  let types = [
    walker.DiscoveredType(
      module_path: "shared/result_type",
      type_name: "Wrapper",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/result_type",
          variant_name: "Wrapper",
          atom_name: "wrapper",
          float_field_indices: [],
          fields: [
            walker.ResultOf(
              ok: walker.StringField,
              err: walker.IntField,
            ),
          ],
        ),
      ],
    ),
  ]
  let js = codegen.emit_typed_decoders(types)
  let assert True = string.contains(js, "decode_result_of(")
  let assert True = string.contains(js, "decode_string(t0)")
  let assert True = string.contains(js, "decode_int(t0)")
}

pub fn option_field_uses_option_decoder_test() {
  let types = [
    walker.DiscoveredType(
      module_path: "shared/opt_type",
      type_name: "OptWrapper",
      type_params: [],
      variants: [
        walker.DiscoveredVariant(
          module_path: "shared/opt_type",
          variant_name: "OptWrapper",
          atom_name: "opt_wrapper",
          float_field_indices: [],
          fields: [walker.OptionOf(walker.StringField)],
        ),
      ],
    ),
  ]
  let js = codegen.emit_typed_decoders(types)
  let assert True = string.contains(js, "decode_option_of(")
}
