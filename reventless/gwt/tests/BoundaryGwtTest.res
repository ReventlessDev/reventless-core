// The boundary test `generate-plugin` writes for every system. A boundary with a
// slice that cannot derive its partition fails it, with the reasons, though every
// slice in it still passes its own test.

open JestGlobals

@schema
type addCategoryCommand = AddCategory({categoryId: string})
@schema
type addCategoryConsumed = CategoryAdded({categoryId: string})
@schema
type categoryAddedEvent = CategoryAdded({categoryId: string})

@schema
type addProductCommand = AddProduct({productId: string, categoryId: string})
@schema
type addProductConsumed =
  | ProductAdded({productId: string})
  | CategoryAdded({categoryId: string})
  | CategoryArchived({categoryId: string})
@schema
type productAddedEvent = ProductAdded({productId: string, categoryId: string})

let catalog: array<Reventless.DcbTag.sliceSchemas> = [
  {
    name: "AddCategory",
    commandSchema: addCategoryCommandSchema->S.castToUnknown,
    consumedEventSchema: addCategoryConsumedSchema->S.castToUnknown,
    eventSchema: categoryAddedEventSchema->S.castToUnknown,
  },
  {
    name: "AddProduct",
    commandSchema: addProductCommandSchema->S.castToUnknown,
    consumedEventSchema: addProductConsumedSchema->S.castToUnknown,
    eventSchema: productAddedEventSchema->S.castToUnknown,
  },
]

// Writes two ids and reads both off an event nothing in the boundary writes, which
// leaves it no partition.
@schema
type imagesCommand = AttachProductImage({productId: string, uploadId: string})
@schema
type imagesConsumed =
  | ImageUploaded({productId: string, uploadId: string})
  | ProductImageAttached({uploadId: string})
@schema
type imagesEvent = ProductImageAttached({productId: string, uploadId: string})

let withUnresolvableSlice = catalog->Array.concat([
  {
    Reventless.DcbTag.name: "ProductImages",
    commandSchema: imagesCommandSchema->S.castToUnknown,
    consumedEventSchema: imagesConsumedSchema->S.castToUnknown,
    eventSchema: imagesEventSchema->S.castToUnknown,
  },
])

describe("a system's boundary test", () => {
  testSync("a boundary whose slices all derive their partition passes", () =>
    expect(Boundary_GWT.resolves(~name="Catalog", catalog))->toEqual(Outcome.pass)
  )

  testSync("one slice with no partition fails the boundary, naming it", () =>
    switch Boundary_GWT.resolves(~name="Catalog", withUnresolvableSlice) {
    | Error(PartitionUnresolved({boundary, reasons})) => {
        expect(boundary)->toBe("Catalog")
        expect(reasons->Array.some(r => r->String.includes("ProductImages")))->toBe(true)
      }
    | other => expect(other)->toEqual(Outcome.pass)
    }
  )
})
