import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/result
import libero/push

fn receive_push(timeout: Int) -> Result(BitArray, Nil) {
  let selector =
    process.new_selector()
    |> process.select_record(
      tag: atom.create("libero_push"),
      fields: 1,
      mapping: fn(record) {
        { use frame <- decode.field(1, decode.bit_array)
          decode.success(frame)
        }
        |> decode.run(record, _)
        |> result.unwrap(<<>>)
      },
    )
  process.selector_receive(from: selector, within: timeout)
}

pub fn init_is_idempotent_test() {
  push.init()
  push.init()
}

pub fn join_and_receive_push_test() {
  push.init()
  push.join(topic: "test_push_join")

  push.send_to_clients(
    topic: "test_push_join",
    module: "shared/messages",
    msg: "hello",
  )

  let assert Ok(_frame) = receive_push(500)

  push.leave(topic: "test_push_join")
}

pub fn leave_stops_receiving_test() {
  push.init()
  push.join(topic: "test_push_leave")
  push.leave(topic: "test_push_leave")

  push.send_to_clients(
    topic: "test_push_leave",
    module: "shared/messages",
    msg: "should not arrive",
  )

  let assert Error(Nil) = receive_push(100)
}

pub fn register_and_send_to_client_test() {
  push.init()
  push.register(client_id: "test_push_user_1")

  push.send_to_client(
    client_id: "test_push_user_1",
    module: "shared/messages",
    msg: "direct",
  )

  let assert Ok(_frame) = receive_push(500)

  push.unregister(client_id: "test_push_user_1")
}
