// Carries the deployment's elevated groups into Lambda runtimes.
//
// A cloud deployment is two kinds of process and only one of them is the deploy
// program: it bakes the owner predicate into generated resolver source, while
// command stamping (`CommandGenerator_Callback`) and SQL-backed reads
// (`PgQueryResolver_Lambda`) run later, in function runtimes the deploy never
// enters. `Reventless.OwnerScope.elevatedGroups()` answers from an explicit
// `setElevatedGroups` or from the environment, so a value stated in the deploy
// program reaches those runtimes only if something puts it in their environment.
//
// Nothing did, and the two halves fail in opposite directions. A read that
// believes nobody is elevated shows an operator too little, which is safe and
// visible. A write that believes it stamps an operator's on-behalf order with
// the OPERATOR's id — silently, and the row is wrong from then on. The second is
// why this is a correctness fix rather than a parity one.
//
// Scoped deliberately to `RuntimeEnvironment_Lambda.makeFromCodeAsset`, which
// every command and query runtime is built through. The bespoke builders that
// append `Util_LambdaLogging.logLevelEntry()` for themselves — dead letters, the
// state-topic publisher, geocoding, the two upload Lambdas, the platform UI APIs
// — neither stamp a command nor serve an owner-scoped view, so they sit outside
// this policy for the same reason they sit outside several others. The
// serialized-closure `make` path is likewise outside it, and already outside the
// logging policy.

let key = "REVENTLESS_ELEVATED_GROUPS"

/** The `("REVENTLESS_ELEVATED_GROUPS", "Admin,Support")` entry, or `None` when
    the deployment named no elevated groups.

    Comma-separated because that is what `OwnerScope.parseElevatedGroups` reads,
    which trims each part and drops the empties. Absent rather than empty for the
    empty case: the two mean the same thing there, and writing `""` would suggest
    a deployment had answered the question when it has not. */
let entry = (): option<(string, Pulumi.Input.t<string>)> =>
  switch Reventless.OwnerScope.elevatedGroups() {
  | [] => None
  | groups => Some((key, groups->Array.join(",")->Pulumi.Input.make))
  }

/** Default the elevated groups for a Lambda when the caller has not pinned them.
    Mutates in place and must run after the caller's own env vars are set, so
    theirs win — the same contract as `Util_LambdaLogging.applyLogLevelDefault`,
    which it runs beside. */
let applyElevatedGroupsDefault = (variables: dict<Pulumi.Input.t<string>>) =>
  if variables->Dict.get(key)->Option.isNone {
    entry()->Option.forEach(((k, v)) => variables->Dict.set(k, v))
  }
