/**
What a trait's conformance suite proved, against one host, as data.

The suite has run inside a consumer's build since the emitter shipped. What was
missing is any way for something downstream to *read* the result: it was console
output, so a listing could carry a claim nobody could check and a CI gate had
nothing to gate on. This is that result, typed and versioned like every other
persisted shape here.

## What it is evidence of, and what it is not

It says: this trait, at this version, asserted these rules through this host, and
they held. It does **not** say the host is correct — the suite deliberately covers
only what the trait has an opinion about, and the host's own lifecycle refusals,
authorization and projections are asserted by the host's own tests and are none of
the trait's business.

So a listing that carries this can say "verified against its declared hosts" and
cannot say "this application works". The distinction is the whole reason the
assertion names travel with the counts: a reader can see *what* was proved rather
than trusting a number.

## Why the results come from a test report

The framework does not own the runner. A consumer runs their own suite, their own
way, and hands the report here — so this module is a pure transformation with no
opinion about Jest, CI, or where files live. `fromReport` is the whole of it.
*/

/** One assertion, and whether it held. Named, not numbered: a count that changed
    tells a reader nothing, and a name that disappeared tells them everything. */
@schema
type assertion = {name: string, passed: bool}

@schema
type t = {
  /** The trait's package name — its identity everywhere else too. */
  trait: string,
  traitVersion: string,
  /** The framework the suite ran against. A trait is certified against a
      framework version, not in the abstract: `marketplace`'s Verified tier is
      "passes its suite against the latest framework", and without this the claim
      cannot be aged out. */
  framework: string,
  /** The bound host's component name — `Spec.name` from the binding. */
  host: string,
  /** The suite's own title, as the trait composes it. Carried so a reader can
      find the run this came from without reconstructing the string. */
  suite: string,
  assertions: array<assertion>,
  passed: int,
  failed: int,
}

/**
The badge rule, stated once.

Every assertion held, and there was at least one. The second half matters more
than it looks: a binding that registers nothing produces an empty, all-passing
certificate, and "zero assertions, zero failures" is exactly the shape a broken
graft takes. A certificate that called that verified would certify silence.
*/
let verified = (certificate: t) =>
  certificate.failed == 0 && certificate.assertions->Array.length > 0

/**
Build a certificate from a suite's results.

`results` is `(assertion name, passed)` in the order the suite registered them —
whatever produced them. Counts are derived rather than passed in, so a caller
cannot hand over a total that disagrees with the list it accompanies.
*/
let fromReport = (
  ~trait: string,
  ~traitVersion: string,
  ~framework: string,
  ~host: string,
  ~suite: string,
  ~results: array<(string, bool)>,
): t => {
  let assertions = results->Array.map(((name, passed)) => {name, passed})
  {
    trait,
    traitVersion,
    framework,
    host,
    suite,
    assertions,
    passed: assertions->Array.filter(a => a.passed)->Array.length,
    failed: assertions->Array.filter(a => !a.passed)->Array.length,
  }
}

/** Deterministic rendering: 2-space indent, trailing newline. Rebuilding from an
    unchanged run must produce a byte-identical file, so a committed certificate
    does not churn and a diff means something moved. */
let render = (certificate: t): string =>
  JSON.stringify(certificate->Util_Sury.toJson(schema), ~space=2) ++ "\n"

/** A one-line summary for a build log — the counts plus the verdict, so a
    console reader and a machine reader agree without either restating the rule. */
let summarize = (certificate: t): string =>
  `${certificate.trait}@${certificate.traitVersion} → ${certificate.host}: ` ++
  `${certificate.passed->Int.toString}/${(certificate.assertions->Array.length)
    ->Int.toString} assertions, ` ++ (certificate->verified ? "verified" : "NOT verified")
