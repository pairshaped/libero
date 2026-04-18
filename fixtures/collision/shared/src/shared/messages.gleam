import shared/a
import shared/b

pub type MsgFromClient {
  LoadA
  LoadB
}

pub type MsgFromServer {
  LoadedA(Result(a.Status, String))
  LoadedB(Result(b.Status, String))
}
