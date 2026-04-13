/** Pulumi resource alias — used in CustomResourceOptions.aliases to allow
    a resource's type or name to change without Pulumi treating it as a
    delete-then-create. Specify the OLD type/name so Pulumi can match the
    existing state entry against the new resource declaration. */
type t = {
  name?: string,
  @as("type") type_?: string,
}

let make = (~name=?, ~type_=?, ()): t =>
  switch (name, type_) {
  | (Some(n), Some(t)) => {name: n, type_: t}
  | (Some(n), None) => {name: n}
  | (None, Some(t)) => {type_: t}
  | (None, None) => {}
  }
