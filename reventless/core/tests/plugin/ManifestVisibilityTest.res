// Verifies that ReadModel.Spec.visibility flows through PPX injection, that the
// filter predicate used by Plugin_Builder.makeAutoUIManifest excludes Internal
// entries while leaving Public ones intact, and that Plugin_Structure.make
// CARRIES Internal entries but tags them via `queryableDef.visibility` (the
// dev-graph contract). Does NOT instantiate the full Plugin_Builder.Make functor
// — the filter is a pure switch on a Spec field and is therefore testable in
// isolation via stubbed ReadModel.T modules.

open JestGlobals

// Public ReadModel — no @@reventless.visibility attribute, PPX defaults to Public.
module PublicSpec = {
  module Id = Reventless.Id.StringPure
  let name = "PublicView"
  let moduleUrl = ""

  @schema
  type state = {id: string, name: string}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
  // PPX walk_inline_specs injects authorization = AllowAuthenticated
  //                                visibility    = Public
}

// Internal ReadModel — manually setting visibility = Internal here mirrors what
// @@reventless.visibility(Internal) injects in a real spec file.
module InternalSpec = {
  module Id = Reventless.Id.StringPure
  let name = "InternalView"
  let moduleUrl = ""

  @schema
  type state = {id: string, name: string}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
  let visibility: Reventless.Visibility.t = Internal
}

module PublicReadModel: ReventlessInfra.ReadModel.T
  with type api = unit and type role = unit = {
  module Spec = PublicSpec
  type api = unit
  type role = unit
  type component
  let sourceNames: array<string> = []
  // A read model that projects an event reaching it via a (DCB-log-sourced) mapping — the
  // case Plugin_Structure must surface as a qualified `consumedEventTypes` entry.
  let consumedEventNames: array<string> = ["OrderPlaced"]
  let make = (~api as _, ~apiRole as _, ~allEventTopics as _, ~runtime as _=?, ~opts as _=?): component =>
    Obj.magic(0)
  let outputs = (_: component): ReventlessInfra.ReadModel.outputs => Obj.magic(0)
  let operations = (_: component): Pulumi.Output.t<ReventlessInfra.ReadModel.operations> =>
    Obj.magic(0)
  let finish = () => ()
}

module InternalReadModel: ReventlessInfra.ReadModel.T
  with type api = unit and type role = unit = {
  module Spec = InternalSpec
  type api = unit
  type role = unit
  type component
  let sourceNames: array<string> = []
  let consumedEventNames: array<string> = []
  let make = (~api as _, ~apiRole as _, ~allEventTopics as _, ~runtime as _=?, ~opts as _=?): component =>
    Obj.magic(0)
  let outputs = (_: component): ReventlessInfra.ReadModel.outputs => Obj.magic(0)
  let operations = (_: component): Pulumi.Output.t<ReventlessInfra.ReadModel.operations> =>
    Obj.magic(0)
  let finish = () => ()
}

let isVisible = (
  module(R: ReventlessInfra.ReadModel.T with type api = unit and type role = unit),
): bool =>
  switch R.Spec.visibility {
  | Public => true
  | Internal => false
  }

let readModels: array<
  module(ReventlessInfra.ReadModel.T with type api = unit and type role = unit),
> = [module(PublicReadModel), module(InternalReadModel)]

describe("ReadModel visibility filter", () => {
  testSync("PPX defaults visibility to Public when no attribute is present", () => {
    expect(PublicSpec.visibility)->toEqual(Reventless.Visibility.Public)
  })

  testSync("Internal spec retains Internal value", () => {
    expect(InternalSpec.visibility)->toEqual(Reventless.Visibility.Internal)
  })

  testSync("filter predicate excludes Internal", () => {
    let visible = readModels->Array.filter(isVisible)
    expect(visible->Array.length)->toBe(1)
  })

  testSync("filter predicate retains Public name", () => {
    let visible = readModels->Array.filter(isVisible)
    let first = visible->Array.getUnsafe(0)
    let module(R) = first
    expect(R.Spec.name)->toEqual("PublicView")
  })

  testSync("unfiltered list still contains both entries (no over-filtering)", () => {
    expect(readModels->Array.length)->toBe(2)
  })
})

describe("Plugin_Structure.make — visibility tagging", () => {
  // pluginStructure CARRIES Internal read models (so the dev graph / dead-code
  // tools can see them) and tags each via `queryableDef.visibility`
  // (`None` = Public, `Some("Internal")` = Internal). The deployed AutoUI
  // consumers re-filter on that tag — visibility does not remove entries from
  // pluginStructure itself. See Plugin_Structure.res / Visibility.res.
  let structure = Plugin_Structure.make(~name="VisibilityPlugin", ~readModels)

  testSync("readModels carries both Public and Internal entries", () => {
    expect(structure.readModels->Array.length)->toBe(2)
  })

  testSync("the Public entry is tagged visibility = None", () => {
    let public = structure.readModels->Array.find(d => d.name == "PublicView")
    expect(public->Option.map(d => d.visibility))->toEqual(Some(None))
  })

  testSync("the Internal entry is carried and tagged visibility = Some(\"Internal\")", () => {
    let internal = structure.readModels->Array.find(d => d.name == "InternalView")
    expect(internal->Option.map(d => d.visibility))->toEqual(Some(Some("Internal")))
  })

  testSync("a read model's mapping-consumed events surface as qualified consumedEventTypes", () => {
    // Q6 #2: a classic read model fed via a (DCB-log-sourced) mapping now reflects the
    // events it projects from, qualified to the plugin — so DomainGraph draws the
    // Event→ReadModel projection edge (e.g. OrderPlaced → Customers).
    let public = structure.readModels->Array.find(d => d.name == "PublicView")
    expect(public->Option.map(d => d.consumedEventTypes))->toEqual(
      Some(["VisibilityPlugin.OrderPlaced"]),
    )
  })

  testSync("aggregates / stateViewSlices stay empty when none are passed (sanity)", () => {
    expect((
      structure.aggregates->Array.length,
      structure.stateViewSlices->Array.length,
    ))->toEqual((0, 0))
  })
})
