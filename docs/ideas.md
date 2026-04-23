# Ideas

## ~~`libero new --database sqlite`~~ ✓ Implemented

Shipped in v4.2. `--database pg` and `--database sqlite` are supported.
See `cli.gleam` and `cli/templates/db.gleam`.

## Future ideas

- Type alias walk-through in walker (currently skips aliases silently)
- Request IDs in wire protocol for robust response matching under panics
- Reconnection strategy for push handlers (currently consumer responsibility)
