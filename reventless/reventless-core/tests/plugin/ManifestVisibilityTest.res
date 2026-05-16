// Verifies that ReadModel.Spec.visibility flows through PPX injection and that
// the same filter predicate used by Plugin_Builder.makeAutoUIManifest excludes
// Internal entries while leaving Public ones intact. Does NOT instantiate the
// full Plugin_Builder.Make functor — the filter is a pure switch on a Spec field
// and is therefore testable in isolation via stubbed ReadModel.T modules.

open Jest
open Expect

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
  let make = (~api as _, ~apiRole as _, ~allEventTopics as _, ~opts as _=?): component =>
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
  let make = (~api as _, ~apiRole as _, ~allEventTopics as _, ~opts as _=?): component =>
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
  test("PPX defaults visibility to Public when no attribute is present", () => {
    expect(PublicSpec.visibility)->toEqual(Reventless.Visibility.Public)
  })

  test("Internal spec retains Internal value", () => {
    expect(InternalSpec.visibility)->toEqual(Reventless.Visibility.Internal)
  })

  test("filter predicate excludes Internal", () => {
    let visible = readModels->Array.filter(isVisible)
    expect(visible->Array.length)->toBe(1)
  })

  test("filter predicate retains Public name", () => {
    let visible = readModels->Array.filter(isVisible)
    let first = visible->Array.getUnsafe(0)
    let module(R) = first
    expect(R.Spec.name)->toEqual("PublicView")
  })

  test("unfiltered list still contains both entries (no over-filtering)", () => {
    expect(readModels->Array.length)->toBe(2)
  })
})
