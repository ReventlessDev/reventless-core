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

// Which command yields which event or error. An outcome is the whole `then`, so
// two events emitted together are one outcome rather than two alternatives; and
// an empty `then` is not evidence of anything, since the PPX writes the same
// `then: []` for `thenNoEvent` as for a step it could not read.
describe("commandOutcomes reads each command's outcomes off its scenarios", () => {
  let el = (name): Check.element => {name, values: []}
  let scenario = (~title, ~whenKind="command", ~when_, ~thenKind, ~then_=[]): Check.scenario => {
    title,
    given: [],
    whenKind,
    whenElements: when_->Array.map(el),
    thenKind,
    thenElements: then_->Array.map(el),
    thenValues: [],
  }
  let corpus = (~component, scenarios): Check.corpus => {
    component,
    path: `tests/${component}/Aggregate/${component}_GWT.gwt.json`,
    scenarios,
  }

  let found = Check.commandOutcomes(
    ~plugin="shop/ordering",
    ~corpora=[
      corpus(
        ~component="Order",
        [
          scenario(~title="placing", ~when_=["Place"], ~thenKind="event", ~then_=["OrderPlaced"]),
          scenario(
            ~title="placing twice",
            ~when_=["Place"],
            ~thenKind="error",
            ~then_=["OrderAlreadyPlaced"],
          ),
          scenario(
            ~title="placing again",
            ~when_=["Place"],
            ~thenKind="event",
            ~then_=["OrderPlaced"],
          ),
          scenario(
            ~title="shipping",
            ~when_=["Ship"],
            ~thenKind="event",
            ~then_=["OrderShipped", "InvoiceIssued"],
          ),
          scenario(~title="shipping a shipped order", ~when_=["Ship"], ~thenKind="noEvent"),
          scenario(~title="cancelling, unreadably", ~when_=["Cancel"], ~thenKind=""),
          scenario(~title="an opaque when", ~when_=[], ~thenKind="event", ~then_=["OrderPlaced"]),
        ],
      ),
      corpus(
        ~component="Customer",
        [
          scenario(
            ~title="registering",
            ~when_=["Register"],
            ~thenKind="event",
            ~then_=["Registered"],
          ),
        ],
      ),
      corpus(
        ~component="Orders",
        [
          scenario(
            ~title="a placed order is listed",
            ~whenKind="event",
            ~when_=["OrderPlaced"],
            ~thenKind="state",
          ),
        ],
      ),
    ],
  )

  let entry = command =>
    found->Array.find(e => e.Check.command == command)->Option.map(e => e.outcomes)

  testSync("entries are sorted by component, then command, and say something", () =>
    expect(found->Array.map(e => (e.Check.plugin, e.component, e.command)))->toEqual([
      ("shop/ordering", "Customer", "Register"),
      ("shop/ordering", "Order", "Place"),
      ("shop/ordering", "Order", "Ship"),
    ])
  )

  testSync("a single event, and an error, in order of first appearance", () =>
    expect(entry("Place"))->toEqual(
      Some([
        {Check.kind: "event", names: ["OrderPlaced"], scenarios: ["placing", "placing again"]},
        {kind: "error", names: ["OrderAlreadyPlaced"], scenarios: ["placing twice"]},
      ]),
    )
  )

  testSync("events emitted together are one outcome, and noEvent is its own", () =>
    expect(entry("Ship"))->toEqual(
      Some([
        {
          Check.kind: "event",
          names: ["OrderShipped", "InvoiceIssued"],
          scenarios: ["shipping"],
        },
        {kind: "noEvent", names: [], scenarios: ["shipping a shipped order"]},
      ]),
    )
  )

  // Only an empty `then`, so there is nothing to say, and no entry says it.
  testSync("an empty then is skipped, and a command left with nothing is omitted", () =>
    expect(entry("Cancel"))->toEqual(None)
  )

  testSync("a read model's event scenarios are not command outcomes", () =>
    expect(found->Array.some(e => e.Check.component == "Orders"))->toEqual(false)
  )

  testSync("the same outcome in two corpora of one component merges, titles deduplicated", () => {
    let twice = Check.commandOutcomes(
      ~plugin="shop/ordering",
      ~corpora=[
        corpus(
          ~component="Customer",
          [
            scenario(
              ~title="registering",
              ~when_=["Register"],
              ~thenKind="event",
              ~then_=["Registered"],
            ),
          ],
        ),
        corpus(
          ~component="Customer",
          [
            scenario(
              ~title="registering",
              ~when_=["Register"],
              ~thenKind="event",
              ~then_=["Registered"],
            ),
            scenario(
              ~title="registering by invitation",
              ~when_=["Register"],
              ~thenKind="event",
              ~then_=["Registered"],
            ),
          ],
        ),
      ],
    )
    expect(twice->Array.map(e => e.Check.outcomes))->toEqual([
      [
        {
          Check.kind: "event",
          names: ["Registered"],
          scenarios: ["registering", "registering by invitation"],
        },
      ],
    ])
  })
})

// How the check is invoked from outside this file: the editor extension runs
// `check-lifecycle --root <dir> --reuse-sidecars --json`, and CI runs
// `pnpm run check:lifecycle -- --reuse-sidecars`, which reaches here behind the
// `--` pnpm forwards.
describe("CheckLifecycleModel.parseArgs", () => {
  testSync("the editor extension's invocation", () =>
    expect(
      CheckLifecycleModel.parseArgs(["--root", "/app", "--reuse-sidecars", "--json"]),
    )->toEqual(
      Ok({
        CheckLifecycleModel.update: false,
        roots: ["/app"],
        reuseSidecars: true,
        json: true,
      }),
    )
  )

  testSync("CI's invocation, behind the -- pnpm forwards", () =>
    expect(CheckLifecycleModel.parseArgs(["--", "--reuse-sidecars"]))->toEqual(
      Ok({CheckLifecycleModel.update: false, roots: [], reuseSidecars: true, json: false}),
    )
  )

  testSync("no arguments checks every example", () =>
    expect(CheckLifecycleModel.parseArgs([]))->toEqual(
      Ok({CheckLifecycleModel.update: false, roots: [], reuseSidecars: false, json: false}),
    )
  )

  testSync("--update rewrites, and --root may be repeated", () =>
    expect(CheckLifecycleModel.parseArgs(["--update", "--root", "a", "--root", "b"]))->toEqual(
      Ok({CheckLifecycleModel.update: true, roots: ["a", "b"], reuseSidecars: false, json: false}),
    )
  )

  testSync("--root with no directory after it is refused", () =>
    expect(CheckLifecycleModel.parseArgs(["--root", "--json"])->Result.isError)->toBe(true)
  )
})
