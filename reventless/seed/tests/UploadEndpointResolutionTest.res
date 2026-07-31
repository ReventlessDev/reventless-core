// Which endpoint an asset uploads through once a deployment publishes one per
// declared store, and what a data set is told when none resolves.
//
// The four rows are the same ones the AutoUI renderer resolves an upload field
// by. They are pinned here because the two middle ones are what keep a
// deployment predating per-store endpoints — and the local dev server, which
// serves a single upload route — working unchanged, and because the row that
// falls back to the legacy service must never fall back to *another store*: that
// uploads into a different plugin's bucket with a 2xx and a plausible ref.

open JestGlobals


// `unresolvedReason` reads the knob, so the ambient environment has to be quiet.
let clearSkip = () => NodeProcess.env->Dict.set("SEED_SKIP_UPLOADS", "")

let perStore = Dict.fromArray([
  ("Catalog.productImages", "https://catalog.example/"),
  ("Ordering.invoices", "https://ordering.example/"),
])

describe("Seed.Upload.endpointFor", () => {
  testSync("a declared store with a matching endpoint uses that store's endpoint", () =>
    expect(
      Seed.Upload.endpointFor(
        ~store="Catalog.productImages",
        ~uploadEndpoint="https://legacy.example/",
        ~uploadEndpoints=perStore,
      ),
    )->toEqual(Some("https://catalog.example/"))
  )

  // Not "https://ordering.example/" — a wrong guess here is a silent
  // wrong-bucket write.
  testSync("a declared store with no matching endpoint falls back to the legacy service", () =>
    expect(
      Seed.Upload.endpointFor(
        ~store="Catalog.brochures",
        ~uploadEndpoint="https://legacy.example/",
        ~uploadEndpoints=perStore,
      ),
    )->toEqual(Some("https://legacy.example/"))
  )

  testSync("naming no store uses the legacy service", () =>
    expect(
      Seed.Upload.endpointFor(~uploadEndpoint="https://legacy.example/", ~uploadEndpoints=perStore),
    )->toEqual(Some("https://legacy.example/"))
  )

  testSync("neither available resolves nothing", () =>
    expect(
      Seed.Upload.endpointFor(
        ~store="Catalog.brochures",
        ~uploadEndpoint="",
        ~uploadEndpoints=Dict.make(),
      ),
    )->toEqual(None)
  )

  // The local dev server's shape: one upload route, no per-store map, and a data
  // set that names its store all the same.
  testSync("a single-route deployment serves a store-naming data set", () =>
    expect(
      Seed.Upload.endpointFor(
        ~store="Catalog.productImages",
        ~uploadEndpoint="http://localhost:4000/__inmemory/upload",
        ~uploadEndpoints=Dict.make(),
      ),
    )->toEqual(Some("http://localhost:4000/__inmemory/upload"))
  )
})

// "no upload endpoint" states a fact about the deployment. When the deployment
// publishes endpoints the caller could not match, the fact is about the client,
// and that phrasing sends a reader to the bucket, the presign service and the
// IAM policy — all of which are correct.
describe("Seed.Upload.unresolvedReason", () => {
  beforeEach(clearSkip)

  testSync("no endpoints at all reads as a fact about the deployment", () =>
    expect(
      Seed.Upload.unresolvedReason(~store="Catalog.productImages", ~uploadEndpoints=Dict.make()),
    )->toBe("this deployment publishes no upload endpoint")
  )

  testSync("an unmatched store names the store and the keys that were available", () => {
    let msg = Seed.Upload.unresolvedReason(~store="Catalog.brochures", ~uploadEndpoints=perStore)
    expect(msg)->toContain("Catalog.brochures")
    expect(msg)->toContain("Catalog.productImages")
    expect(msg)->toContain("Ordering.invoices")
  })

  testSync("the knob outranks both, so a skipped run is never read as a broken one", () => {
    NodeProcess.env->Dict.set("SEED_SKIP_UPLOADS", "1")
    expect(
      Seed.Upload.unresolvedReason(~store="Catalog.productImages", ~uploadEndpoints=perStore),
    )->toBe("SEED_SKIP_UPLOADS is set")
  })
})
