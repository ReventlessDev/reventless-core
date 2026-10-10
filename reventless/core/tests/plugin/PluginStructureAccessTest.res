// `requiredAccess` is derived from the authorization rule the server enforces, so
// what these assert is that the manifest cannot describe a different policy from
// the one the resolver applies. A client uses the keys to stop offering what it
// would be refused; it never decides anything with them.

open JestGlobals

type scsComponent = Component.t<
  ReventlessInfra.StateChangeSlice.t,
  ReventlessInfra.StateChangeSlice.outputs,
  ReventlessInfra.StateChangeSlice.operations,
>
type svsComponent = Component.t<
  ReventlessInfra.StateViewSlice.t,
  ReventlessInfra.StateViewSlice.outputs,
  ReventlessInfra.StateViewSlice.operations,
>

module PsGatedCommandsSlice: ReventlessInfra.StateChangeSlice.T = {
  module Spec = PsGatedCommands
  module Behavior = {
    type state = PsGatedCommands.state
    let initialState = PsGatedCommands.initialState
    let evolve = PsGatedCommands.evolve
    let decide = PsGatedCommands.decide
    let moduleUrl = PsGatedCommands.moduleUrl
  }
  let isAsync = false
  type component = scsComponent
  let make = (
    ~dcbEventLog as _,
    ~publishJsons as _,
    ~tagKeysByEventType as _=?,
    ~crossPartitionTagKeys as _=?,
    ~partitionTag as _=?,
    ~runtime as _=?,
    ~opts as _=?,
  ): component => Obj.magic(0)
}

module PsGatedViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsGatedView
  module Projection = {
    let project = PsGatedView.project
    let moduleUrl = PsGatedView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}

module PsOrdersViewSlice: ReventlessInfra.StateViewSlice.T = {
  module Spec = PsOrdersView
  module Projection = {
    let project = PsOrdersView.project
    let moduleUrl = PsOrdersView.moduleUrl
  }
  type component = svsComponent
  let make = (~dcbEventLog as _, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}

let structure = Plugin_Structure.make(
  ~name="AccessPlugin",
  ~stateChangeSlices=[module(PsGatedCommandsSlice)],
  ~stateViewSlices=[module(PsGatedViewSlice), module(PsOrdersViewSlice)],
)

let commandNamed = name =>
  structure.stateChangeSlices
  ->Array.flatMap(w => w.commands)
  ->Array.find(c => c.name === name)
  ->Option.flatMap(c => c.requiredAccess)

let viewNamed = name =>
  structure.stateViewSlices
  ->Array.find(q => q.name === name)
  ->Option.flatMap(q => q.requiredAccess)

describe("requiredAccess derived from the authorization rule", () => {
  testSync("an AllowRoles command publishes its groups", () =>
    expect(commandNamed("Restock"))->toEqual(Some(["Admin", "Ops"]))
  )

  // The reason the rule is evaluated per constructor rather than per component:
  // one slice, two audiences, and a component-level shortcut would gate both.
  testSync("a sibling command in the same slice publishes nothing", () =>
    expect(commandNamed("RequestRestock"))->toEqual(None)
  )

  testSync("a module-level rule reaches the view it guards", () =>
    expect(viewNamed("GatedView"))->toEqual(Some(["Admin"]))
  )

  testSync("an unannotated view publishes nothing", () =>
    expect(viewNamed("Orders"))->toEqual(None)
  )

  // Null rather than `[]` on the wire: "no key gates this" is one answer, and a
  // def written before the field existed has to read as the same thing.
  testSync("nothing to require encodes as null, not an empty list", () => {
    let json =
      Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
        ~pluginId="AccessPlugin",
        structure,
      )->JSON.stringify
    expect((
      json->String.includes(`"requiredAccess":null`),
      json->String.includes(`"requiredAccess":["Admin","Ops"]`),
      json->String.includes(`"requiredAccess":[]`),
    ))->toEqual((true, true, false))
  })

  // The access keys are compared with a token's groups, so they are the groups
  // the roles map to; the roles themselves travel beside them for the deploy
  // check.
  testSync("a renamed role publishes its group as the key and its role as the role", () => {
    Reventless.Role.clearGroups()
    Reventless.Role.setGroups([(Reventless.Role.make("Ops"), "shop-ops")])
    let renamed = Plugin_Structure.make(
      ~name="AccessPlugin",
      ~stateChangeSlices=[module(PsGatedCommandsSlice)],
    )
    Reventless.Role.clearGroups()
    let restock =
      renamed.stateChangeSlices
      ->Array.flatMap(w => w.commands)
      ->Array.find(c => c.name === "Restock")
    expect(restock->Option.map(c => (c.requiredAccess, c.requiredRoles)))->toEqual(
      Some((Some(["Admin", "shop-ops"]), Some(["Admin", "Ops"]))),
    )
  })

  testSync("a command that names no role publishes no roles", () =>
    expect(
      structure.stateChangeSlices
      ->Array.flatMap(w => w.commands)
      ->Array.find(c => c.name === "RequestRestock")
      ->Option.flatMap(c => c.requiredRoles),
    )->toEqual(None)
  )
})

module PsTwoRuleFeed = {
  let name = "PsTwoRuleFeed"
  let moduleUrl = "ps-two-rule-feed://spec"
  @schema type externalInput = {sku: string}
  @schema type command = AddProduct({sku: string}) | AddCategory({sku: string})
  let targetName = "AddProduct"
  let externalSystem = None
  type role = Reventless.Role.name
  let authorizationOf = (name: string): Reventless.Authorization.rule<role> =>
    switch name {
    | "AddProduct" => AllowRoles([Reventless.Role.make("Merchandiser")])
    | "AddCategory" => AllowRoles([Reventless.Role.make("Admin")])
    | _ => DenyAll
    }
}

module PsTwoRuleFeedSlice: ReventlessInfra.InboundTranslationSlice.T = {
  module Spec = PsTwoRuleFeed
  module Translation = {
    let translate = (_: PsTwoRuleFeed.externalInput) => Ok([])
    let moduleUrl = PsTwoRuleFeed.moduleUrl
  }
  type component = Component.t<
    ReventlessInfra.InboundTranslationSlice.t,
    ReventlessInfra.InboundTranslationSlice.outputs,
    ReventlessInfra.InboundTranslationSlice.operations,
  >
  let queryDbName = "PsTwoRuleFeedAudit"
  let make = (~publishJsons as _, ~runtime as _=?, ~opts as _=?): component => Obj.magic(0)
}

describe("an inbound slice's roles", () => {
  let door = Dcb_Builder.inboundDoorPermission(
    PsTwoRuleFeed.commandSchema,
    PsTwoRuleFeed.authorizationOf,
  )

  testSync("the door admits any constructor's roles", () =>
    expect(door->Option.map(Reventless.Authorization.rolesOf))->toEqual(
      Some([Reventless.Role.make("Merchandiser"), Reventless.Role.make("Admin")]),
    )
  )

  testSync("requiredRoles are the door's roles", () => {
    let inbound =
      Plugin_Structure.make(
        ~name="AccessPlugin",
        ~inboundTranslationSlices=[module(PsTwoRuleFeedSlice)],
      ).inboundTranslationSlices->Array.get(0)
    let doorRoles =
      door->Option.map(
        rule => rule->Reventless.Authorization.rolesOf->Array.map(r => (r :> string)),
      )
    expect(inbound->Option.flatMap(s => s.requiredRoles))->toEqual(doorRoles)
  })
})
