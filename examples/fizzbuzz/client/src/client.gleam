//// FizzBuzz over libero RPC — client entry point.

import client/app
import lustre

pub fn main() -> Nil {
  let lustre_app = lustre.application(app.init, app.update, app.view)
  let assert Ok(_) = lustre.start(lustre_app, "#app", Nil)
  Nil
}
