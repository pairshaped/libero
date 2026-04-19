import ets_store

pub type SharedState {
  SharedState
}

pub fn new() -> SharedState {
  ets_store.init()
  SharedState
}
