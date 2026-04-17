/// Framework-level errors only. Domain errors (TodoError) live inside
/// each `MsgFromServer` variant's `Result`. Libero treats `AppError`
/// values as opaque - a panic, an unknown RPC, or a handler returning
/// `Error(app_err)` all surface to the client through `RpcError` rather
/// than through a typed `MsgFromServer` payload.
pub type AppError {
  AppError(reason: String)
}
