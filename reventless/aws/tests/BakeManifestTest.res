open JestGlobals

// What the command decides without AWS: which stacks it reads, what it asks the
// bake function, how it reads the answer, and when it stops asking.

module Bake = BakeManifest

let json = text => JSON.parseOrThrow(text)

describe("DeployManifest", () => {
  let text = `
region: eu-west-1
platform:
  path: platform-aws
  name: shop-platform
plugins:
  - name: catalog
    path: catalog-aws
    depends-on: []
  - name: ordering
    path: ordering-aws
`

  testSync("resolves every folder against the manifest's own folder", () => {
    let resolved =
      DeployManifest.parseString(text)->Result.map(
        m => m->DeployManifest.resolve(~file="/repo/shop/deploy-manifest.yaml"),
      )
    expect(resolved)->toEqual(
      Ok({
        DeployManifest.file: "/repo/shop/deploy-manifest.yaml",
        region: Some("eu-west-1"),
        platformDir: "/repo/shop/platform-aws",
        plugins: [
          {name: "catalog", dir: "/repo/shop/catalog-aws"},
          {name: "ordering", dir: "/repo/shop/ordering-aws"},
        ],
      }),
    )
  })

  testSync("refuses a manifest without a platform", () =>
    expect(DeployManifest.parseString("plugins: []")->Result.isError)->toBe(true)
  )
})

describe("BakeManifest.parseArgs", () => {
  testSync("reads the stack, the manifest and the deploy's start", () =>
    expect(
      Bake.parseArgs([
        "--stack",
        "alpha",
        "--manifest",
        "m.yaml",
        "--since",
        "2026-09-16T10:00:00Z",
      ]),
    )->toEqual(
      Ok({
        Bake.manifest: Some("m.yaml"),
        stack: Some("alpha"),
        since: Some("2026-09-16T10:00:00Z"),
        help: false,
      }),
    )
  )

  // CI passes the start through an output that is empty on a hand-run workflow.
  testSync("an empty --since is no instant", () =>
    expect(Bake.parseArgs(["--since", ""])->Result.map(a => a.since))->toEqual(Ok(None))
  )

  testSync("an unknown flag refuses", () =>
    expect(Bake.parseArgs(["--stak", "alpha"]))->toEqual(Error(`unknown argument "--stak"`))
  )
})

describe("BakeManifest reads the stacks", () => {
  testSync("a platform without a bake function declares no bake", () =>
    expect(
      Bake.targetOf(
        json(`{"bakedManifestBucket": "b", "bakedManifestFunction": ""}`)
        ->JSON.Decode.object
        ->Option.getOr(Dict.make()),
      ),
    )->toEqual(None)
  )

  testSync("a platform with one names the function, bucket and key", () =>
    expect(
      Bake.targetOf(
        json(`{"bakedManifestFunction": "fn", "bakedManifestBucket": "b", "bakedManifestKey": "manifest.json"}`)
        ->JSON.Decode.object
        ->Option.getOr(Dict.make()),
      ),
    )->toEqual(Some({Bake.functionName: "fn", bucket: "b", key: "manifest.json"}))
  )

  testSync("a plugin stack's structure key is read from pluginStructureRef", () =>
    expect(
      Bake.structureRefOf(
        json(`{"pluginStructureRef": {"plugin": "Catalog", "key": "sha256/abc"}}`)
        ->JSON.Decode.object
        ->Option.getOr(Dict.make()),
      ),
    )->toEqual(Some(("Catalog", "sha256/abc")))
  )

  testSync("the payload carries the deploy's start only when there is one", () => {
    let target = {Bake.functionName: "fn", bucket: "b", key: "k"}
    let expect_ = Dict.fromArray([("Catalog", "sha256/abc")])
    expect(
      Bake.payload(~target, ~expect=expect_, ~since=None)->JSON.stringify,
    )->toBe(`{"bake":true,"bucket":"b","key":"k","expect":{"Catalog":"sha256/abc"}}`)
    expect(
      Bake.payload(~target, ~expect=expect_, ~since=Some("2026-09-16T10:00:00Z"))->JSON.stringify,
    )->toBe(`{"bake":true,"bucket":"b","key":"k","expect":{"Catalog":"sha256/abc"},"since":"2026-09-16T10:00:00Z"}`)
  })
})

let pending = state =>
  json(
    `[{"baked": false, "pending": ["Catalog"], "registrations": [
    {"plugin": "Catalog", "state": "${state}", "expected": "sha256/new", "found": "sha256/old", "writtenAt": null}
  ]}]`,
  )

let baked = json(`[
  {"baked": true, "bucket": "b", "key": "manifest.json", "plugins": 2, "bytes": 512},
  {"summary": true, "plugins": 1, "registered": 1, "unchanged": 0, "matched": 0, "registrations": [
    {"plugin": "Catalog", "state": "registered", "expected": "sha256/new", "found": "sha256/new", "writtenAt": "2026-09-16T10:01:00Z"}
  ]}
]`)

describe("BakeManifest.readAnswer", () => {
  testSync("a written manifest reports its files and what convergence proved", () =>
    switch Bake.readAnswer(baked) {
    | Ok(Baked({written, summary})) =>
      expect((
        written->Array.map(w => (w.key, w.bytes)),
        summary->Option.map(s => s.registered),
      ))->toEqual(([("manifest.json", 512)], Some(1)))
    | _ => expect("not baked")->toBe("baked")
    }
  )

  testSync("a pending answer names the plugins not yet arrived", () =>
    switch Bake.readAnswer(pending("behind")) {
    | Ok(Pending({pending})) => expect(pending)->toEqual(["Catalog"])
    | _ => expect("not pending")->toBe("pending")
    }
  )

  testSync("the report line carries both keys and the row's date", () =>
    expect(
      Bake.registrationLine({
        plugin: "Catalog",
        state: "missing",
        expected: "sha256/new",
        found: None,
        writtenAt: None,
      }),
    )->toBe("  Catalog: missing — expected sha256/new, row holds no row (written never)")
  )
})

describe("BakeManifest.converge", () => {
  let run = async (answers: array<JSON.t>, ~attempts) => {
    let asked = ref(0)
    let invoke = async () => {
      let answer = answers->Array.getUnsafe(Math.Int.min(asked.contents, answers->Array.length - 1))
      asked := asked.contents + 1
      Ok(answer)
    }
    let outcome = await Bake.converge(~invoke, ~sleep=async () => (), ~log=_ => (), ~attempts)
    (outcome->Result.isOk, asked.contents)
  }

  test("asks again while a plugin is behind, then succeeds", async () =>
    expect(await run([pending("behind"), pending("behind"), baked], ~attempts=5))->toEqual((
      true,
      3,
    ))
  )

  // A first deploy has no row for any plugin until its registration lands.
  test("waits for a missing registration", async () =>
    expect(await run([pending("missing"), baked], ~attempts=5))->toEqual((true, 2))
  )

  test("stops at once on a registration that diverged", async () =>
    expect(await run([pending("diverged"), baked], ~attempts=5))->toEqual((false, 1))
  )

  test("gives up when the attempts run out", async () =>
    expect(await run([pending("behind")], ~attempts=3))->toEqual((false, 3))
  )
})
