//// Simple ETS-backed integer counter.

@external(erlang, "counter_ets_ffi", "init")
pub fn init() -> Nil

@external(erlang, "counter_ets_ffi", "get")
pub fn get() -> Int

@external(erlang, "counter_ets_ffi", "increment")
pub fn increment() -> Int

@external(erlang, "counter_ets_ffi", "decrement")
pub fn decrement() -> Int
