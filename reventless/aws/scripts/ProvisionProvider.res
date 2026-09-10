/***
Which identity provider a provisioning run is about.

Both bins ask the same question and neither should make the operator answer it
twice. The docs used to say `--provider-id $(pulumi stack output
identityProviderId)`, which is a command substitution a tool can perform.

🚨 **Three sources, in this order, and the last is a fallback rather than the
path.** An explicit `--provider-id` wins, then `REVENTLESS_IDENTITY_PROVIDER_ID`
— the variable [Platform_Stack] reads for the same value, so a CI shell that
already exports it needs no second spelling — and only then the stack.

Reading the stack works in *both* modes, which is the fact that makes this worth
doing rather than a convenience for auto deployments only: [Platform_Stack]
exports `identityProviderId` whether it created the pool or was handed one, so a
BYO deployment re-exports the provider it was given.

🚨 **It always reports which source answered, and which stack.** `pulumi stack
output` with no `--stack` reads whichever stack happens to be selected, so a run
against `alpha` while the operator believes they are on `beta` would succeed —
in the wrong pool, leaving working accounts somewhere nobody is looking. That is
worse than failing. So the stack is resolved by name, named in the output, and
overridable with `--stack`.
*/

/** Where an id came from, so a run can say so rather than leave it inferred. */
type source =
  | Flag
  | Environment
  | Stack(string)

let describe = (source: source): string =>
  switch source {
  | Flag => "--provider-id"
  | Environment => "REVENTLESS_IDENTITY_PROVIDER_ID"
  | Stack(stack) => `stack ${stack}`
  }

/** The same variable [Platform_Stack] reads for the same value. */
let envKey = "REVENTLESS_IDENTITY_PROVIDER_ID"

/** `stdio` leaves stderr to the caller's terminal but keeps stdout, so a Pulumi
  failure is legible where it happens instead of being swallowed and re-reported
  as a vaguer message here. */
let pulumi = (args: array<string>): string =>
  NodeChildProcess.execFileSync(
    "pulumi",
    args,
    {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]},
  )->String.trim

/** The stack the working directory currently has selected. `None` when there is
  no Pulumi project here, no stack selected, or no `pulumi` on the PATH — all of
  which are ordinary for someone running against a BYO pool, and none of which
  should be an error until the id is actually needed. */
let selectedStack = (): option<string> =>
  switch pulumi(["stack", "--show-name"]) {
  | "" => None
  | name => Some(name)
  | exception _ => None
  }

/**
The provider id a stack exports.

`--stack` is passed explicitly even when it names the already-selected stack, so
the value read and the name reported cannot drift apart between the two calls.
*/
let fromStack = (~stack: string): result<string, string> =>
  switch pulumi(["stack", "output", "identityProviderId", "--stack", stack]) {
  | "" =>
    Error(
      `stack "${stack}" exports no identityProviderId — deploy the platform stack first, or pass --provider-id`,
    )
  | id => Ok(id)
  | exception _ =>
    Error(
      `could not read identityProviderId from stack "${stack}" — is pulumi installed, logged in, and the stack deployed? Pass --provider-id to skip this lookup`,
    )
  }

/**
The provider this run is about, and where the answer came from.

The error names all three sources rather than only the one that was tried last:
someone who has no Pulumi project here needs to be told about the flag, and
someone who has one needs to be told it was consulted and came back empty.
*/
let resolve = (~given: option<string>, ~stack: option<string>): result<(string, source), string> =>
  switch given {
  | Some(id) => Ok((id, Flag))
  | None =>
    switch NodeProcess.env->Dict.get(envKey) {
    | Some(id) if id->String.trim != "" => Ok((id, Environment))
    | _ =>
      switch stack->Option.orElse(selectedStack()) {
      | None =>
        Error(
          `--provider-id is required (or set ${envKey}). It is also read from a deployed stack, but no Pulumi stack is selected here — run this from the platform package, or pass --stack`,
        )
      | Some(stack) => fromStack(~stack)->Result.map(id => (id, Stack(stack)))
      }
    }
  }
