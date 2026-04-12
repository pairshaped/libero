//// ETF (Erlang Term Format) wire codec for Libero RPC.
////
//// Encoding walks any Gleam value through `erlang:term_to_binary/1`,
//// which preserves the full Erlang type structure - atoms, tuples,
//// maps, lists - natively. Decoding uses `erlang:binary_to_term/1`
//// to reconstruct the original terms. No manual walk or rebuild is
//// needed because ETF is the BEAM's native serialization format.
////
//// **Wire shape:**
//// - The call envelope is `{fn_name_binary, args_list}` - a 2-tuple
////   where the first element is a UTF-8 binary (Gleam String) and the
////   second is a list of arbitrary terms.
//// - The response is the Gleam value directly (e.g. `Ok(value)` or
////   `Error(MalformedRequest)`), serialized as ETF.

import gleam/dynamic.{type Dynamic}

// ---------- Encoder ----------

/// Encode any Gleam value to an ETF binary.
pub fn encode(value: a) -> BitArray {
  ffi_encode(coerce(value))
}

// ---------- Decoder (incoming call envelope) ----------

pub type DecodeError {
  DecodeError(message: String)
}

/// Parse a `{<<"fn_name">>, [arg1, arg2, ...]}` tuple from an ETF binary.
/// Returns the function name and args list. Since `binary_to_term`
/// returns real Erlang terms, no rebuild step is needed - atoms are
/// atoms, tuples are tuples, maps are maps.
pub fn decode_call(
  data: BitArray,
) -> Result(#(String, List(Dynamic)), DecodeError) {
  ffi_decode_call(data)
}

@external(erlang, "libero_wire_ffi", "decode_call")
fn ffi_decode_call(
  data: BitArray,
) -> Result(#(String, List(Dynamic)), DecodeError)

@external(erlang, "libero_ffi", "encode")
fn ffi_encode(value: Dynamic) -> BitArray

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic
