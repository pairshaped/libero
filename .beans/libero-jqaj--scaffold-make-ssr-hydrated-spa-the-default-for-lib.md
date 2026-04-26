---
# libero-jqaj
title: 'Scaffold: make SSR-hydrated SPA the default for libero new'
status: todo
type: feature
created_at: 2026-04-26T03:34:28Z
updated_at: 2026-04-26T03:34:28Z
---

Follow-up to libero-nm1e (isomorphic routing). Once ssr.handle_request and ssr.boot_script have shipped and gotten real-app mileage, update the libero new scaffold so SSR-hydrated SPA is the default shape.

Scope:
- Update codegen-generated server entry (src/libero/codegen.gleam main.gleam template) to wire ssr.handle_request for non-/ws, non-/rpc, non-/web/* paths.
- Add starter Route enum + parse_route + route_to_path + view to scaffolded shared/.
- Update starter_spa template (src/libero/cli/templates.gleam) to use modem.init and decode_flags in client init.
- Add page/load/render skeleton to scaffolded src/server/ (likely a new src/server/page.gleam containing load_page and render_page stubs).
- Remove --web flag from cli.gleam (it's redundant once SSR is default).
- Add --no-client flag for the rare server-only project case (skips clients/web/, omits SSR wiring from server entry, drops Route/view from shared/).
- Update test/libero/cli_new_test.gleam to verify the new default and the --no-client opt-out.
- Update docs/build-a-checklist-app.md guide if it references the old scaffold shape.

Wait until libero-nm1e has shipped and we've used it in at least one real (non-example) app before starting — easier to encode the right defaults once API has been validated.

Depends on libero-nm1e.
