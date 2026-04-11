import client/generated/libero/rpc/fizzbuzz as rpc_fizzbuzz
import gleam/int
import gleam/list
import libero/error.{
  type Never, type RpcError, AppError, InternalError, MalformedRequest,
  UnknownFunction,
}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

// ---- Model ----

/// One demo per RPC function. Each slot holds the last response from
/// that RPC (either a human-readable message or an error string).
pub type Model {
  Model(
    classify: Slot,
    range: Slot,
    crash: Slot,
    classify_input: String,
    range_from: String,
    range_to: String,
    crash_input: String,
  )
}

pub type Slot {
  Idle
  Showing(String)
  Errored(String)
}

// ---- Messages ----

pub type Msg {
  ClassifyInputChanged(String)
  RangeFromChanged(String)
  RangeToChanged(String)
  CrashInputChanged(String)

  ClassifySubmitted
  RangeSubmitted
  CrashSubmitted

  ClassifyResponse(Result(String, RpcError(Never)))
  RangeResponse(Result(List(String), RpcError(String)))
  CrashResponse(Result(String, RpcError(Never)))
}

// ---- Init ----

pub fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      classify: Idle,
      range: Idle,
      crash: Idle,
      classify_input: "15",
      range_from: "1",
      range_to: "15",
      crash_input: "boom",
    ),
    effect.none(),
  )
}

// ---- Update ----

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ClassifyInputChanged(v) -> #(Model(..model, classify_input: v), effect.none())
    RangeFromChanged(v) -> #(Model(..model, range_from: v), effect.none())
    RangeToChanged(v) -> #(Model(..model, range_to: v), effect.none())
    CrashInputChanged(v) -> #(Model(..model, crash_input: v), effect.none())

    ClassifySubmitted ->
      case int.parse(model.classify_input) {
        Ok(n) -> #(
          model,
          rpc_fizzbuzz.classify(n: n, on_response: ClassifyResponse),
        )
        Error(_) -> #(
          Model(..model, classify: Errored("not a whole number")),
          effect.none(),
        )
      }

    RangeSubmitted -> {
      let parsed = case int.parse(model.range_from), int.parse(model.range_to) {
        Ok(from), Ok(to) -> Ok(#(from, to))
        _, _ -> Error("from and to must be whole numbers")
      }
      case parsed {
        Ok(#(from, to)) -> #(
          model,
          rpc_fizzbuzz.range(from: from, to: to, on_response: RangeResponse),
        )
        Error(message) -> #(
          Model(..model, range: Errored(message)),
          effect.none(),
        )
      }
    }

    CrashSubmitted -> #(
      model,
      rpc_fizzbuzz.crash(label: model.crash_input, on_response: CrashResponse),
    )

    // --- Classify (bare return, RpcError(Never)) ---
    ClassifyResponse(Ok(label)) -> #(
      Model(..model, classify: Showing(label)),
      effect.none(),
    )
    ClassifyResponse(Error(e)) -> #(
      Model(..model, classify: Errored(framework_message_never(e))),
      effect.none(),
    )

    // --- Range (wrapped return, RpcError(String)) ---
    RangeResponse(Ok(labels)) -> #(
      Model(..model, range: Showing(string_join_commas(labels))),
      effect.none(),
    )
    RangeResponse(Error(AppError(message))) -> #(
      Model(..model, range: Errored("server rejected: " <> message)),
      effect.none(),
    )
    RangeResponse(Error(e)) -> #(
      Model(..model, range: Errored(framework_message_app(e))),
      effect.none(),
    )

    // --- Crash (bare return, RpcError(Never); InternalError on panic) ---
    CrashResponse(Ok(label)) -> #(
      Model(..model, crash: Showing(label)),
      effect.none(),
    )
    CrashResponse(Error(e)) -> #(
      Model(..model, crash: Errored(framework_message_never(e))),
      effect.none(),
    )
  }
}

fn framework_message_never(e: RpcError(Never)) -> String {
  case e {
    MalformedRequest -> "malformed request"
    UnknownFunction(name) -> "unknown function: " <> name
    InternalError(trace_id) ->
      "server panicked — trace " <> trace_id <> " (see server logs)"
    AppError(_) -> "impossible"
  }
}

fn framework_message_app(e: RpcError(String)) -> String {
  case e {
    AppError(message) -> "app error: " <> message
    MalformedRequest -> "malformed request"
    UnknownFunction(name) -> "unknown function: " <> name
    InternalError(trace_id) ->
      "server panicked — trace " <> trace_id <> " (see server logs)"
  }
}

fn string_join_commas(items: List(String)) -> String {
  case items {
    [] -> "(empty)"
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, item) { acc <> ", " <> item })
  }
}

// ---- View ----

pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text("Libero · FizzBuzz")]),
    html.p([attribute.class("intro")], [
      html.text(
        "Three RPC calls over libero — each demonstrates a different "
        <> "corner of the typed wire contract.",
      ),
    ]),
    view_classify(model),
    view_range(model),
    view_crash(model),
  ])
}

fn view_classify(model: Model) -> Element(Msg) {
  html.section([], [
    html.h2([], [html.text("classify(n)")]),
    html.p([attribute.class("hint")], [
      html.text(
        "Bare String return. Client envelope is Result(String, RpcError(Never)).",
      ),
    ]),
    html.form([event.on_submit(fn(_) { ClassifySubmitted })], [
      html.label([], [
        html.text("n = "),
        html.input([
          attribute.type_("number"),
          attribute.value(model.classify_input),
          event.on_input(ClassifyInputChanged),
        ]),
      ]),
      html.text(" "),
      html.button([attribute.type_("submit")], [html.text("Classify")]),
    ]),
    view_slot(model.classify),
  ])
}

fn view_range(model: Model) -> Element(Msg) {
  html.section([], [
    html.h2([], [html.text("range(from, to)")]),
    html.p([attribute.class("hint")], [
      html.text(
        "Wrapped return — Result(List(String), RpcError(String)). Try from=10, "
        <> "to=1 to see the AppError branch fire.",
      ),
    ]),
    html.form([event.on_submit(fn(_) { RangeSubmitted })], [
      html.label([], [
        html.text("from = "),
        html.input([
          attribute.type_("number"),
          attribute.value(model.range_from),
          event.on_input(RangeFromChanged),
        ]),
      ]),
      html.text(" "),
      html.label([], [
        html.text("to = "),
        html.input([
          attribute.type_("number"),
          attribute.value(model.range_to),
          event.on_input(RangeToChanged),
        ]),
      ]),
      html.text(" "),
      html.button([attribute.type_("submit")], [html.text("Generate range")]),
    ]),
    view_slot(model.range),
  ])
}

fn view_crash(model: Model) -> Element(Msg) {
  html.section([], [
    html.h2([], [html.text("crash(label)")]),
    html.p([attribute.class("hint")], [
      html.text(
        "Bare return that panics on the label \"boom\". Watch the client "
        <> "receive InternalError(trace_id) while the server logs the panic "
        <> "via libero's PanicInfo bubble-up. Anything other than \"boom\" "
        <> "returns a normal string.",
      ),
    ]),
    html.form([event.on_submit(fn(_) { CrashSubmitted })], [
      html.label([], [
        html.text("label = "),
        html.input([
          attribute.type_("text"),
          attribute.value(model.crash_input),
          event.on_input(CrashInputChanged),
        ]),
      ]),
      html.text(" "),
      html.button([attribute.type_("submit")], [html.text("Call crash")]),
    ]),
    view_slot(model.crash),
  ])
}

fn view_slot(slot: Slot) -> Element(Msg) {
  case slot {
    Idle -> html.div([attribute.class("slot idle")], [html.text("—")])
    Showing(value) ->
      html.div([attribute.class("slot ok")], [html.text(value)])
    Errored(message) ->
      html.div([attribute.class("slot err")], [html.text(message)])
  }
}
