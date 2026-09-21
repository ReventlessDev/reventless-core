// A category's id: the Category stream and the Categories rows are keyed by it.
include Reventless.Id.Make({
  let key = "categoryId"
})
