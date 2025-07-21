let supplementTagsWithName = (tags, name) =>
  switch tags {
  | Some(t) =>
    switch t->Js.Dict.get("Name") {
    | None => t->Js.Dict.set("Name", name)
    | Some(_) => ()
    }
    t
  | None =>
    let t = Js.Dict.empty()
    t->Js.Dict.set("Name", name)
    t
  }
