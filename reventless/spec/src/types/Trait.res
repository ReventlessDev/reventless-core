// What a domain trait says about itself, so that a graft leaves a trace.
//
// A graft becomes ordinary host source — that is the design, and it is why every
// other signal a trait leaves is source-side: the package dependency, the variant
// spread, the `module X = Trait_Rules` alias, the conformance binding under
// `tests/`. None of them survives into a deployed plugin, so a running estate
// cannot answer "which of my components came from a trait" at all.
//
// This is the one fact that does survive, because it travels the way
// `capabilityNeeds` does: a value the trait exports and the host names, collected
// into `pluginStructure` while it is assembled and re-emitted whole on every
// registration.
//
// **Nothing here is typed by a human.** The trait exports its own identity, so a
// renamed or removed trait is a build error rather than a stale row; the version
// is read from the trait's own package rather than restated; and the component is
// filled in by the structure, which is the only party that knows which component
// declared it. That is the whole reason this is a value rather than an
// annotation — an attribute's fields would all be strings the compiler never
// checks, which is the failure this program exists to remove.
//
// **A declaration is a claim about origin, never about behaviour.** After a graft
// the developer owns the files and may edit them freely. So this says "grafted
// from trait X", and it does NOT say "still behaves like trait X" — the thing that
// answers the second question is the trait's conformance suite, which runs in the
// consumer's build and reports separately. A reader that paints a declared graft
// as verified is drawing a conclusion this field cannot support.

/** Whether the graft reports back into the host it is grafted onto.

    `WritesBack` publishes commands to its host — the geocoding shape, where the
    slice reports its answer back onto the aggregate. `Observes` reads host events
    and writes nothing back. `SelfContained` brings its own components and grafts
    only by reading — the notification shape, which is what broke the
    write-back assumption the first two specimens shared. */
type posture =
  | WritesBack
  | Observes
  | SelfContained

let postureToString = (p: posture): string =>
  switch p {
  | WritesBack => "WritesBack"
  | Observes => "Observes"
  | SelfContained => "SelfContained"
  }

/**
One trait's own account of itself, exported by the trait package.

`version` is read from the trait's package at load time rather than restated in
source — see `PackageVersion.fromModuleUrl`, which the certification CLI already
resolves trait versions with. A trait whose package.json cannot be found reports
`"0.0.0"`, which is visibly wrong rather than quietly stale.
*/
type t = {
  /** The package, as it is depended on: `"@reventlessdev/trait-attachments"`. */
  trait: string,
  /** Resolved from the trait's own package, never written by hand. */
  version: string,
  posture: posture,
}
