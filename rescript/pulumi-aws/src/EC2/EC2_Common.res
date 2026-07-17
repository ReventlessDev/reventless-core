let supplementTagsWithName = (tags, name) =>
  switch tags {
  | Some(t) =>
    switch t->Dict.get("Name") {
    | None => t->Dict.set("Name", name)
    | Some(_) => ()
    }
    t
  | None =>
    let t = Dict.make()
    t->Dict.set("Name", name)
    t
  }
