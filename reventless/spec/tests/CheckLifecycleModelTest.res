open JestGlobals

// The verdict logic of the lifecycle check, reachable at all only because the
// module no longer calls `main` at the top level — `run-check-lifecycle.mjs`
// does. While the call was there, importing this ran the whole check and then
// exited the process, so the pure functions below could not be reached.
//
// What these pin is the distinction the check turns on: a command that is
// *refused* somewhere against one that is *accepted and silent* there. Both
// produce no event, and only the first says anything about which states a
// command is legal in.

module Check = CheckLifecycleModel

let observation = (~command, ~from, ~outcome, ~to_="") => {
  Check.title: `${command} from ${from}`,
  command,
  from,
  outcome,
  to: to_ == "" ? from : to_,
}

let derive = observations =>
  Check.deriveCommands(~component="Customer", ~observations, ~labelled=true)
  ->Array.get(0)
  ->Option.getOrThrow

describe("deriveCommands separates a refusal from an accepted no-op", () => {
  // The shape that prompted this: a verdict reported by another slice. It takes
  // effect from Active, is deliberately swallowed after deactivation so the
  // reporting slice does not retry forever, and is refused only where there is
  // no row at all.
  let verdict = derive([
    observation(~command="MarkEmailVerified", ~from="Active", ~outcome=Check.Emitted),
    observation(~command="MarkEmailVerified", ~from="Active", ~outcome=Check.NoChange),
    observation(~command="MarkEmailVerified", ~from="Deactivated", ~outcome=Check.NoChange),
  ])

  testSync("a state it takes effect from is in the from-set", () =>
    expect(verdict.allowedStates)->toEqual(["Active"])
  )

  testSync("both silent states are inert", () =>
    expect(verdict.inertStates)->toEqual(["Active", "Deactivated"])
  )

  // The whole point: silence is not refusal. `Ok([])` for a command that would
  // change nothing is this codebase's idempotency convention, required because
  // commands arrive at least once.
  testSync("but neither is refused", () => expect(verdict.refusedStates)->toEqual([]))

  testSync("a genuine refusal is recorded as one", () => {
    let guarded = derive([
      observation(
        ~command="Deactivate",
        ~from="Active",
        ~outcome=Check.Emitted,
        ~to_="Deactivated",
      ),
      observation(~command="Deactivate", ~from="Deactivated", ~outcome=Check.Refused),
    ])
    expect((guarded.inertStates, guarded.refusedStates))->toEqual((
      ["Deactivated"],
      ["Deactivated"],
    ))
  })
})

// `Unrestricted` claims the command is never *refused*. It does not claim the
// command always emits, so a state where it is accepted and silent agrees with
// it. Reading `inertStates` here marked every idempotent legal-everywhere
// command contradicted — the opposite of what its corpus showed.
describe("an Unrestricted claim is refuted by a refusal, not by silence", () => {
  let verdictsFor = (~observations, ~allowedStatesSource) => {
    let findings = []
    Check.compare(
      ~plugin="ordering",
      ~writable={
        Check.name: "Customer",
        linkedViews: ["Customers"],
        commands: [
          {
            Check.command: "MarkEmailVerified",
            level: "Instance",
            aggregateIdField: None,
            allowedStates: None,
            targetState: None,
            allowedStatesSource,
          },
        ],
      },
      ~derived=derive(observations),
      ~findings,
    )
    findings->Array.filter(f => f.Check.severity == "contradicted")
  }

  let silentSomewhere = [
    observation(~command="MarkEmailVerified", ~from="Active", ~outcome=Check.Emitted),
    observation(~command="MarkEmailVerified", ~from="Deactivated", ~outcome=Check.NoChange),
  ]

  testSync("a swallowed command in a state it declares legal is not a contradiction", () =>
    expect(
      verdictsFor(~observations=silentSomewhere, ~allowedStatesSource=Some("unrestricted")),
    )->toEqual([])
  )

  testSync("a refusal in a state it declares legal is", () => {
    let found = verdictsFor(
      ~observations=[
        observation(~command="MarkEmailVerified", ~from="Active", ~outcome=Check.Emitted),
        observation(~command="MarkEmailVerified", ~from="Deactivated", ~outcome=Check.Refused),
      ],
      ~allowedStatesSource=Some("unrestricted"),
    )
    expect(found->Array.map(f => f.Check.states))->toEqual([["Deactivated"]])
  })

  // The claim the other branch makes is stronger — a named from-set says the
  // command takes effect from those states — so inertness still refutes it
  // there. Guarded so the narrower reading does not leak across.
  testSync("a command that declares no source at all reports nothing here", () =>
    expect(verdictsFor(~observations=silentSomewhere, ~allowedStatesSource=None))->toEqual([])
  )
})
