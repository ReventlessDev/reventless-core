// Product aggregate specification.
// A product listing with name, description, price and an image.
//
// `@storageRef("productImages")` on the command inputs is what makes `imageUrl`
// an upload rather than a free-text field: the store name is unqualified, so it
// resolves to this plugin's own `Catalog.productImages`, and the platform must
// provision it. Events carry the resulting ref as a plain string — the
// annotation describes an input, not a stored value.

@@reventless.spec

@schema
type command =
  | Add({
      name: string,
      description: string,
      price: float,
      @storageRef("productImages") imageUrl: string,
    })
  | UpdateName({name: string})
  | UpdateDescription({description: string})
  | UpdatePrice({price: float})
  | UpdateImage({@storageRef("productImages") imageUrl: string})

@schema
type event =
  | Added({name: string, description: string, price: float, imageUrl: string})
  | NameUpdated({name: string})
  | DescriptionUpdated({description: string})
  | PriceUpdated({price: float})
  | ImageUpdated({imageUrl: string})

@schema
type error =
  | ProductAlreadyExists
  | ProductNotFound
