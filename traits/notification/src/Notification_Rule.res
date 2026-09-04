/**
One notification rule as a value: which stream of occurrences it answers to, who
it is for, which kind it is, and what it says.

The shape a compiled table and a configured one both hold. That is why the filter
is a typed tree and not an expression string — a string needs a parser at
evaluation time, and a parser that runs on data from outside is an injection
surface. It is also why the wording is `Reventless.Template` source: readable
text rather than ReScript interpolation, rendered against the payload's schema so
a semantic formats itself and a `@sensitive` field is withheld.
*/

/** How a field is compared. */
@schema
type comparison =
  | Eq
  | Ne
  | Lt
  | Lte
  | Gt
  | Gte
  | Contains

/** What it is compared against. */
@schema
type literal =
  | Text(string)
  | Number(float)
  | Flag(bool)

/** Whether a rule answers to this occurrence. */
@schema
type rec predicate =
  | Always
  | Compare({path: string, op: comparison, value: literal})
  | All(array<predicate>)
  | Any(array<predicate>)
  | Not(predicate)

/** One wording, in one locale. Both fields are `Reventless.Template` sources. */
@schema
type content = {locale: string, subject: string, body: string}

/** The stream of occurrences a rule answers to, as the two halves of the
    `"<log>:<eventType>"` a claim is made against. */
@schema
type source = {log: string, eventType: string}

/** How a rule's occurrences reach the recipient: one message each, or gathered
    into one message per window.

    Routing is a field on the rule and not a negotiation between producers. A
    digest is scheduler-driven and therefore its own component, but *which*
    occurrences are its to gather is a table entry — so a relay serves the half it
    can deliver and leaves the rest, with nothing to arbitrate.

    `windowSeconds` is the one thing a digest cannot read off the rule. Where a
    window starts and ends is the gathering component's own, deliberately: aligning
    to a local midnight is a decision this table has no input for. */
@schema
type delivery =
  | Immediate
  | Digest({windowSeconds: int})

@schema
type t = {
  /** Stable, because it is also the namespace of every reference this rule's
      requests carry — renaming it re-keys their delivery rows. */
  id: string,
  /** Which version of this rule wrote a message, for the request to record. */
  version: string,
  source: source,
  filter: predicate,
  /** The host's kind of notification, as a key — see `Notification_Rules.category`. */
  category: string,
  delivery: delivery,
  /** Where in the payload the person to notify is named. */
  recipientPath: string,
  /** What the notification is about: the component's name as the deployment
      registers it, and where that row's own id sits in the payload. */
  subjectType: string,
  subjectPath: string,
  content: array<content>,
}

/** The stream this rule answers to, in the form a claim is made against. */
let sourceId = (rule: t) => `${rule.source.log}:${rule.source.eventType}`

/** The correlation key a request carries. One per rule per subject, so an order
    that is placed and then ships is two notifications and two delivery rows. */
let referenceFor = (~ruleId: string, ~subject: string) => `${ruleId}:${subject}`

let reference = (rule: t, ~subject: string) => referenceFor(~ruleId=rule.id, ~subject)

let byId = (rules: array<t>, id: string) => rules->Array.find(rule => rule.id == id)

/** Whether the per-event relay is the one that delivers this rule. A digest's
    occurrences are gathered by its own component, so the relay passes over them
    rather than sending one message each. */
let isImmediate = (rule: t) => rule.delivery == Immediate

/** Every rule answering to one occurrence. Two rules on one event type are two
    notifications, which is what makes adding one a table change and not a code
    change. */
let forEvent = (rules: array<t>, ~log: string, ~eventType: string) =>
  rules->Array.filter(rule => rule.source.log == log && rule.source.eventType == eventType)

/** A mismatch of kinds is `false`, `Ne` included: a filter that cannot be read
    against this payload does not fire. */
let compare = (actual: JSON.t, op: comparison, expected: literal): bool => {
  let ordered = (a, b) =>
    switch op {
    | Eq => a == b
    | Ne => a != b
    | Lt => a < b
    | Lte => a <= b
    | Gt => a > b
    | Gte => a >= b
    | Contains => false
    }
  switch (actual, expected) {
  | (String(a), Text(b)) => op == Contains ? a->String.includes(b) : ordered(a, b)
  | (Number(a), Number(b)) => ordered(a, b)
  | (Boolean(a), Flag(b)) =>
    switch op {
    | Eq => a == b
    | Ne => a != b
    | _ => false
    }
  | (Array(items), Text(b)) =>
    op == Contains &&
      items->Array.some(item =>
        switch item {
        | String(text) => text == b
        | _ => false
        }
      )
  | _ => false
  }
}

let rec matches = (predicate: predicate, ~payload: JSON.t): bool =>
  switch predicate {
  | Always => true
  | Compare({path, op, value}) =>
    switch Reventless.Template.lookup(payload, path) {
    | Some(actual) => compare(actual, op, value)
    | None => false
    }
  | All(parts) => parts->Array.every(part => matches(part, ~payload))
  | Any(parts) => parts->Array.some(part => matches(part, ~payload))
  | Not(part) => !matches(part, ~payload)
  }

let stringAt = (payload: JSON.t, path: string) =>
  switch Reventless.Template.lookup(payload, path) {
  | Some(String(text)) => Some(text)
  | _ => None
  }

/** Who to notify. `None` is a rule whose path does not name a person in this
    payload, which is a rule that cannot be acted on rather than one that sends
    to nobody. */
let recipientOf = (rule: t, ~payload: JSON.t) => stringAt(payload, rule.recipientPath)

/** What it is about. Empty is legal — a notification about nothing in particular
    is a real case, and a fabricated subject is worse than an absent one. */
let subjectOf = (rule: t, ~payload: JSON.t) =>
  stringAt(payload, rule.subjectPath)->Option.getOr("")

/** The wording to use, the asked-for locale if the rule has it and the first
    otherwise. Which locale to ask for is the caller's — nothing here knows who
    is being written to. */
let contentFor = (rule: t, ~locale: option<string>=?) =>
  switch locale {
  | Some(wanted) =>
    switch rule.content->Array.find(entry => entry.locale == wanted) {
    | Some(_) as found => found
    | None => rule.content->Array.get(0)
    }
  | None => rule.content->Array.get(0)
  }

// A template that does not parse falls back to its own source: the renderer's
// posture is that a fault is visible rather than silent, and `validate` is what
// keeps a compiled table from reaching this.
let render = (source: string, ~payload: JSON.t, ~schema: S.t<'a>) =>
  Reventless.Template.renderSource(source, ~payload, ~schema)->Result.getOr(source)

/** The rendered `(subject, body)`. */
let compose = (rule: t, ~payload: JSON.t, ~schema: S.t<'a>, ~locale: option<string>=?) =>
  switch contentFor(rule, ~locale?) {
  | None => ("", "")
  | Some({subject, body}) => (
      render(subject, ~payload, ~schema),
      render(body, ~payload, ~schema),
    )
  }

/**
The problems in a table, empty when it is sound.

What a compiled table's own test asserts, so `compose`'s fallbacks and
`recipientOf`'s `None` stay unreachable in a build rather than merely unlikely.
`sample` is one payload of the shape the table's rules read.

`~digestRouted` says whether this deployment has a component that gathers
digests. It defaults to `false` because most do not, and there a `Digest` rule is
a rule whose occurrences the per-event relay passes over and nobody else picks
up — silence, which is the failure this competency is careful about everywhere
else.
*/
let validate = (rules: array<t>, ~digestRouted: bool=false, ~sample: JSON.t): array<string> =>
  rules->Array.flatMap(rule => {
    let problems = []
    let note = message => problems->Array.push(`${rule.id}: ${message}`)
    if rule.id == "" {
      note("a rule needs an id — it is the namespace of every reference it writes")
    }
    if Array.length(rule.content) == 0 {
      note("no wording at all")
    }
    rule.content->Array.forEach(({locale, subject, body}) =>
      [("subject", subject), ("body", body)]->Array.forEach(((which, template)) =>
        switch Reventless.Template.parse(template) {
        | Ok(_) => ()
        | Error(why) => note(`${locale} ${which} does not parse — ${why}`)
        }
      )
    )
    if recipientOf(rule, ~payload=sample) == None {
      note(`recipientPath "${rule.recipientPath}" names nobody in the sample payload`)
    }
    if stringAt(sample, rule.subjectPath) == None {
      note(`subjectPath "${rule.subjectPath}" resolves to nothing in the sample payload`)
    }
    switch rule.delivery {
    | Immediate => ()
    | Digest({windowSeconds}) =>
      if !digestRouted {
        note("delivered as a digest, and nothing in this deployment gathers one")
      }
      if windowSeconds <= 0 {
        note(`a digest window of ${windowSeconds->Int.toString}s gathers nothing`)
      }
    }
    problems
  })
