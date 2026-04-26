pub type Item {
  Item(id: Int, title: String, completed: Bool)
}

pub type ItemParams {
  ItemParams(title: String)
}

pub type ItemError {
  NotFound
  TitleRequired
}
