// Which document `resolveEndpoints` reads, and what each arm takes from it.
//
// `endpointsFrom` is the pure half of `resolveEndpoints`; the impure half is a
// `pulumi stack output` subprocess and a `config.json` fetch, and the decision
// these tests pin is in neither. The defect they lock out: **neither arm read
// `uploadEndpoints`**, so a platform that publishes a presign endpoint per
// declared store resolved "" and the seeder reported it as serving no uploads.
// The stack-outputs arm is the one that matters — a platform deploying no host
// shell publishes no `hostShellUrl` by construction, so it takes that arm, and
// the per-store endpoint is its only way to reach the store.

open JestGlobals
open ReventlessSeed

@val @scope("process") external processEnv: dict<string> = "env"

// Every value read here has an env override, and an ambient one in the runner's
// environment (AWS_REGION is routinely set) would silently stand in for the
// document under test. An empty string reads as unset.
let clearOverrides = () =>
  [
    "REVENTLESS_GRAPHQL_ENDPOINT",
    "REVENTLESS_UPLOAD_ENDPOINT",
    "AWS_REGION",
    "COGNITO_CLIENT_ID",
    "SEED_SKIP_UPLOADS",
  ]->Array.forEach(k => processEnv->Dict.set(k, ""))

let obj = entries => JSON.Encode.object(entries->Dict.fromArray)
let str = JSON.Encode.string

// A host shell's config.json and the stack outputs of a platform that serves no
// shell — the two documents the two arms read, minus the upload keys each test
// supplies.
let config = (~extra: array<(string, JSON.t)>) =>
  obj(
    Array.concat(
      [
        ("apiEndpoint", str("https://api.example/graphql")),
        ("region", str("eu-west-1")),
        ("cognitoClientId", str("client-abc")),
      ],
      extra,
    ),
  )

let outputs = (~extra: array<(string, JSON.t)>) =>
  obj(
    Array.concat(
      [
        ("domainApiEndpoint", str("https://domain.example/graphql")),
        ("cognitoRegion", str("eu-west-1")),
        ("cognitoUserPoolClientId", str("client-abc")),
      ],
      extra,
    ),
  )

let storeEndpoints = obj([("Catalog.productImages", str("https://presign.example/"))])

describe("endpointsFrom — host shell arm", () => {
  beforeEach(clearOverrides)

  testSync("reads the legacy single service and the per-store map together", () => {
    let eps = ReventlessSeedAws.endpointsFrom(
      ~stack="alpha",
      HostShellConfig(
        config(
          ~extra=[
            ("uploadEndpoint", str("https://legacy.example/")),
            ("uploadEndpoints", storeEndpoints),
          ],
        ),
      ),
    )
    expect(eps.uploadEndpoint)->toBe("https://legacy.example/")
    expect(eps.uploadEndpoints)->toEqual(
      Dict.fromArray([("Catalog.productImages", "https://presign.example/")]),
    )
  })

  // A shell fronting only declared stores writes no singular key. That used to
  // fail the whole run before a command was sent ("deployment is missing
  // uploadEndpoint"), which is a harder failure than the one this plan fixes.
  testSync("a shell publishing only per-store endpoints resolves an empty legacy service", () => {
    let eps = ReventlessSeedAws.endpointsFrom(
      ~stack="alpha",
      HostShellConfig(config(~extra=[("uploadEndpoints", storeEndpoints)])),
    )
    expect(eps.uploadEndpoint)->toBe("")
    expect(eps.uploadEndpoints->Dict.keysToArray)->toEqual(["Catalog.productImages"])
  })

  testSync("REVENTLESS_UPLOAD_ENDPOINT overrides the legacy service and leaves the map alone", () => {
    processEnv->Dict.set("REVENTLESS_UPLOAD_ENDPOINT", "https://override.example/")
    let eps = ReventlessSeedAws.endpointsFrom(
      ~stack="alpha",
      HostShellConfig(
        config(
          ~extra=[
            ("uploadEndpoint", str("https://legacy.example/")),
            ("uploadEndpoints", storeEndpoints),
          ],
        ),
      ),
    )
    expect(eps.uploadEndpoint)->toBe("https://override.example/")
    expect(eps.uploadEndpoints->Dict.get("Catalog.productImages"))->toEqual(
      Some("https://presign.example/"),
    )
  })
})

describe("endpointsFrom — stack outputs arm", () => {
  beforeEach(clearOverrides)

  // The lookup that was missing entirely: this arm had no upload source but the
  // env var, so a `PlatformOwned` deployment resolved "" whatever it published.
  testSync("reads the uploadEndpoints stack output", () => {
    let eps = ReventlessSeedAws.endpointsFrom(
      ~stack="pr-verify",
      StackOutputs(outputs(~extra=[("uploadEndpoints", storeEndpoints)])),
    )
    expect(eps.uploadEndpoints)->toEqual(
      Dict.fromArray([("Catalog.productImages", "https://presign.example/")]),
    )
  })

  // Declaring no store is a legitimate deployment, not a broken one — it stays a
  // no-op at the data set rather than failing the run.
  testSync("a deployment declaring no store resolves an empty map without failing", () => {
    let eps = ReventlessSeedAws.endpointsFrom(~stack="pr-verify", StackOutputs(outputs(~extra=[])))
    expect(eps.uploadEndpoint)->toBe("")
    expect(eps.uploadEndpoints->Dict.keysToArray)->toEqual([])
  })

  testSync("prefers the merged API endpoint over the per-plugin one", () => {
    let eps = ReventlessSeedAws.endpointsFrom(
      ~stack="pr-verify",
      StackOutputs(outputs(~extra=[("domainMergedApiEndpoint", str("https://merged.example/"))])),
    )
    expect(eps.graphql)->toBe("https://merged.example/")
  })

  testSync("fails naming both keys when the stack exports neither API endpoint", () =>
    switch ReventlessSeedAws.endpointsFrom(
      ~stack="pr-verify",
      StackOutputs(obj([("cognitoRegion", str("eu-west-1"))])),
    ) {
    | _ => fail("expected endpointsFrom to fail")
    | exception Seed.Failed(msg) =>
      expect(msg)->toContain("domainMergedApiEndpoint")
      expect(msg)->toContain("domainApiEndpoint")
    }
  )
})

describe("endpointsFrom — malformed uploadEndpoints", () => {
  beforeEach(clearOverrides)

  // One bad member should not cost the run every endpoint it could have used.
  testSync("drops a non-string member rather than the whole map", () => {
    let eps = ReventlessSeedAws.endpointsFrom(
      ~stack="pr-verify",
      StackOutputs(
        outputs(
          ~extra=[
            (
              "uploadEndpoints",
              obj([
                ("Catalog.productImages", str("https://presign.example/")),
                ("Catalog.broken", JSON.Encode.int(7)),
              ]),
            ),
          ],
        ),
      ),
    )
    expect(eps.uploadEndpoints->Dict.keysToArray)->toEqual(["Catalog.productImages"])
  })
})
