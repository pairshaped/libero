pub type MsgFromClient {
  Increment
  Decrement
  GetCounter
}

pub type MsgFromServer {
  CounterUpdated(Result(Int, Nil))
}
