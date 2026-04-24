# Request IDs in Wire Protocol — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add monotonic request IDs to the wire protocol so responses are matched by ID instead of FIFO order, eliminating silent response misrouting after timeouts.

**Architecture:** The client assigns an incrementing integer to each `send()` call and includes it in the ETF call envelope (3-tuple instead of 2-tuple). The server echoes the ID back in the response frame header (4 bytes after the tag byte). The client matches responses by ID via a Map instead of a FIFO array. Timeouts just delete the Map entry — no need to close the WebSocket.

**Tech Stack:** Gleam (wire.gleam, codegen.gleam, ssr.gleam), Erlang (libero_wire_ffi.erl), JavaScript (rpc_ffi.mjs)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/libero/wire.gleam` | Modify | `decode_call` returns 3-tuple with request ID; `tag_response` accepts request ID; `encode_call` includes request ID |
| `src/libero_wire_ffi.erl` | Modify | Pattern match 3-tuple `{Module, RequestId, Value}` |
| `src/libero/rpc_ffi.mjs` | Modify | Request ID counter, `encode_call` writes 3-tuple, response handler extracts ID from frame, Map-based callback matching |
| `src/libero/codegen.gleam` | Modify | Generated dispatch extracts request ID from `decode_call`, threads it through `dispatch` → `safe_encode` → `tag_response` |
| `src/libero/ssr.gleam` | Modify | `ssr.call` passes a dummy request ID (0) in `encode_call` and skips the ID bytes in the response frame |
| `test/libero/wire_test.gleam` | Modify | Update envelope helpers and assertions for 3-tuple format |
| `test/libero/wire_roundtrip_test.gleam` | Modify | Update `roundtrip` helper to use 3-tuple envelope |
| `llms.txt` | Modify | Update wire format documentation |

---

### Task 1: Update wire.gleam — decode_call return type and encode_call signature

**Files:**
- Modify: `src/libero/wire.gleam:99-131`
- Modify: `src/libero_wire_ffi.erl:1-27`
- Test: `test/libero/wire_test.gleam`

- [ ] **Step 1: Update the Erlang FFI to accept 3-tuple**

In `src/libero_wire_ffi.erl`, change the pattern match from 2-tuple to 3-tuple:

```erlang
decode_call(Bin) when is_binary(Bin) ->
    try erlang:binary_to_term(Bin, [safe]) of
        {Module, RequestId, Value} when is_binary(Module), is_integer(RequestId) ->
            {ok, {Module, RequestId, Value}};
        _ ->
            {error, {decode_error, <<"invalid call envelope: expected {binary, integer, value} tuple">>}}
    catch
        _:_ ->
            {error, {decode_error, <<"invalid ETF binary">>}}
    end;
decode_call(_) ->
    {error, {decode_error, <<"expected a binary (BitArray)">>}}.
```

- [ ] **Step 2: Update decode_call return type in wire.gleam**

Change the return type at `src/libero/wire.gleam:106`:

```gleam
pub fn decode_call(data: BitArray) -> Result(#(String, Int, Dynamic), DecodeError) {
  ffi_decode_call(data)
}

@external(erlang, "libero_wire_ffi", "decode_call")
fn ffi_decode_call(data: BitArray) -> Result(#(String, Int, Dynamic), DecodeError) {
  let _ = data
  panic as "libero/wire.decode_call is a server-side function, unreachable on JavaScript target"
}
```

- [ ] **Step 3: Update encode_call to include request ID**

Change `encode_call` at `src/libero/wire.gleam:122-124`:

```gleam
pub fn encode_call(module module: String, request_id request_id: Int, msg msg: a) -> BitArray {
  encode(#(module, request_id, msg))
}
```

- [ ] **Step 4: Update tag_response to include request ID**

Change `tag_response` at `src/libero/wire.gleam:129-131`:

```gleam
pub fn tag_response(request_id request_id: Int, data data: BitArray) -> BitArray {
  <<0, request_id:32, data:bits>>
}
```

- [ ] **Step 5: Update wire_test.gleam for 3-tuple format**

Update the helper and all assertions in `test/libero/wire_test.gleam`:

```gleam
fn encode_call_envelope(module: String, request_id: Int, value: Dynamic) -> BitArray {
  ffi_encode(coerce(#(module, request_id, value)))
}
```

Update each test to use 3-tuple patterns:

```gleam
pub fn decode_call_with_nil_value_test() {
  let envelope = encode_call_envelope("shared/records", 1, coerce(Nil))
  let assert Ok(#("shared/records", 1, _value)) = wire.decode_call(envelope)
}

pub fn decode_call_with_int_value_test() {
  let envelope = encode_call_envelope("shared/fizzbuzz", 42, coerce(15))
  let assert Ok(#("shared/fizzbuzz", 42, value)) = wire.decode_call(envelope)
  let result: Int = unsafe_coerce(value)
  let assert 15 = result
}

pub fn decode_call_with_string_value_test() {
  let envelope = encode_call_envelope("shared/records", 99, coerce("hello"))
  let assert Ok(#("shared/records", 99, value)) = wire.decode_call(envelope)
  let result: String = unsafe_coerce(value)
  let assert "hello" = result
}

pub fn decode_call_wrong_shape_test() {
  let bad = ffi_encode(coerce(42))
  let assert Error(wire.DecodeError(
    message: "invalid call envelope: expected {binary, integer, value} tuple",
  )) = wire.decode_call(bad)
}

pub fn encode_call_decode_call_roundtrip_string_test() {
  let encoded = wire.encode_call(module: "core/messages", request_id: 1, msg: "hello")
  let assert Ok(#("core/messages", 1, msg)) = wire.decode_call(encoded)
  let decoded: String = wire.coerce(msg)
  let assert "hello" = decoded
}

pub fn encode_call_decode_call_roundtrip_int_test() {
  let encoded = wire.encode_call(module: "core/messages", request_id: 7, msg: 42)
  let assert Ok(#("core/messages", 7, msg)) = wire.decode_call(encoded)
  let decoded: Int = wire.coerce(msg)
  let assert 42 = decoded
}
```

- [ ] **Step 6: Update wire_roundtrip_test.gleam helper**

In `test/libero/wire_roundtrip_test.gleam`, update the `roundtrip` helper:

```gleam
fn roundtrip(value: a) -> Dynamic {
  let envelope = ffi_encode(coerce(#("shared/test", 0, coerce(value))))
  let assert Ok(#("shared/test", 0, rebuilt)) = wire.decode_call(envelope)
  rebuilt
}
```

- [ ] **Step 7: Run tests to verify**

Run: `gleam test`
Expected: Compilation errors in codegen.gleam and ssr.gleam (they call the old signatures). Wire tests should pass.

- [ ] **Step 8: Commit**

```bash
git add src/libero/wire.gleam src/libero_wire_ffi.erl test/libero/wire_test.gleam test/libero/wire_roundtrip_test.gleam
git commit -m "feat: add request ID to wire protocol envelope and response frame"
```

---

### Task 2: Update codegen.gleam — thread request ID through generated dispatch

**Files:**
- Modify: `src/libero/codegen.gleam:64-206`
- Test: `test/libero/codegen_test.gleam` (existing snapshot tests)

- [ ] **Step 1: Update case arms to extract request ID from decode_call**

In `src/libero/codegen.gleam`, update the single-handler case arm (around line 73):

Change pattern from `Ok(#(\"...\", msg))` to `Ok(#(\"...\", request_id, msg))`:

```gleam
[single_handler] -> {
  let alias = handler_alias(single_handler)
  Ok(
    "    Ok(#(\""
    <> m.module_path
    <> "\", request_id, msg)) ->\n      dispatch(state, request_id, fn() { "
    <> alias
    <> ".update_from_client(msg: wire.coerce(msg), state:) })",
  )
}
```

Update the multi-handler case arm (around line 106):

```gleam
Ok(
  "    Ok(#(\""
  <> m.module_path
  <> "\", request_id, msg)) ->\n      dispatch(state, request_id, fn() {\n"
  <> body
  <> "\n        result\n      })",
)
```

- [ ] **Step 2: Update the unknown and error arms**

Update `ok_unknown_arm` (around line 116):

```gleam
let ok_unknown_arm =
  "    Ok(#(name, _request_id, _)) ->\n      #(wire.tag_response(request_id: 0, data: wire.encode(Error(UnknownFunction(name)))), None, state)"
```

Update `error_arm` (around line 119):

```gleam
let error_arm =
  "    Error(_) ->\n      #(wire.tag_response(request_id: 0, data: wire.encode(Error(MalformedRequest))), None, state)"
```

- [ ] **Step 3: Update dispatch function to accept and thread request_id**

Update the generated `dispatch` function (around line 161):

```gleam
fn dispatch(
  state state: SharedState,
  request_id request_id: Int,
  call call: fn() -> Result(#(a, SharedState), AppError),
) -> #(BitArray, Option(PanicInfo), SharedState) {
  case trace.try_call(call) {
    Ok(Ok(#(value, new_state))) ->
      safe_encode(fn() { wire.encode(Ok(value)) }, new_state, request_id, \"dispatch_encode_ok\")
    Ok(Error(app_err)) ->
      safe_encode(fn() { wire.encode(Error(error.AppError(app_err))) }, state, request_id, \"dispatch_encode_app_err\")
    Error(reason) -> {
      let trace_id = trace.new_trace_id()
      #(
        wire.tag_response(request_id:, data: wire.encode(Error(InternalError(trace_id, \"Internal server error\")))),
        Some(error.PanicInfo(trace_id:, fn_name: \"dispatch\", reason:)),
        state,
      )
    }
  }
}
```

- [ ] **Step 4: Update safe_encode to accept and thread request_id**

Update the generated `safe_encode` function (around line 190):

```gleam
fn safe_encode(
  encoder: fn() -> BitArray,
  state: SharedState,
  request_id: Int,
  fn_name: String,
) -> #(BitArray, Option(PanicInfo), SharedState) {
  case trace.try_call(encoder) {
    Ok(bytes) -> #(wire.tag_response(request_id:, data: bytes), None, state)
    Error(reason) -> {
      let trace_id = trace.new_trace_id()
      #(
        wire.tag_response(request_id:, data: wire.encode(Error(InternalError(trace_id, \"Response encoding failed\")))),
        Some(error.PanicInfo(trace_id:, fn_name:, reason:)),
        state,
      )
    }
  }
}
```

- [ ] **Step 5: Run tests to verify codegen snapshot tests update**

Run: `gleam test`
Expected: Codegen snapshot tests will need updating (they compare generated output). Update the expected output in test fixtures to match the new dispatch code shape. Other tests may still fail (ssr.gleam not yet updated).

- [ ] **Step 6: Commit**

```bash
git add src/libero/codegen.gleam
git commit -m "feat: thread request ID through generated dispatch code"
```

---

### Task 3: Update ssr.gleam — pass request ID 0 for server-side calls

**Files:**
- Modify: `src/libero/ssr.gleam:45-69`
- Test: `test/libero/ssr_test.gleam` (existing)

- [ ] **Step 1: Update ssr.call to pass request_id: 0 in encode_call**

SSR calls don't go over the wire, so request ID is irrelevant. Use 0 as a sentinel. At `src/libero/ssr.gleam:52`:

```gleam
let data = wire.encode_call(module:, request_id: 0, msg:)
```

- [ ] **Step 2: Update response parsing to skip the request ID bytes**

The response now has format `<<tag, request_id:32, etf:bytes>>`. Update the pattern match at `src/libero/ssr.gleam:57-58`:

```gleam
case response_bytes {
  <<_tag, _request_id:32, etf:bytes>> -> {
```

- [ ] **Step 3: Run tests to verify**

Run: `gleam test`
Expected: All Gleam tests pass. JS-side (rpc_ffi.mjs) is not tested by gleam test — that's next task.

- [ ] **Step 4: Commit**

```bash
git add src/libero/ssr.gleam
git commit -m "feat: update ssr.call for request ID wire format"
```

---

### Task 4: Update rpc_ffi.mjs — client-side request ID encoding and Map-based matching

**Files:**
- Modify: `src/libero/rpc_ffi.mjs:867-1121`

- [ ] **Step 1: Add request ID counter and change responseCallbacks to Map**

At `src/libero/rpc_ffi.mjs:867-870`, change:

```javascript
let ws = null;
let pendingSends = [];    // [{payload, requestId, callback, timer}]
let responseCallbacks = new Map(); // requestId -> {callback, timer}
let nextRequestId = 1;
const REQUEST_TIMEOUT_MS = 30_000;
```

- [ ] **Step 2: Update clearAllPending to iterate Map**

At `src/libero/rpc_ffi.mjs:904-916`, change:

```javascript
function clearAllPending(reason) {
  const error = makeConnectionError(reason);
  for (const entry of pendingSends) {
    if (entry.timer) clearTimeout(entry.timer);
    entry.callback(error);
  }
  for (const [, entry] of responseCallbacks) {
    if (entry.timer) clearTimeout(entry.timer);
    entry.callback(error);
  }
  pendingSends = [];
  responseCallbacks = new Map();
}
```

- [ ] **Step 3: Update ensureSocket open handler to use Map**

At `src/libero/rpc_ffi.mjs:939-944`, change:

```javascript
ws.addEventListener("open", () => {
  for (const entry of pendingSends) {
    ws.send(entry.payload);
    responseCallbacks.set(entry.requestId, { callback: entry.callback, timer: entry.timer });
  }
  pendingSends = [];
});
```

- [ ] **Step 4: Update message handler to extract request ID from response frame**

At `src/libero/rpc_ffi.mjs:947-1008`, update the response handling section. The response frame format is now `<<0x00, request_id:32-big, etf_bytes>>`:

```javascript
ws.addEventListener("message", (event) => {
  const bytes = new Uint8Array(event.data);
  const tag = bytes[0];

  if (tag === 0x01) {
    // Push frame: unchanged — payload starts at byte 1
    const payload = bytes.slice(1);
    const typedDecoder = getMsgFromServerDecoder();
    let decodedModule, decodedValue;
    if (typedDecoder) {
      const raw = decode_value_raw(payload);
      if (raw && raw[0] !== undefined && raw[1] !== undefined) {
        decodedModule = raw[0];
        decodedValue = typedDecoder(raw[1]);
      }
    } else {
      const decoded = decode_value(payload);
      if (decoded && decoded[0] !== undefined && decoded[1] !== undefined) {
        decodedModule = decoded[0];
        decodedValue = decoded[1];
      }
    }
    if (decodedModule !== undefined && decodedValue !== undefined) {
      const handler = pushHandlers.get(decodedModule);
      if (handler) handler(decodedValue);
    }
    return;
  }

  // Response frame (tag 0x00): extract request ID and match by ID.
  // Frame format: <<0x00, request_id:32-big, etf_bytes>>
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const requestId = view.getUint32(1);
  const payload = bytes.slice(5);

  let decoded;
  const typedDecoder = getMsgFromServerDecoder();
  if (typedDecoder) {
    const raw = decode_value_raw(payload);
    if (Array.isArray(raw) && raw[0] === "ok" && raw[1] !== undefined) {
      const typedVariant = typedDecoder(raw[1]);
      decoded = new Ok(typedVariant);
    } else if (Array.isArray(raw) && raw[0] === "error" && raw[1] !== undefined) {
      decoded = new ResultError(decodeRpcError(raw[1]));
    } else {
      decoded = decode_value(payload);
    }
  } else {
    decoded = decode_value(payload);
  }

  const entry = responseCallbacks.get(requestId);
  if (entry) {
    responseCallbacks.delete(requestId);
    if (entry.timer) clearTimeout(entry.timer);
    entry.callback(decoded);
  }
});
```

- [ ] **Step 5: Update send() to use request IDs**

At `src/libero/rpc_ffi.mjs:1046-1089`, rewrite `send()`:

```javascript
export function send(url, module, msg, callback) {
  ensureSocket(url);
  const requestId = nextRequestId++;
  const payload = encode_call(module, requestId, msg);

  const timer = setTimeout(() => {
    // Remove from whichever state this request is in.
    const pendingIdx = pendingSends.findIndex(e => e.requestId === requestId);
    if (pendingIdx !== -1) {
      pendingSends.splice(pendingIdx, 1);
    }
    responseCallbacks.delete(requestId);
    callback(makeConnectionError("Request timed out"));
    // No need to close the WebSocket — request IDs prevent FIFO desync.
  }, REQUEST_TIMEOUT_MS);

  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(payload);
    responseCallbacks.set(requestId, { callback, timer });
  } else {
    pendingSends.push({ payload, requestId, callback, timer });
  }
}
```

- [ ] **Step 6: Update encode_call to write 3-tuple with request ID**

At `src/libero/rpc_ffi.mjs:1112-1121`, change:

```javascript
export function encode_call(module, requestId, msg) {
  const encoder = new ETFEncoder();
  encoder.writeUint8(131); // ETF version byte
  // Envelope: {<<"module_name">>, request_id, msg_value}
  encoder.writeUint8(104); // SMALL_TUPLE_EXT
  encoder.writeUint8(3);   // arity 3
  encoder.encodeBinary(module);
  encoder.encodeTerm(requestId);
  encoder.encodeTerm(msg);
  return encoder.result();
}
```

- [ ] **Step 7: Commit**

```bash
git add src/libero/rpc_ffi.mjs
git commit -m "feat: client-side request ID encoding and Map-based response matching"
```

---

### Task 5: Update codegen snapshot tests and any remaining test fixtures

**Files:**
- Modify: `test/libero/codegen_test.gleam` (if dispatch snapshots exist)
- Modify: Any other tests that call `wire.encode_call` or `wire.tag_response`

- [ ] **Step 1: Search for all callers of the changed signatures**

Run: `grep -rn 'encode_call\|tag_response\|decode_call' test/ src/libero/ssr_test`

Fix any remaining call sites that use the old 2-arg signatures.

- [ ] **Step 2: Run the full test suite**

Run: `gleam test`
Expected: All tests pass.

- [ ] **Step 3: Run gleam format and glinter**

Run: `gleam format src/ test/ examples/ && gleam run -m glinter`
Expected: No issues.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test: update all test fixtures for request ID wire format"
```

---

### Task 6: Update docs and clean up stale comments

**Files:**
- Modify: `llms.txt`
- Modify: `src/libero/rpc_ffi.mjs` (remove stale FIFO desync comments)
- Modify: `src/libero/wire.gleam` (remove "planned for v5" comments — it's v5 now)
- Modify: `src/libero/remote_data.gleam` (remove "planned for v5" comment)

- [ ] **Step 1: Update llms.txt wire format section**

Find the wire format documentation and update:

```
- The call envelope is `{module_name_binary, request_id_int, msg_from_client_value}` — a
  3-tuple where the first element is a UTF-8 binary naming the shared module,
  the second is a monotonic request ID (integer), and the third is the typed
  MsgFromClient value serialized as a native ETF term.
- The response is `<<0x00, request_id:32-big, etf_bytes>>` where the request ID
  echoes the ID from the corresponding call.
```

- [ ] **Step 2: Remove stale "v5" comments from wire.gleam and remote_data.gleam**

Remove or update comments referencing `docs/request_ids.md` and "planned for v5" in:
- `src/libero/wire.gleam:62-63`
- `src/libero/remote_data.gleam:115-116`

- [ ] **Step 3: Update rpc_ffi.mjs comments**

Remove the FIFO desync design note in the `send()` function (lines 1049-1060) and replace with a brief note that request IDs handle matching.

- [ ] **Step 4: Run gleam format and glinter**

Run: `gleam format src/ test/ examples/ && gleam run -m glinter`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs: update wire protocol docs for request IDs, remove stale v5 comments"
```
