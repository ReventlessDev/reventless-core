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
          ...Platform_Admin_Structure.activateCommand,
          targetState: Some("Conected"),
        },
      ],
    }
    expect(raises([bogus]))->toEqual(true)
  })
})
