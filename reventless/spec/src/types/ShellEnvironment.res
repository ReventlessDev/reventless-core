/***
Which environment a host shell runs in, as `config.json` tells it: the name, and
the purpose when it is known. The shell badges everything that is not
`production`, so an unknown purpose shows rather than hides.

One answer for every caller, from the two the deploy already gives: a declared
environment ([DeploymentProvenance]) and the stacks the platform treats as
production. Pure; the caller passes the stack and the list.
*/

type t = {name: string, purpose?: string}

let nameKey = "environment"
let purposeKey = "environmentPurpose"

/** What the local platform says about itself. */
let local = {name: "local", purpose: "local"}

/**
The declared environment wins over the stack, its purpose over the stack list.
A stack in `prodStacks` with no declared purpose is `production`; any other is
unknown.
*/
let resolve = (
  ~provenance: DeploymentProvenance.t,
  ~stack: string,
  ~prodStacks: array<string>,
): t => {
  name: provenance.environment->Option.getOr(stack),
  purpose: ?(
    provenance.purpose->Option.orElse(
      prodStacks->Array.includes(stack) ? Some(Environments.purposeName(Production)) : None,
    )
  ),
}

/** The `config.json` entries; no purpose key when the purpose is unknown. */
let configFields = (env: t): array<(string, JSON.t)> =>
  [(nameKey, JSON.Encode.string(env.name))]->Array.concat(
    env.purpose->Option.mapOr([], p => [(purposeKey, JSON.Encode.string(p))]),
  )
