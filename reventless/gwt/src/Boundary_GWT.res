// Whether a DCB consistency boundary derives its tag scope over all its slices.
//
// One slice's own test cannot show this: a single slice always resolves, so the
// all-or-nothing fallback in `deriveEffectiveScope` (one unresolvable slice
// discarding the derived scope for every slice beside it) has no per-slice
// symptom. The slices keep passing their own tests while the platform rejects
// valid commands. `generate-plugin` writes this test for every system, over its
// `Plugin.dcbSliceSchemas`, so the boundary is checked as deployed with no test
// written for it.

let resolves = (~name: string, slices: array<Reventless.DcbTag.sliceSchemas>): Outcome.outcome => {
  let scope = Reventless.DcbTag.deriveEffectiveScope(slices)
  // Deploy and boot derive the storage partition from the same slices and refuse
  // the boundary when it fails, so the test fails with their reasons.
  let partitionReasons = {
    let shapes = slices->Array.map(Reventless.DcbTag.sliceShape)
    let hints = Reventless.DcbValidation.validatePartitionHintsVsInference(~shapes)
    let arms = Reventless.DcbValidation.validateCrossPartitionArms(
      ~shapes,
      ~inferred=Reventless.DcbScopeInference.infer(shapes),
    )
    let contradictions =
      hints.contradictions
      ->Array.concat(arms.contradictions)
      ->Array.map(e => `${e.sliceName}: ${e.message}`)
    switch Reventless.DcbTag.deriveBoundaryPartition(slices) {
    | _ => contradictions
    | exception JsExn(err) =>
      contradictions->Array.concat([
        JsExn.message(err)->Option.getOr("partition derivation failed"),
      ])
    }
  }

  // Beyond that, an ambiguity that costs nothing is not a failure: a boundary whose
  // fallback carries every derived key reads exactly as the derivation would. What
  // fails is losing a key, because that is the case where the runtime answers wrongly.
  if partitionReasons->Array.length > 0 {
    Outcome.fail(PartitionUnresolved({boundary: name, reasons: partitionReasons}))
  } else if scope.droppedCrossPartitionTagKeys->Array.length > 0 {
    Outcome.fail(
      ScopeDegraded({
        boundary: name,
        dropped: scope.droppedCrossPartitionTagKeys,
        ambiguities: scope.ambiguities->Array.map(((slice, reason)) => `${slice}: ${reason}`),
      }),
    )
  } else {
    Outcome.pass
  }
}

/** The test of one system's boundary, named for the system. */
let test = (~system: string, slices: array<Reventless.DcbTag.sliceSchemas>) =>
  JestBind.test(~slice=system, `the ${system} boundary derives its DCB scope`, () =>
    resolves(~name=system, slices)
  )
