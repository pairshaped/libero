//// ETF (Erlang Term Format) wire codec for Libero RPC.
////
//// Encoding walks any Gleam value through `erlang:term_to_binary/1`,
//// which preserves the full Erlang type structure - atoms, tuples,
//// maps, lists - natively. Decoding uses `erlang:binary_to_term/1`
//// to reconstruct the original terms. No manual walk or rebuild is
//// needed because ETF is the BEAM's native serialization format.
////
//// **Wire shape:**
//// - The call envelope is `{module_name_binary, msg_from_client_value}` - a
////   2-tuple where the first element is a UTF-8 binary (Gleam String)
////   naming the shared module, and the second is the typed MsgFromClient
////   value serialized as a native ETF term.
//// - The response is the Gleam value directly (e.g. `Ok(value)` or
////   `Error(MalformedRequest)`), serialized as ETF.
////
//// **Cross-target:** `encode` and `decode` work on both Erlang and
//// JavaScript targets. The Erlang path uses the BEAM's native
//// `term_to_binary` / `binary_to_term`. The JavaScript path uses
//// libero's own ETF encoder/decoder in `rpc_ffi.mjs`, which requires
//// that any custom-type constructors in the value have been registered
//// via `register_all()` at boot (libero's generator emits that
//// registration for every type reachable from the MsgFromClient/MsgFromServer type graph).

import gleam/dynamic.{type Dynamic}

// ---------- Encoder ----------

/// Encode any Gleam value to an ETF binary.
///
/// Works on both Erlang and JavaScript targets. Used internally by
/// libero to serialize RPC responses, and also available for non-RPC
/// paths (e.g. passing server-rendered state into a Lustre SPA via
/// flags, in the Elm "init flags" style).
@external(erlang, "libero_ffi", "encode")
@external(javascript, "./rpc_ffi.mjs", "encode_value")
pub fn encode(value: a) -> BitArray

// ---------- Decoder (arbitrary value) ----------

/// Decode an ETF binary into an arbitrary Gleam value.
///
/// Works on both Erlang and JavaScript targets. Use this for non-RPC
/// paths - for example, reading server-rendered state from Lustre
/// flags on client boot. For decoding incoming RPC call envelopes
/// specifically, use `decode_call` instead.
///
/// Any custom types in the decoded value must be reachable from the
/// MsgFromClient/MsgFromServer type graph so their constructors are registered with the
/// JavaScript codec (via `register_all()` at boot). On Erlang this
/// is automatic because atoms are pre-registered by the generated
/// `rpc_atoms` module.
///
/// **Warning: type safety is the caller's responsibility.** The return
/// type `a` is unwitnessed — the function returns whatever the ETF
/// binary deserializes to, cast to the caller's expected type. A
/// version skew between client and server will produce silent data
/// corruption, not a runtime error. This is an intentional tradeoff
/// for ergonomics in controlled deployments where both sides are
/// built from the same source.
///
/// **Panics on malformed input.** In a typical libero deployment
/// both sides are controlled, so this is a sharp-edge check rather
/// than a user-facing error. For untrusted input, use `decode_safe`
/// which returns a `Result`.
@external(erlang, "libero_ffi", "decode")
@external(javascript, "./rpc_ffi.mjs", "decode_value")
pub fn decode(data: BitArray) -> a

// ---------- Safe decoder (arbitrary value) ----------

/// Decode an ETF binary into an arbitrary Gleam value, returning a
/// `Result` instead of panicking on malformed input.
///
/// Use this for non-RPC paths where the input may be untrusted or
/// user-influenced - for example, reading server-rendered state from
/// Lustre flags on client boot where the binary may have been
/// corrupted in transit.
pub fn decode_safe(data: BitArray) -> Result(a, DecodeError) {
  ffi_decode_safe(data)
}

@external(erlang, "libero_ffi", "decode_safe")
@external(javascript, "./rpc_ffi.mjs", "decode_safe")
fn ffi_decode_safe(data: BitArray) -> Result(a, DecodeError) {
  let _ = data
  panic as "libero/wire.ffi_decode_safe is unreachable - externals handle both targets"
}

// ---------- Decoder (incoming call envelope) ----------

pub type DecodeError {
  DecodeError(message: String)
}

/// Parse a `{<<"module_name">>, toserver_value}` tuple from an ETF binary.
/// Returns the module name and the raw Dynamic value to be coerced.
/// Since `binary_to_term` returns real Erlang terms, no rebuild step
/// is needed - atoms are atoms, tuples are tuples, maps are maps.
///
/// This is specifically for RPC call envelopes. For decoding
/// arbitrary values, use `decode`.
pub fn decode_call(data: BitArray) -> Result(#(String, Dynamic), DecodeError) {
  ffi_decode_call(data)
}

// nolint: avoid_panic, discarded_result -- Erlang-only @external; JS fallback is unreachable
@external(erlang, "libero_wire_ffi", "decode_call")
fn ffi_decode_call(data: BitArray) -> Result(#(String, Dynamic), DecodeError) {
  let _ = data
  panic as "libero/wire.decode_call is a server-side function, unreachable on JavaScript target"
}

// ---------- Call envelope encoder ----------

/// Encode a call envelope: `{module_name, msg}` as ETF binary.
/// Used by generated client send_to_server functions to pack a MsgFromClient value
/// for transport to the server.
pub fn encode_call(module module: String, msg msg: a) -> BitArray {
  encode(#(module, msg))
}

// ---------- Frame tagging ----------

/// Tag a response frame so the JS client routes it to the FIFO callback queue.
pub fn tag_response(data: BitArray) -> BitArray {
  <<0, data:bits>>
}

/// Tag a push frame so the JS client routes it to the push handler.
/// The value is an ETF-encoded `{module_name, msg}` tuple so the
/// client knows which handler to invoke.
pub fn tag_push(module module: String, msg msg: a) -> BitArray {
  let data = encode(#(module, msg))
  <<1, data:bits>>
}

// ---------- Coerce ----------

/// Cast a Dynamic value to any type.
/// Used by generated server dispatch code to coerce the decoded
/// MsgFromClient value to its typed form. Safe when client and server are
/// built from the same source (the generator guarantees the types match).
///
/// **Warning: unwitnessed cast.** Same safety model as `decode` —
/// type correctness depends on both sides being built from the same
/// source. A mismatch produces silent data corruption.
@external(erlang, "libero_ffi", "identity")
@external(javascript, "./rpc_ffi.mjs", "identity")
pub fn coerce(value: dynamic.Dynamic) -> a {
  let _ = value
  panic as "unreachable"
}
