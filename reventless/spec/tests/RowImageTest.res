open JestGlobals

// The picture a reference shows a row by. Three backends read this field out of
// a stored row and one of them bakes the read into generated JavaScript, so what
// is asserted here is that they are all reading the same field — and that the
// two shapes a host actually writes (a bare ref, and a captioned set read at its
// primary member) both resolve.

type withSet = {
  productId: string,
  name: string,
  productImages: array<CaptionedImage.t>,
}
let withSetSchema = S.schema(s => {
  productId: s.matches(S.string),
  name: s.matches(S.string),
  productImages: s.matches(S.array(CaptionedImage.forField(~store="productImages"))),
})

type withScalar = {
  categoryId: string,
  categoryImage: option<UploadableImage.t>,
}
let withScalarSchema = S.schema(s => {
  categoryId: s.matches(S.string),
  categoryImage: s.matches(S.option(UploadableImage.forField(~store="categoryImages"))),
})

type withNone = {orderId: string, total: int}
let withNoneSchema = S.schema(s => {orderId: s.matches(S.string), total: s.matches(S.int)})

let sourceOf = schema => RowImage.sourceFrom(schema->S.castToUnknown)

let row = (pairs: array<(string, JSON.t)>) => Dict.fromArray(pairs)

describe("RowImage:", () => {
  testSync("reads a captioned set at its primary member", () =>
    expect(sourceOf(withSetSchema))->toEqual(
      Some({RowImage.field: "productImages", shape: Member("ref"), fromArray: true}),
    )
  )

  testSync("reads an optional scalar ref as the field itself", () =>
    expect(sourceOf(withScalarSchema))->toEqual(
      Some({RowImage.field: "categoryImage", shape: Scalar, fromArray: false}),
    )
  )

  // Most views declare no picture, and the field is null for them rather than
  // the door failing to answer.
  testSync("finds nothing where the view declares no picture", () =>
    expect(sourceOf(withNoneSchema))->toEqual(None)
  )

  testSync("extracts the primary member's ref from a stored row", () => {
    let source = {RowImage.field: "productImages", shape: Member("ref"), fromArray: true}
    let stored = row([
      (
        "productImages",
        JSON.Encode.array([
          JSON.Encode.object(
            Dict.fromArray([
              ("ref", JSON.Encode.string("productImages/primary.png")),
              ("caption", JSON.Encode.string("Front")),
            ]),
          ),
          JSON.Encode.object(Dict.fromArray([("ref", JSON.Encode.string("productImages/2.png"))])),
        ]),
      ),
    ])
    expect(stored->RowImage.refFrom(source))->toEqual(Some("productImages/primary.png"))
  })

  // A row written before the field existed, and one whose set is empty, are the
  // same answer: nothing to draw.
  testSync("reads an absent or empty set as no picture", () => {
    let source = {RowImage.field: "productImages", shape: Member("ref"), fromArray: true}
    expect((
      row([])->RowImage.refFrom(source),
      row([("productImages", JSON.Encode.array([]))])->RowImage.refFrom(source),
    ))->toEqual((None, None))
  })

  // A projection that wrote a placeholder said nothing about a picture, and a
  // consumer resolving "" against a store gets a broken tile.
  testSync("reads an empty ref as no picture", () =>
    expect(
      row([("categoryImage", JSON.Encode.string(""))])->RowImage.refFrom({
        field: "categoryImage",
        shape: Scalar,
        fromArray: false,
      }),
    )->toEqual(None)
  )

  // The one backend whose resolver is generated source rather than a function
  // has to read exactly what the others read.
  testSync("hands the same read to a generated resolver", () =>
    expect((
      RowImage.jsExpr(~row="row", {field: "productImages", shape: Member("ref"), fromArray: true}),
      RowImage.jsExpr(~row="row", {field: "categoryImage", shape: Scalar, fromArray: false}),
    ))->toEqual((
      "(row['productImages'] ?? [])[0]?.['ref'] ?? null",
      "row['categoryImage'] ?? null",
    ))
  )
})
