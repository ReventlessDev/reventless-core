// Guards the write/read symmetry of the `pluginDefinition.json` asset.
//
// The deploy side writes it with the schema's encoder (Plugin_Helpers); the
// runtime side (EventCollectorEntryPoint_Ops.loadPluginDefinition) reads it back
// and republishes the value inside the Connect handshake. Those two have to be
// the same schema in opposite directions.
//
// They stopped being that once a field carried @offload, whose wire form is
// deliberately untagged: {"$offload": …} on the wire, Offloaded(…) in ReScript.
// The read side cast the parsed JSON instead of decoding it, so the wire form
// survived inside a value typed as the record and the *next* encode — publishing
// ConnectPlugin — threw. Registration then froze at the previous version with the
// deploy reporting success, so this asserts the round trip rather than the read.

open JestGlobals

let offloadedFragment: Reventless.Plugin.pluginDefinition = {
  id: "Catalog@1.0.0-alpha.215",
  name: "Catalog",
  version: "1.0.0-alpha.215",
  extensionPoints: [],
  extensions: [],
  eventCollector: "arn:aws:sqs:eu-west-1:1:CatalogPluginEventColl",
  extensionProtocols: [],
  apiSchemaFragment: Some(
    Offloaded({
      store: "pluginApiFragments",
      key: "sha256/a3db053a9ca51d63982811b0c1faa42cbb83ef6011ea140841375c7b1c9e9695",
      hash: "a3db053a9ca51d63982811b0c1faa42cbb83ef6011ea140841375c7b1c9e9695",
      bytes: 14594,
    }),
  ),
  apiTarget: Some("Domain"),
  structure: None,
  dcbEventLog: None,
  kind: Domain,
}

let inlineFragment: Reventless.Plugin.pluginDefinition = {
  ...offloadedFragment,
  apiSchemaFragment: Some(Inline({encoded: "{\"types\":[]}", protocol: "1"})),
}

// The asset as it lands in the code archive — the deploy side, verbatim.
let writeAsset = (def: Reventless.Plugin.pluginDefinition): string =>
  def->Reventless.Util_Sury.toJsonString(Reventless.Plugin.pluginDefinitionSchema)

// The runtime side, through the real entry point: loadPluginDefinition resolves
// the asset against process.cwd(), so the file has to be laid down where it looks
// rather than the decode re-implemented here — re-implementing it is what would
// let a cast come back green.
let readAsset = (json: string): Reventless.Plugin.pluginDefinition => {
  let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "plugindef-"]))
  let previousCwd = NodeProcess.cwd()
  NodeFs.writeFileSync(NodePath.join([dir, "pluginDefinition.json"]), json)
  NodeProcess.chdir(dir)
  let restore = () => {
    NodeProcess.chdir(previousCwd)
    NodeFs.rmSync(dir, {recursive: true, force: true})
  }
  switch EventCollectorEntryPoint_Ops.loadPluginDefinition() {
  | def =>
    restore()
    def
  | exception exn =>
    restore()
    throw(exn)
  }
}

describe("pluginDefinition.json write/read symmetry", () => {
  testSync("an offloaded field reaches the runtime as Offloaded, not as its wire form", () => {
    let def = offloadedFragment->writeAsset->readAsset
    switch def.apiSchemaFragment {
    | Some(Offloaded({store, bytes})) =>
      expect(store)->toBe("pluginApiFragments")
      expect(bytes)->toBe(14594)
    | Some(Inline(_)) => fail("offloaded fragment decoded as Inline")
    | None => fail("offloaded fragment decoded as None")
    }
  })

  testSync("a definition read back from the asset can be published to the Connect handshake", () => {
    // The encode the old cast broke. Both arms, because only Offloaded diverges
    // between wire and runtime shape and an Inline-only test would stay green.
    [offloadedFragment, inlineFragment]->Array.forEach(def => {
      let published =
        ReventlessInfra.PluginExtensionPointSpec.ConnectPlugin(def->writeAsset->readAsset)
        ->Reventless.Util_Sury.toJson(ReventlessInfra.PluginExtensionPointSpec.commandSchema)
      expect(published->JSON.Decode.object->Option.isSome)->toBe(true)
    })
  })

  testSync("the asset round-trips byte-identically, so no stored message shifts", () => {
    let once = offloadedFragment->writeAsset
    expect(once->readAsset->writeAsset)->toBe(once)
  })

  testSync("an absent optional reaches the runtime as None, not as null", () => {
    let def = offloadedFragment->writeAsset->readAsset
    expect(def.structure->Option.isNone)->toBe(true)
    expect(def.dcbEventLog->Option.isNone)->toBe(true)
  })
})
