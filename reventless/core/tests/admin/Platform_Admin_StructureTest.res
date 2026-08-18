// The platform's own admin components, as `Platform_ComponentDefinitions` serves
// them. The Plugins read model is a framework-generated queryable: its field names
// are chosen here and read by every client, so the rule that applies to it is the
// opposite of the one that applies to an authored record.
//
// An authored record may follow the convention — name the field `lifecycle` and
// write no annotation. A generated row cannot, because its field name is a
// published wire name: `status` in the SDL, in stored QueryDb rows, and in any
// client selecting it. Renaming it to satisfy a convention would move the
// contract, break selecting clients and require re-projection. So it declares
// instead, and the declaration is what this asserts — the failure mode otherwise
// is silent (a board loses its columns, a command menu stops filtering, and
// nothing fails to compile).

open JestGlobals
open Reventless.Plugin

// The commands are derived from `PluginSpec.command` rather than hand-written, so
// a test names one by looking it up. Raises rather than defaulting: a missing
// variant is the failure these tests exist to catch, and a placeholder would let
// the assertions below pass against nothing.
let commandNamed = (name: string): commandDef =>
  Platform_Admin_Structure.pluginCommands
  ->Array.find(c => c.name == name)
  ->Option.getOrThrow(~message=`Platform_Admin_Structure publishes no "${name}" command`)

let activate = () => commandNamed("Activate")

describe("the Plugins read model declares its lifecycle", () => {
  let rm: queryableDef = Platform_Admin_Structure.pluginReadModel

  testSync("names the field commands branch on", () =>
    expect(rm.lifecycleField)->toEqual(Some("status"))
  )

  testSync("and the published wire name is unchanged by the rename", () => {
    // Stated as its own assertion rather than folded into the one above: the two
    // say different things. That the field is declared is the fix; that it is
    // still called `status` is the constraint the fix had to respect.
    let sdlDeclaresStatus =
      rm.lifecycleField->Option.mapOr(false, f => f == "status") &&
        rm.queryField->String.startsWith("Platform_")
    expect(sdlDeclaresStatus)->toEqual(true)
  })

  testSync("is served on the encoded def under the new key", () => {
    let json =
      rm->Platform_ComponentDefinitionsApi.encodeQueryableDef->JSON.stringify
    expect(json->String.includes(`"lifecycleField":"status"`))->toEqual(true)
  })

  testSync("and never under the old one", () =>
    expect(
      rm
      ->Platform_ComponentDefinitionsApi.encodeQueryableDef
      ->JSON.stringify
      ->String.includes(`"statusField"`),
    )->toEqual(false)
  )
})

// `Plugin_Structure.make` never sees the platform's own components, so the checks it
// runs over every ordinary plugin do not run here. A test rather than a startup call:
// both sides are compile-time constants in this package, so nothing varies at runtime.
describe("the admin structure's declared transitions are checked", () => {
  let states = Plugin_Structure.lifecycleStatesFromStateSchema(
    ~entityName=PluginsReadModelSpec.name,
    PluginsReadModelSpec.stateSchema->S.castToUnknown,
  )

  let statesByView = () => {
    let d = Dict.make()
    states->Option.forEach(s => d->Dict.set(PluginsReadModelSpec.name, s))
    d
  }

  let raises = writables =>
    switch Plugin_Structure.checkDeclaredTransitions(
      ~pluginName="Platform",
      ~writables,
      ~lifecycleStatesByView=statesByView(),
    ) {
    | () => false
    | exception _ => true
    }

  // The precondition the rest of the block is worthless without: with no states the
  // check counts the commands as unvalidated and passes.
  testSync("the linked view yields its lifecycle states", () =>
    expect(states)->toEqual(Some(["Connected", "Disconnected", "Inactive", "Retired"]))
  )

  testSync("every state the Plugin commands name is one the view declares", () =>
    expect(raises([Platform_Admin_Structure.pluginAggregate]))->toEqual(false)
  )

  // A check that cannot fail is indistinguishable from one that is not running.
  testSync("and a state the view does not declare is caught", () => {
    let bogus: Reventless.Plugin.writableDef = {
      ...Platform_Admin_Structure.pluginAggregate,
      commands: [
        {
          ...activate(),
          targetState: Some("Conected"),
        },
      ],
    }
    expect(raises([bogus]))->toEqual(true)
  })
})

// The drift that made deriving these defs worth doing rather than tidy. The
// hand-written arg schema described only `id`, while the SDL generated off the
// same `commandSchema` declares `Platform_Plugin_Activate(_0: String!, id: ID!)`.
// AutoUI builds its mutation document from the published schema, so it sent a
// document missing a required argument and every admin row action was rejected at
// GraphQL validation, before the aggregate saw it.
describe("the Plugin command defs carry every argument the SDL requires", () => {
  testSync("the version argument is published", () =>
    expect(activate().schema->String.includes(`"_0"`))->toEqual(true)
  )

  testSync("and so is the aggregate id", () => {
    // `id` is not in the command schema — it is the aggregate instance, injected
    // by the auto-resolver flow. What the def has to get right is naming it, so
    // the consumer declares the variable rather than guessing.
    expect(activate().aggregateIdField)->toEqual(None)
  })

  testSync("the exposed commands name the field PluginBaseFragment generates", () =>
    expect(
      Platform_Admin_Structure.pluginCommands
      ->Array.filter(c => c.apiExposed != Some(false))
      ->Array.map(c => c.mutationField),
    )->toEqual([
      "Platform_Plugin_Activate",
      "Platform_Plugin_Deactivate",
      "Platform_Plugin_Retire",
    ])
  )

  // The `@noApi` protocol variants come back from the same walk. They belong on
  // the event graph — `Disconnect` is the only edge into `Disconnected` — but
  // `Connect` carries a whole plugin definition, so publishing metadata about
  // them must not publish a way to call them.
  testSync("the internal commands are published as uncallable", () => {
    let internal =
      Platform_Admin_Structure.pluginCommands->Array.filter(c => c.apiExposed == Some(false))
    expect(internal->Array.map(c => c.name))->toEqual([
      "Heartbeat",
      "Redetect",
      "Connect",
      "Disconnect",
      "ReportIncompatibility",
    ])
    expect(internal->Array.every(c => c.mutationField == ""))->toEqual(true)
  })
})

// A heartbeat timing out is the only way a row reaches `Disconnected`, and the
// command that does it carries `@noApi`. Until it declared its edge the topology
// check reported the state unreachable and was right to: nothing in the
// declarations said how a row got there.
describe("the internal commands declare the edges they move rows along", () => {
  let states = Plugin_Structure.lifecycleStatesFromStateSchema(
    ~entityName=PluginsReadModelSpec.name,
    PluginsReadModelSpec.stateSchema->S.castToUnknown,
  )

  let statesByView = () => {
    let d = Dict.make()
    states->Option.forEach(s => d->Dict.set(PluginsReadModelSpec.name, s))
    d
  }

  testSync("the only edge into Disconnected is declared", () =>
    expect((commandNamed("Disconnect").allowedStates, commandNamed("Disconnect").targetState))
    ->toEqual((Some(["Connected"]), Some("Disconnected")))
  )

  // The creating form's claim: a target and no from-set. `Connect` brings the
  // version's row into being, so there is no state it runs from — and an empty
  // `allowedStates` would say the opposite, that it is legal in none.
  testSync("the handshake declares a target and no from-set", () =>
    expect((commandNamed("Connect").allowedStates, commandNamed("Connect").targetState))
    ->toEqual((None, Some("Connected")))
  )

  testSync("and no state is left unreachable", () =>
    expect(
      Plugin_Structure.lifecycleTopologyFindings(
        ~writables=[Platform_Admin_Structure.pluginAggregate],
        ~lifecycleStatesByView=statesByView(),
      ),
    )->toEqual([])
  )
})

// One rule, read on both sides of the wire. `PluginBaseFragment` hand-wrote an
// `Admin` Cognito gate while the spec defaulted to `AllowAuthenticated`, and the
// published `requiredAccess` said `None` — so a shell was told the Plugins view
// was open to everyone and the server refused anyone outside `Admin`. The
// mismatch is invisible until a non-admin clicks the page.
describe("the Plugins view publishes the rule the server enforces", () => {
  testSync("the spec declares the group", () =>
    expect(PluginsReadModelSpec.authorization)->toEqual(
      Reventless.Authorization.AllowGroups(["Admin"]),
    )
  )

  testSync("and the published access keys are derived from it", () =>
    expect(Platform_Admin_Structure.pluginReadModel.requiredAccess)->toEqual(Some(["Admin"]))
  )

  // The API entry reads the same binding rather than restating it, so the two
  // cannot be edited apart.
  testSync("the query entry carries the spec's rule and no hand-written pair", () => {
    let entry = PluginBaseFragment.queryEntries->Array.getUnsafe(0)
    expect((entry.permission, entry.authorization))->toEqual((
      Some(PluginsReadModelSpec.authorization),
      None,
    ))
  })
})

// The `queryableDef` is derived from the spec, not hand-written. The analysis
// that preceded this expected the admin's naming to be bespoke and it is not:
// `Api_Naming.queryFieldNamesForReadModel` returns byte-identical names, because
// `singularize` already handles the plural-spec-name / singular-type shape that
// looked special. Asserted rather than assumed — the whole case for deriving
// rests on the generic helpers reaching the same answers.
describe("the Plugins queryableDef is what the generic helpers produce", () => {
  let rm: queryableDef = Platform_Admin_Structure.pluginReadModel

  testSync("the field names are the generic ones", () =>
    expect((rm.queryField, rm.singleQueryField))->toEqual((
      "Platform_Plugins",
      Some("Platform_Plugin"),
    ))
  )

  testSync("the label ladder reaches the same field, by convention", () =>
    expect((rm.labelField, rm.labelFieldSource, rm.searchableFields))->toEqual((
      "name",
      Some("convention"),
      ["name"],
    ))
  )

  // The row id is `name@version` and the state carries the two halves
  // separately, never the composed key — so `None` is the honest answer, and it
  // is the one the resolver ladder reaches on its own.
  testSync("the key ladder finds no id field, as the hand-written def claimed", () =>
    expect((rm.idField, rm.idFieldSource))->toEqual((None, None))
  )

  // The last hand-written list here. `apiSchemaFragment` and `structure` are on
  // the API — the shell queries them through dedicated resolver paths — but
  // AutoUI would name them in a generated list query without a sub-selection.
  // `@hidden` on the spec replaces this once every shell skips hidden fields in
  // its selection; until the pin moves, declaring it would take the page down.
  testSync("the two narrowed fields are absent from the published schema", () => {
    // Read as property NAMES, not as substrings of the JSON: the schema carries
    // nested object types whose own fields would match a naive `includes`.
    let props =
      rm.schema
      ->JSON.parseExn
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("properties"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.mapOr([], Dict.keysToArray)
    expect((
      props->Array.includes("apiSchemaFragment"),
      props->Array.includes("structure"),
      props->Array.includes("statusChange"),
    ))->toEqual((false, false, true))
  })
})
