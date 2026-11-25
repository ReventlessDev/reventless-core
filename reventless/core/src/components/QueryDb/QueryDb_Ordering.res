/** How a store orders a list: by its keys and indexes only, or by any field with one query. */
type t =
  | Keys
  | AnyField

let answer: ref<string => t> = ref(_ => Keys)

/** The platform says, per read model, how the store it picked orders. Set before construct. */
let set = (forReadModel: string => t) => answer := forReadModel

/** How the store of this read model (by `Spec.name`) orders. `Keys` until a platform says. */
let forReadModel = (name: string): t => answer.contents(name)
