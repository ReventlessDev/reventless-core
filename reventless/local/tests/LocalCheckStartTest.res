open JestGlobals

// `check-start [<mainModule>]` runs an app's start in check mode: everything is built the way a
// start builds it, and nothing is served.

/** Runs `f` with `key` set to `value` (or unset), and puts the environment back. */
let withEnv = (key: string, value: option<string>, f: unit => 'a): 'a => {
  let previous = NodeProcess.env->Dict.get(key)
  switch value {
  | Some(v) => NodeProcess.env->Dict.set(key, v)
  | None => NodeProcess.env->Dict.delete(key)
  }
  let restore = () =>
    switch previous {
    | Some(v) => NodeProcess.env->Dict.set(key, v)
    | None => NodeProcess.env->Dict.delete(key)
    }
  switch f() {
  | result =>
    restore()
    result
  | exception e =>
    restore()
    throw(e)
  }
}

describe("LocalCheckStart.active", () => {
  testSync("is off unless the variable says otherwise", () => {
    expect(LocalCheckStart.active(~env=Dict.make(), ()))->toBe(false)
    expect(LocalCheckStart.active(~env=Dict.fromArray([(LocalCheckStart.envVar, " ")]), ()))->toBe(
      false,
    )
    expect(LocalCheckStart.active(~env=Dict.fromArray([(LocalCheckStart.envVar, "1")]), ()))->toBe(
      true,
    )
  })
})

describe("LocalCheckStart.enterCheckMode", () => {
  testSync("checks in memory and quietly, keeping a log level the caller chose", () => {
    let env = Dict.fromArray([
      ("REVENTLESS_LOCAL_BACKEND", "sqlite:./local.db"),
      ("LOG_LEVEL", "debug"),
    ])
    LocalCheckStart.enterCheckMode(~env, ())
    expect(env->Dict.get(LocalCheckStart.envVar))->toEqual(Some("1"))
    expect(env->Dict.get("REVENTLESS_LOCAL_BACKEND"))->toEqual(Some("memory"))
    expect(env->Dict.get("LOG_LEVEL"))->toEqual(Some("debug"))

    let quiet = Dict.make()
    LocalCheckStart.enterCheckMode(~env=quiet, ())
    expect(quiet->Dict.get("LOG_LEVEL"))->toEqual(Some("warn"))
  })
})

describe("LocalCheckStart.mainModulePath", () => {
  testSync("is the conventional start module unless one is named", () => {
    expect(LocalCheckStart.mainModulePath(~mainModule=None))->toBe(
      NodePath.resolve(["src", "Main.res.mjs"]),
    )
    expect(LocalCheckStart.mainModulePath(~mainModule=Some("lib/Start.res.mjs")))->toBe(
      NodePath.resolve(["lib/Start.res.mjs"]),
    )
  })
})

describe("LocalPlatformStart.orAddressRunning in check mode", () => {
  // Addressing a running platform exits 0, which would report a start nobody checked.
  testSync("goes on although a platform is running in the directory", () => {
    let cwd = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "reventless-check-"]))
    let _ = LocalPlatformRegistry.write(
      ~port=4000,
      ~endpoint="http://localhost:4000/graphql",
      ~loginEndpoint="http://localhost:4000/__inmemory/login",
      ~store={kind: MemoryStore},
      ~pid=NodeProcess.pid,
      ~cwd,
    )
    let returned = withEnv(
      LocalPlatformStart.bypassEnv,
      None,
      () =>
        withEnv(
          LocalCheckStart.envVar,
          Some("1"),
          () => {
            LocalPlatformStart.orAddressRunning(~cwd, ())
            true
          },
        ),
    )
    expect(returned)->toBe(true)
  })
})

describe("check-start on the command line", () => {
  module CliArgs = Reventless.CliArgs
  let usage = LocalCheckStart.usage->String.trim

  testSync("names the start module, or takes the conventional one", () => {
    expect(LocalCheckStart.parseArgs([]))->toEqual(Ok(({}: LocalCheckStart.args)))
    expect(LocalCheckStart.parseArgs(["lib/Start.res.mjs"]))->toEqual(
      Ok({LocalCheckStart.mainModule: "lib/Start.res.mjs"}),
    )
  })

  testSync("takes --json beside the start module", () =>
    expect(LocalCheckStart.parseArgs(["--json", "lib/Start.res.mjs"]))->toEqual(
      Ok({LocalCheckStart.mainModule: "lib/Start.res.mjs", json: true}),
    )
  )

  test("a second argument is a usage mistake, exit 2", async () =>
    expect(await CliArgs.observe(LocalCheckStart.cli, ["a", "b"]))->toEqual({
      CliArgs.stdout: [],
      stderr: [`check-start: unknown argument "b"\n\n${usage}`],
      exitCode: 2,
      reachedMain: false,
    })
  )
})

// An app whose `@partitionTag` inference contradicts: `AddProduct` names the category it reads
// the lifecycle of, where its own key is the product.
module Catalog = {
  module AddProduct = {
    @schema
    type command = AddProduct({productId: string, categoryId: string})
    @schema
    type consumedEvent = ProductAdded({productId: string}) | CategoryAdded({categoryId: string})
    @schema
    type event =
      | ProductAdded({
          productId: @s.matches(Reventless.DcbTag.string) string,
          categoryId: @s.matches(Reventless.DcbTag.partition) string,
        })
  }
  module AddCategory = {
    @schema
    type command = AddCategory({categoryId: string})
    @schema
    type consumedEvent = CategoryAdded({categoryId: string})
    @schema
    type event = CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string})
  }
  let shapes = [
    Reventless.DcbTag.sliceShapeFromSchemas(
      ~name="AddProduct",
      ~commandSchema=AddProduct.commandSchema->S.castToUnknown,
      ~consumedEventSchema=AddProduct.consumedEventSchema->S.castToUnknown,
      ~eventSchema=AddProduct.eventSchema->S.castToUnknown,
    ),
    Reventless.DcbTag.sliceShapeFromSchemas(
      ~name="AddCategory",
      ~commandSchema=AddCategory.commandSchema->S.castToUnknown,
      ~consumedEventSchema=AddCategory.consumedEventSchema->S.castToUnknown,
      ~eventSchema=AddCategory.eventSchema->S.castToUnknown,
    ),
  ]
}

describe("check-start --json", () => {
  let printed = (json: JSON.t) => json->JSON.stringify->JSON.parseOrThrow

  testSync("says the app starts", () =>
    expect(LocalCheckStart.startsJson()->printed)->toEqual(%raw(`{starts: true}`))
  )

  testSync("reads the code, the component, the slice and both keys off a refused build", () => {
    let error = switch ReventlessCore.Dcb_Builder.checkPartitionHints(
      ~component="Catalog",
      ~shapes=Catalog.shapes,
    ) {
    | () => None
    | exception JsExn(e) => Some(e)
    }
    let json = switch error {
    | Some(e) =>
      LocalCheckStart.refusedJson(
        ~refusal=Reventless.StartRefusal.ofError(e),
        LocalCheckStart.reasonOf(e),
      )->printed
    | None => JSON.Encode.null
    }
    let field = (o, path) =>
      path->Array.reduce(
        Some(o),
        (at, key) =>
          at->Option.flatMap(
            v =>
              switch v {
              | JSON.Object(d) => d->Dict.get(key)
              | JSON.Array(xs) => key->Int.fromString->Option.flatMap(i => xs->Array.get(i))
              | _ => None
              },
          ),
      )
    let text = path => json->field(path)->Option.flatMap(JSON.Decode.string)
    expect(json->field(["starts"]))->toEqual(Some(JSON.Encode.bool(false)))
    expect((
      text(["refusal", "component"]),
      text(["refusal", "refusals", "0", "code"]),
      text(["refusal", "refusals", "0", "slice"]),
      text(["refusal", "refusals", "0", "named"]),
      text(["refusal", "refusals", "0", "derived"]),
    ))->toEqual((
      Some("Catalog"),
      Some("partition-contradiction"),
      Some("AddProduct"),
      Some("categoryId"),
      Some("productId"),
    ))
    // The message is the one the line without --json prints.
    expect(text(["refusal", "message"]))->toEqual(error->Option.map(LocalCheckStart.reasonOf))
  })

  testSync("codes a refusal the error does not carry as unknown", () =>
    expect(LocalCheckStart.refusedJson(~refusal=None, "Main.res.mjs not found")->printed)->toEqual(
      %raw(`{
        starts: false,
        refusal: {
          message: "Main.res.mjs not found",
          refusals: [{code: "unknown", message: "Main.res.mjs not found"}],
        },
      }`),
    )
  )

  testSync("reports a store in use and roles nothing honours under their codes", () => {
    let codes = (r: Reventless.StartRefusal.t) =>
      switch LocalCheckStart.refusedJson(~refusal=Some(r), r->Reventless.StartRefusal.message)
      ->printed
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("refusal"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("refusals")) {
      | Some(JSON.Array(items)) =>
        items->Array.filterMap(
          i =>
            i
            ->JSON.Decode.object
            ->Option.flatMap(o => o->Dict.get("code"))
            ->Option.flatMap(JSON.Decode.string),
        )
      | _ => []
      }
    let store: LocalPlatformRegistry.entry = {
      port: 4000,
      endpoint: "http://localhost:4000/graphql",
      loginEndpoint: "http://localhost:4000/__inmemory/login",
      store: {kind: SqliteStore, path: "/app/local.db"},
      pid: 42,
      app: "shop",
      startedAt: "",
    }
    expect(codes(LocalPlatformStart.refusal(~path="/app/local.db", store)))->toEqual([
      "store-in-use",
    ])
    expect(
      codes(
        Reventless.AdmissionCheck.refusal([
          {plugin: "Shop", role: "Shopper", why: "is self-service"},
        ]),
      ),
    )->toEqual(["roles-unhonoured"])
  })
})
