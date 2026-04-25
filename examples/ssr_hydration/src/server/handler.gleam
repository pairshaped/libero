import ets_store
import server/handler_context.{type HandlerContext}

// Each pub function below is an RPC endpoint. Libero's scanner detects these
// by checking: (1) public, (2) last param is HandlerContext, (3) returns
// #(Result(value, error), HandlerContext), (4) all types are shared or builtins.
//
// From these signatures, codegen generates:
//   - ClientMsg variants: Increment, Decrement, GetCounter
//   - A dispatch module routing each variant to its handler
//   - Typed client stubs: rpc.increment(on_response: ..)

// increment -> ClientMsg variant: Increment (no params)
// Client stub: rpc.increment(on_response: CounterChanged)
pub fn increment(
  state state: HandlerContext,
) -> #(Result(Int, Nil), HandlerContext) {
  #(Ok(ets_store.increment()), state)
}

// decrement -> ClientMsg variant: Decrement (no params)
// Client stub: rpc.decrement(on_response: CounterChanged)
pub fn decrement(
  state state: HandlerContext,
) -> #(Result(Int, Nil), HandlerContext) {
  #(Ok(ets_store.decrement()), state)
}

// get_counter -> ClientMsg variant: GetCounter (no params)
// Client stub: rpc.get_counter(on_response: CounterChanged)
pub fn get_counter(
  state state: HandlerContext,
) -> #(Result(Int, Nil), HandlerContext) {
  #(Ok(ets_store.get()), state)
}
