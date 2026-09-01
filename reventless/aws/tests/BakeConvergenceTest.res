// A plugin's structure CHANGES between two deploys and the bake is required to
// converge.
//
// The rest of the bake's coverage cannot catch this class. An unchanged structure
// converges trivially — the key already matches — so a test that never mutates the
// structure passes against a completely broken re-detect → answer → project chain.
// That is also how the chain can be broken across any number of green deploys and
// surface on the first one that changes a structure.
//
// So this drives the chain a redeploy actually runs: the deploy hashes the
// structure through the offload hook and exports the key, the SAME definition is
// serialized into `pluginDefinition.json` and decoded back the way the
// EventCollector decodes it at cold start, the Plugin aggregate decides on Redetect
// and Connect, and the projection builds the row the bake scans.

open JestGlobals

// Mirrors the deploy-time hook in aws/src/Platform.res: content-addressed key, and
// the key the stack exports as `pluginStructureRef` is the one the hook returned.
let deployStructure = (
  structure: Reventless.Plugin.pluginStructure,
): (string, Reventless.Offload.payload<Reventless.Plugin.pluginStructure>) => {
  let exported = ref("")
  ReventlessCore.Plugin_Helpers.registerOffload((~store, ~bytes) => {
    let hash = NodeCrypto.sha256Hex(bytes)
    let key = "sha256/" ++ hash
    if store == "pluginStructures" {
      exported := key
    }
    {Reventless.Offload.store, key, hash, bytes: bytes->String.length}
  })
  let payload = ReventlessCore.Plugin_Helpers.offloadPayload(
    structure,
    ~schema=Reventless.Plugin.pluginStructureSchema,
    ~store="pluginStructures",
  )
  ReventlessCore.Plugin_Helpers.clearOffload()
  (exported.contents, payload)
}

let emptyStructure: Reventless.Plugin.pluginStructure = {
  readModels: [],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  extensionPoints: None,
  requiredStores: None,
  requiredStoreDeclarations: None,
  requiredCapabilities: None,
}

let definition = (~structure): Reventless.Plugin.pluginDefinition => {
  id: "Ordering@1.0.0",
  name: "Ordering",
  version: "1.0.0",
  extensionPoints: [],
  extensions: [],
  eventCollector: "arn:aws:sqs:eu-west-1:0:Ordering",
  extensionProtocols: [],
  apiSchemaFragment: None,
  apiTarget: None,
  structure: Some(structure),
  dcbEventLog: None,
  kind: Domain,
}

// What the deploy ships as `pluginDefinition.json` and the EventCollector decodes
// at cold start. Round-tripped rather than handed over directly, because it is the
// artifact the registration carries — a key that did not survive this encode is a
// pair of hashes that can never converge.
let shipped = (def: Reventless.Plugin.pluginDefinition): Reventless.Plugin.pluginDefinition =>
  def
  ->Reventless.Util_Sury.toJsonString(Reventless.Plugin.pluginDefinitionSchema)
  ->Reventless.Util_Sury.fromJsonString(Reventless.Plugin.pluginDefinitionSchema)

// The row the projection writes, as the bake's scan sees it: QueryDb marshals the
// raw ReScript value, so the record's runtime shape IS the stored item.
let row = (def: Reventless.Plugin.pluginDefinition, ~at: string): dict<JSON.t> =>
  ReventlessCore.PluginsProjection.displayState(
    def,
    ReventlessCore.PluginsReadModelSpec.Connected,
    {Reventless.Message.at, by: "deploy"},
    [],
  )
  ->JSON.stringifyAny
  ->Option.getOr("{}")
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.getOr(Dict.make())

let apply = (state, events) => events->Array.reduce(state, ReventlessCore.PluginBehavior.evolve)

let connect = (state, def) =>
  switch ReventlessCore.PluginBehavior.decide(state, ReventlessCore.PluginSpec.Connect(def)) {
  | Ok(events) => events
  | Error(_) => []
  }

let stateOf = (rows, ~expect, ~since) =>
  Platform_ComponentDefinitions_Lambda_Ops.registrations(
    rows,
    ~expect=Dict.fromArray(expect),
    ~since=Some(since),
  )
  ->Array.get(0)
  ->Option.map(r => Platform_ComponentDefinitions_Lambda_Ops.stateName(r.state))

let deployedAt = "2026-08-27T10:00:00Z"
let beforeDeploy = "2026-08-27T09:00:00Z"
let afterDeploy = "2026-08-27T10:05:00Z"

describe("the bake converges when a plugin's structure changes", () => {
  let (keyA, structureA) = deployStructure(emptyStructure)
  let (keyB, structureB) = deployStructure({
    ...emptyStructure,
    requiredStores: Some(["Ordering.receipts"]),
  })
  let defA = definition(~structure=structureA)
  let defB = definition(~structure=structureB)

  // If this ever stops holding, the two keys can never converge and every retry is
  // spent waiting for something that cannot happen.
  testSync("a changed structure hashes to a different key", () =>
    expect(keyA == keyB)->toBe(false)
  )

  // The invariant convergence rests on: the structure the deploy hashes and the
  // structure the plugin's registration carries are the same bytes, because they
  // are the same object — the runtime does not recompute it, it ships the
  // deploy's reference and hands it back.
  testSync("the key the deploy exported is the key the registration carries", () =>
    expect(
      Platform_ComponentDefinitions_Lambda_Ops.structureRefKey(
        row(shipped(defB), ~at=afterDeploy),
      ),
    )->toEqual(Some(keyB))
  )

  testSync("before the redeploy's registration lands, the plugin reads as behind", () =>
    expect(
      stateOf(
        [row(shipped(defA), ~at=beforeDeploy)],
        ~expect=[("Ordering", keyB)],
        ~since=deployedAt,
      ),
    )->toEqual(Some("behind"))
  )

  // The link the bake is actually waiting on: a Connect carrying a changed
  // definition must re-emit VersionConnected. `decide` is idempotent on an
  // unchanged one, so this is the step a broken chain silently skips.
  testSync("a redeploy with a changed structure re-emits VersionConnected", () => {
    let connected = ReventlessCore.PluginBehavior.initialState->apply(connect(
      ReventlessCore.PluginBehavior.initialState,
      shipped(defA),
    ))
    expect(connect(connected, shipped(defB))->Array.length)->toBe(1)
  })

  testSync("once it lands, the plugin reads as registered by this deploy", () => {
    let connected = ReventlessCore.PluginBehavior.initialState->apply(connect(
      ReventlessCore.PluginBehavior.initialState,
      shipped(defA),
    ))
    let redeployed = connected->apply(connect(connected, shipped(defB)))
    let def = switch redeployed.known->Dict.get("1.0.0") {
    | Some({definition}) => definition
    | None => shipped(defA)
    }
    expect(
      stateOf([row(def, ~at=afterDeploy)], ~expect=[("Ordering", keyB)], ~since=deployedAt),
    )->toEqual(Some("registered"))
  })

  // Defect 1, as a test: a plugin whose structure did not change never
  // re-registers, so its row is never rewritten and it passes the check without
  // exercising the chain at all. Correct, and no evidence — which is why the bake
  // counts it apart from a plugin that did register.
  testSync("an unchanged structure passes without re-registering", () => {
    let connected = ReventlessCore.PluginBehavior.initialState->apply(connect(
      ReventlessCore.PluginBehavior.initialState,
      shipped(defA),
    ))
    expect(connect(connected, shipped(defA)))->toEqual([])
    expect(
      stateOf(
        [row(shipped(defA), ~at=beforeDeploy)],
        ~expect=[("Ordering", keyA)],
        ~since=deployedAt,
      ),
    )->toEqual(Some("unchanged"))
  })

  // Deploy-time re-detect is what starts the chain for an already-connected
  // version; without it a redeploy of the same version never re-runs the handshake
  // and the changed structure never reaches the read model.
  testSync("a redeploy re-detects an already-connected version", () => {
    let connected = ReventlessCore.PluginBehavior.initialState->apply(connect(
      ReventlessCore.PluginBehavior.initialState,
      shipped(defA),
    ))
    expect(
      ReventlessCore.PluginBehavior.decide(connected, ReventlessCore.PluginSpec.Redetect("1.0.0")),
    )->toEqual(Ok([ReventlessCore.PluginSpec.VersionDetected("1.0.0")]))
  })
})
