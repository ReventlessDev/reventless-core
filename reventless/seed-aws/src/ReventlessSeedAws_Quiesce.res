// Taking a deployed stack's runtimes out of service for the length of a wipe,
// and putting them back exactly as they were.
//
// Why a wipe needs this at all: a truncate is not durable while the runtimes
// that own the data are running. A slice runtime keeps its TODO list in a
// module-level dict for the lifetime of its execution environment and re-saves
// every row it holds at the end of each invocation — including the scheduled
// sweep, which carries no events. Emptying the table under a warm container
// therefore succeeds and is then undone, byte for byte, by the next sweep: the
// rows are not recomputed from anything, so their ids and timestamps come back
// identical. Emptying the upstream stores first does not help, because nothing
// upstream is read.
//
// The answer is to remove the contention rather than to outrun it, which takes
// two distinct steps, in this order:
//
//   1. HOLD — reserve 0 concurrency on every function in scope, so no new
//      invocation can start while the wipe and its verification run. This alone
//      is not enough: a reservation stops invocations, it does not discard the
//      execution environment that holds the state.
//   2. RECYCLE — change each function's configuration once. A configuration
//      change is the documented way to make Lambda discard existing execution
//      environments, so whatever a warm container was holding is gone before it
//      can be invoked again. Done while still held, so the container that
//      eventually replaces it starts from the emptied store.
//
// The recycle is a round trip — a marker variable added, then the original map
// put back — so the function ends the run byte-identical to how it started and
// `pulumi preview` reports no drift. The second update recycles again, which is
// harmless: it happens while the hold is still on and the store is already
// empty.
//
// Everything acquired here is released on the failure path as well as the
// success path, and the release never throws: a reset that aborted mid-wipe
// must still hand the stack back. Release failures come back as warnings for
// the caller to print, because a function left at zero concurrency is a stack
// left switched off, and that has to be said out loud rather than raised as one
// more exception on top of whatever already went wrong.

module Lambda = AwsSdk.Lambda

/** The variable a recycle adds and then removes. Named for what it is, so an
    operator who finds one left behind by a killed run knows it is inert and can
    be deleted (or left for the next `pulumi up` to remove). */
let markerKey = "REVENTLESS_RESET_RECYCLE"

/** What one function looked like before the reset touched it. */
type held = {
  functionName: string,
  /** `None` = the function had no reservation at all. That is a different state
      from a reservation of 0, and restoring it needs
      `DeleteFunctionConcurrency` rather than a put. */
  priorReserved: option<int>,
  /** The variable map as it was, flattened: a function with no `Environment`
      block at all reads as an empty map and is restored to an empty map. */
  priorVariables: dict<string>,
}

/** The Lambda control plane is rate-limited well below the data plane, and a
    reset touches every function in a project at once. Six at a time keeps a
    forty-function stack under a minute per pass without risking a throttle. */
let concurrency = 6

let mapBounded = async (items: array<'a>, ~limit: int, f: 'a => promise<'b>): array<'b> => {
  let results = Array.make(~length=items->Array.length, None)
  let next = ref(0)
  let worker = async () => {
    let running = ref(true)
    while running.contents {
      let i = next.contents
      if i >= items->Array.length {
        running := false
      } else {
        next := i + 1
        let r = await f(items->Array.getUnsafe(i))
        results->Array.set(i, Some(r))
      }
    }
  }
  let _ = await Array.fromInitializer(~length=Math.Int.min(limit, items->Array.length), _ =>
    worker()
  )->Promise.all
  results->Array.filterMap(x => x)
}

let errorText = (exn: exn): string =>
  exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown error")

// An update is rejected while another is still settling, and a stack that was
// deployed moments ago can still be settling. Poll rather than assume.
let awaitSettled = async (~client, ~functionName: string): unit => {
  let deadline = 60
  let rec poll = async (attempt: int): unit =>
    if attempt < deadline {
      let out = await Lambda.GetFunctionConfigurationCommand.send(
        client,
        Lambda.GetFunctionConfigurationCommand.make({functionName: functionName}),
      )
      switch out.lastUpdateStatus {
      | Some("InProgress") =>
        await ReventlessSeed.Seed.Client.sleep(1000)
        await poll(attempt + 1)
      | _ => ()
      }
    }
  await poll(0)
}

let updateVariables = async (~client, ~functionName: string, ~variables: dict<string>): unit => {
  await awaitSettled(~client, ~functionName)
  let _ = await Lambda.UpdateFunctionConfigurationCommand.send(
    client,
    Lambda.UpdateFunctionConfigurationCommand.make({
      functionName,
      environment: {variables: variables},
    }),
  )
  await awaitSettled(~client, ~functionName)
}

/** Put one function's reservation back exactly as it was — a value it had, or no
    reservation at all. Never throws: a function left reserved at 0 is a function
    left switched off, which has to be said rather than raised. */
let restoreConcurrency = async (~client, ~h: held): option<string> =>
  switch await (
    switch h.priorReserved {
    | Some(n) =>
      Lambda.PutFunctionConcurrencyCommand.send(
        client,
        Lambda.PutFunctionConcurrencyCommand.make({
          functionName: h.functionName,
          reservedConcurrentExecutions: n,
        }),
      )->Promise.thenResolve(_ => ())
    | None =>
      Lambda.DeleteFunctionConcurrencyCommand.send(
        client,
        Lambda.DeleteFunctionConcurrencyCommand.make({functionName: h.functionName}),
      )->Promise.thenResolve(_ => ())
    }
  ) {
  | () => None
  | exception exn =>
    Some(
      `LEFT SWITCHED OFF: could not restore concurrency on ${h.functionName} (${errorText(exn)}). ` ++
      `It is still reserved at 0 and will not run until that is undone.`,
    )
  }

/**
Hand the stack back: original environment first (which also drops the marker),
then the original concurrency.

That order matters. The environment restore is itself a configuration change, so
it recycles a second time; doing it while the function is still held means the
container that finally serves traffic is created after the restore, not during
it.

Never throws, for either step and for any function — this runs on the abort path
too, where an exception would replace the reason the reset failed with a
secondary one.
*/
let release = async (~client, ~held: array<held>): array<string> => {
  let warnings = await held->mapBounded(~limit=concurrency, async h => {
    let envWarning = switch await updateVariables(
      ~client,
      ~functionName=h.functionName,
      ~variables=h.priorVariables,
    ) {
    | () => None
    | exception exn =>
      Some(
        `could not restore the environment of ${h.functionName} (${errorText(exn)}) — it may still ` ++
        `carry ${markerKey}, which is inert and is removed by the next deploy.`,
      )
    }
    let concurrencyWarning = await restoreConcurrency(~client, ~h)
    [envWarning, concurrencyWarning]->Array.filterMap(w => w)
  })
  warnings->Array.flat
}

/**
Discard every held function's execution environments, so nothing that loaded
state before the wipe can write it back afterwards.

Never throws. A function that cannot be recycled is the one case where the reset
genuinely cannot promise the store stays empty, so it comes back as a warning
naming the function — the caller reports it rather than swallowing it.
*/
let recycle = async (~client, ~held: array<held>): array<string> => {
  let warnings = await held->mapBounded(~limit=concurrency, async h => {
    let marked = h.priorVariables->Dict.copy
    marked->Dict.set(markerKey, "1")
    switch await updateVariables(~client, ~functionName=h.functionName, ~variables=marked) {
    | () => None
    | exception exn =>
      Some(
        `could not recycle ${h.functionName} (${errorText(exn)}) — a warm container may still hold ` ++
        `pre-wipe state and write it back. Redeploy or update that function to clear it.`,
      )
    }
  })
  warnings->Array.filterMap(w => w)
}

/**
Take every named function out of service, recording what to put back.

Throws if any function cannot be held — before a single delete has been issued,
so a reset that cannot hold the platform still has the option of not starting.
The message names the IAM actions involved, because a missing permission is much
the likeliest cause and "AccessDenied" on its own does not say which one.

Crucially, it hands back whatever it did manage to take before throwing. The
functions are held concurrently, so a failure part-way through the batch leaves
earlier ones already at zero — and a reset that aborted while silently switching
off half a stack would be a worse failure than the one it was reporting. Only the
reservations are rolled back: this runs before `recycle`, so no environment has
been touched yet.
*/
let hold = async (~client, ~functionNames: array<string>): array<held> => {
  let attempts = await functionNames->mapBounded(~limit=concurrency, async functionName =>
    switch await (
      async () => {
        let concurrencyOut = await Lambda.GetFunctionConcurrencyCommand.send(
          client,
          Lambda.GetFunctionConcurrencyCommand.make({functionName: functionName}),
        )
        let configOut = await Lambda.GetFunctionConfigurationCommand.send(
          client,
          Lambda.GetFunctionConfigurationCommand.make({functionName: functionName}),
        )
        let held = {
          functionName,
          priorReserved: concurrencyOut.reservedConcurrentExecutions,
          priorVariables: configOut.environment
          ->Option.flatMap(e => e.variables)
          ->Option.getOr(Dict.make()),
        }
        let _ = await Lambda.PutFunctionConcurrencyCommand.send(
          client,
          Lambda.PutFunctionConcurrencyCommand.make({
            functionName,
            reservedConcurrentExecutions: 0,
          }),
        )
        held
      }
    )() {
    | held => Ok(held)
    | exception exn => Error((functionName, errorText(exn)))
    }
  )

  let taken = attempts->Array.filterMap(a =>
    switch a {
    | Ok(h) => Some(h)
    | Error(_) => None
    }
  )
  switch attempts->Array.findMap(a =>
    switch a {
    | Error(failure) => Some(failure)
    | Ok(_) => None
    }
  ) {
  | None => taken
  | Some((functionName, reason)) =>
    let rollback = await taken->mapBounded(~limit=concurrency, h => restoreConcurrency(~client, ~h))
    let stranded = rollback->Array.filterMap(w => w)
    throw(
      ReventlessSeed.Seed.Failed(
        `could not hold Lambda function ${functionName} at zero concurrency (${reason}) — nothing was ` ++
        `deleted. The reset holds every runtime in scope for the length of the wipe, which needs ` ++
        `lambda:GetFunctionConcurrency, lambda:GetFunctionConfiguration, lambda:PutFunctionConcurrency, ` ++
        `lambda:DeleteFunctionConcurrency and lambda:UpdateFunctionConfiguration. Set ` ++
        `SEED_RESET_NO_QUIESCE=1 to wipe without the hold — but a running runtime can then write back ` ++
        `what the wipe removes.` ++
        switch stranded {
        | [] => ""
        | messages => `\n\n  ` ++ messages->Array.join("\n  ")
        },
      ),
    )
  }
}
