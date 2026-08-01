// Which document `resolveEndpoints` reads, and which GraphQL endpoint each arm takes
// from it.
//
// `endpointsFrom` is the pure half of `resolveEndpoints`; the impure half is a
// `pulumi stack output` subprocess and a `config.json` fetch, and the decision these
// tests pin is in neither. Upload endpoints are no longer resolved here — under route B
// the seed mints through the domain API's `Upload_Presign` mutation on the GraphQL
// endpoint below — so the only decision left is which GraphQL endpoint each source
// publishes, and the merged-over-per-plugin precedence within the stack-outputs arm.

open JestGlobals
open ReventlessSeed

// Every value read here has an env override, and an ambient one in the runner's
// environment (AWS_REGION is routinely set) would silently stand in for the document
// under test. An empty string reads as unset.
let clearOverrides = () =>
  [
    "REVENTLESS_GRAPHQL_ENDPOINT",
    "AWS_REGION",
    "COGNITO_CLIENT_ID",
    "SEED_SKIP_UPLOADS",
  ]->Array.forEach(k => NodeProcess.env->Dict.set(k, ""))

let obj = entries => JSON.Encode.object(entries->Dict.fromArray)
let str = JSON.Encode.string

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

describe("endpointsFrom — host shell arm", () => {
  beforeEach(clearOverrides)

  testSync("reads the GraphQL endpoint from the shell config", () => {
    let eps = ReventlessSeedAws.endpointsFrom(~stack="alpha", HostShellConfig(config(~extra=[])))
    expect(eps.graphql)->toBe("https://api.example/graphql")
  })
})

describe("endpointsFrom — stack outputs arm", () => {
  beforeEach(clearOverrides)

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
