open JestGlobals

// Guards the carrier that tells a Lambda runtime which groups are exempt from
// owner scoping. The deploy program bakes the read predicate itself, but
// stamping and SQL-backed reads run in function runtimes it never enters, so
// without this entry those runtimes conclude nobody is elevated — and an
// operator's on-behalf write is then stamped with the operator's own id.
//
// The encoding is load-bearing in both directions: what is written here is read
// back by `OwnerScope.parseElevatedGroups`, so the two are asserted together
// rather than each against a literal.

let withElevated = (groups, f) => {
  Reventless.OwnerScope.setElevatedGroups(groups)
  let result = f()
  Reventless.OwnerScope.clearElevatedGroups()
  result
}

describe("Util_OwnerScopeEnv — the elevated-groups carrier", () => {
  testSync("writes what OwnerScope reads back", () => {
    let encoded = withElevated(
      ["Admin", "Support"],
      () =>
        switch Util_OwnerScopeEnv.entry() {
        | Some((_, value)) => value->Obj.magic
        | None => ""
        },
    )
    // The round trip, not the spelling: a separator change on either side fails.
    expect(Reventless.OwnerScope.parseElevatedGroups(encoded))->toEqual(["Admin", "Support"])
  })

  testSync("names the variable the runtime actually reads", () => {
    expect(Util_OwnerScopeEnv.key)->toBe("REVENTLESS_ELEVATED_GROUPS")
  })

  testSync("no elevated groups means no variable, not an empty one", () => {
    let entry = withElevated([], () => Util_OwnerScopeEnv.entry())
    expect(entry->Option.isNone)->toBe(true)
  })

  testSync("defaults the variable when the caller pinned nothing", () => {
    let variables = Dict.make()
    withElevated(["Admin"], () => Util_OwnerScopeEnv.applyElevatedGroupsDefault(variables))
    expect(variables->Dict.get(Util_OwnerScopeEnv.key)->Option.isSome)->toBe(true)
  })

  testSync("a caller that pinned the variable wins", () => {
    let variables = Dict.fromArray([(Util_OwnerScopeEnv.key, "Pinned"->Obj.magic)])
    withElevated(["Admin"], () => Util_OwnerScopeEnv.applyElevatedGroupsDefault(variables))
    expect(
      variables->Dict.get(Util_OwnerScopeEnv.key)->Option.getOr(""->Obj.magic)->Obj.magic,
    )->toBe("Pinned")
  })

  testSync("adds nothing when the deployment named no elevated groups", () => {
    let variables = Dict.make()
    withElevated([], () => Util_OwnerScopeEnv.applyElevatedGroupsDefault(variables))
    expect(variables->Dict.get(Util_OwnerScopeEnv.key)->Option.isNone)->toBe(true)
  })

  // The whole path the "administrator sees empty screens" trap ran through: the
  // platform entry point defaults the list, and this composes it into a Lambda's
  // environment. Asserted end to end rather than at either half, because both
  // halves were already correct while the trap was open — the pipe was laid and
  // nothing ever put a value in.
  testSync("the platform's administrator default reaches a composed environment", () => {
    Reventless.OwnerScope.clearElevatedGroups()
    NodeProcess.env->Dict.delete(Util_OwnerScopeEnv.key)
    Reventless.OwnerScope.defaultElevatedGroups([Reventless.AdminGroup.name])

    let variables = Dict.make()
    Util_OwnerScopeEnv.applyElevatedGroupsDefault(variables)
    let encoded = switch variables->Dict.get(Util_OwnerScopeEnv.key) {
    | Some(value) => value->Obj.magic
    | None => ""
    }
    Reventless.OwnerScope.clearElevatedGroups()

    // Round-tripped, like the first case above: the runtime reads this back with
    // `parseElevatedGroups`, so the encoding is asserted rather than the spelling.
    expect(Reventless.OwnerScope.parseElevatedGroups(encoded))->toEqual([
      Reventless.AdminGroup.name,
    ])
  })
})
