pub type Item {
  Item(id: Int, name: String)
}

pub type ItemParams {
  ItemParams(name: String)
}

pub type ItemError {
  NotFound
  Invalid
}
