/// SharedState is a unit type — actual state lives in ETS.
/// This satisfies the dispatch.handle(state:, data:) signature
/// that libero generates.
pub type SharedState {
  SharedState
}

pub fn new() -> SharedState {
  SharedState
}
