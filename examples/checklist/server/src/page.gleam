import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import handler
import handler_context.{type HandlerContext}
import libero/remote_data.{Failure, Success}
import libero/ssr
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import mist.{type Connection, type ResponseData}
import shared/router.{type Route}
import shared/views.{type Model, type Msg, Model}

pub fn load_page(
  _req: Request(Connection),
  route: Route,
  handler_ctx: HandlerContext,
) -> Result(Model, Response(ResponseData)) {
  let #(result, _) = handler.get_items(handler_ctx:)
  let items = case result {
    Ok(items) -> Success(items)
    Error(err) -> Failure(err)
  }
  Ok(Model(route:, items:, input: ""))
}

pub fn render_page(_route: Route, model: Model) -> Element(Msg) {
  html.html([attribute.attribute("lang", "en")], [
    html.head([], [
      html.meta([attribute.attribute("charset", "utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.attribute("content", "width=device-width, initial-scale=1"),
      ]),
      html.title([], "Checklist"),
    ]),
    html.body([], [
      html.div([attribute.id("app")], [views.view(model)]),
      ssr.boot_script(client_module: "/web/web/app.mjs", flags: model),
    ]),
  ])
}
