/**
The notification competency's rules, compiled once and called by every host: a
recipient is reachable at an address per channel, subscribes to a *kind* of
notification per channel, and a request to notify them resolves to an addressed
message, a suppression, or a record that nobody could be reached.

A host maps its own constructors onto `op` and `fact` and keeps the spec surface —
the variants, their annotations, its refusals. Nothing here knows what an order
is, or what a customer is. `Notification_Conformance` asserts these rules through
a host.

## The one thing this module cannot know

Whether an unheard-from recipient should be notified is **per category and per
host**: a confirmation is one the recipient asked for by ordering, and marketing
is the opposite. So the fallback *rule* lives here — an absent choice defers to
the posture — and the *table* is passed in as `~posture`. A trait that hard-coded
either answer would be wrong for half its hosts.
*/

/** How a recipient is reached. Mirrors `Reventless.Messaging.channel`, which is
    the platform capability's vocabulary; this one is the domain's, so it carries
    a host's schema and travels on the wire. `Notification_Send` maps the two. */
type channel =
  | Email
  | Sms
  | Push

let channels = [Email, Sms, Push]

/** A selectable kind of notification, as its host spells it. A key rather than a
    variant for the same reason the attachments trait's `ref` is a string: the
    host's own `category` is a real variant with a schema, and wrapping it here
    would only mean unwrapping it on every arm. What kinds exist is the host's
    vocabulary — this module never enumerates them. */
type category = string

/** Refolded per decision, never stored — the host's slice state is. */
type t = {
  /** One address per channel. An array rather than a single address because the
      channels differ in kind: an email is one address per person, a device token
      is one per *install*. A host that only ever announces an inbox holds a
      one-element list, and the shape does not have to change when it does not. */
  contacts: array<(channel, string)>,
  /** Only the cells a recipient has an opinion about; the rest is `~posture`. */
  choices: array<(category, channel, bool)>,
}

let empty = {contacts: [], choices: []}

/** What a host asks the competency to do. */
type op =
  | /** Relayed from whatever the host publishes when it learns where somebody is.
        Not a client's command: a caller who could announce another person's
        address would be redirecting their mail. */
  Announce({channel: channel, address: string})
  | Subscribe({category: category, channel: channel})
  | Unsubscribe({category: category, channel: channel})
  | /** Something worth telling them about happened. `reference` is the caller's
        own key for it, echoed back on whichever outcome follows, so the relay
        that asked can tell its work is finished. Opaque here on purpose. */
  Request({category: category, reference: string})

/** What the competency decided, for the host to name in its own events. */
type fact =
  | Announced({channel: channel, address: string})
  | Subscribed({category: category, channel: channel})
  | Unsubscribed({category: category, channel: channel})
  | /** The addressed message. `address` is the snapshot delivery uses, which is
        why it is on the fact and not looked up again later. */
  Requested({category: category, reference: string, channel: channel, address: string})
  | /** They are reachable and said no. */
  Suppressed({category: category, reference: string})
  | /** They want it and nobody can be reached — no address on file for any
        channel they left enabled. A different fact from `Suppressed` on purpose:
        one is the system working and the other is the system falling short, and
        reporting both the same way hides every delivery gap behind a legitimate
        preference. */
  Undeliverable({category: category, reference: string})

let addressFor = (t, channel) =>
  t.contacts->Array.find(((c, _)) => c == channel)->Option.map(((_, address)) => address)

/** Whether this cell is on: the recipient's own choice if they made one, else the
    host's posture for that kind. */
let enabled = (t, ~posture: (category, channel) => bool, category, channel) =>
  switch t.choices->Array.find(((cat, ch, _)) => cat == category && ch == channel) {
  | Some((_, _, isEnabled)) => isEnabled
  | None => posture(category, channel)
  }

let withChoice = (t, category, channel, isEnabled) => {
  ...t,
  choices: Array.concat(
    t.choices->Array.filter(((cat, ch, _)) => !(cat == category && ch == channel)),
    [(category, channel, isEnabled)],
  ),
}

let evolve = (t, fact) =>
  switch fact {
  | Announced({channel, address}) => {
      ...t,
      contacts: Array.concat(
        t.contacts->Array.filter(((c, _)) => c != channel),
        [(channel, address)],
      ),
    }
  | Subscribed({category, channel}) => withChoice(t, category, channel, true)
  | Unsubscribed({category, channel}) => withChoice(t, category, channel, false)
  // Neither the outcome of a request nor a delivery report changes who somebody
  // is or what they want, so the fold ignores them. What a host must NOT do is
  // read them back as consumed events to make this state bigger — the directory
  // is snapshotted, and a set of every reference ever seen would grow forever.
  | Requested(_)
  | Suppressed(_)
  | Undeliverable(_) => t
  }

/** The whole competency, in one function.

    `array<fact>` rather than `option<fact>`: a request can go out on more than
    one channel, and each is its own message. An empty array is the no-op a
    retried subscribe produces; a request never returns one, because the relay
    upstream is waiting for an outcome and a silent path is a row that retries
    until it is abandoned.

    The one refusal is a client managing preferences for somebody the directory
    has never heard of — a person is at the other end of that one and can be
    told, unlike the relayed ops, which record a fact instead. */
let decide = (t, op, ~posture: (category, channel) => bool): result<
  array<fact>,
  [#RecipientUnknown],
> =>
  switch op {
  | Announce({channel, address}) =>
    addressFor(t, channel) == Some(address) ? Ok([]) : Ok([Announced({channel, address})])

  | Subscribe({category, channel}) =>
    t.contacts->Array.length == 0
      ? Error(#RecipientUnknown)
      : enabled(t, ~posture, category, channel)
      ? Ok([])
      : Ok([Subscribed({category, channel})])

  | Unsubscribe({category, channel}) =>
    t.contacts->Array.length == 0
      ? Error(#RecipientUnknown)
      : enabled(t, ~posture, category, channel)
      ? Ok([Unsubscribed({category, channel})])
      : Ok([])

  | Request({category, reference}) =>
    let wanted = channels->Array.filter(channel => enabled(t, ~posture, category, channel))
    let addressed =
      wanted->Array.filterMap(channel =>
        addressFor(t, channel)->Option.map(address => Requested({
          category,
          reference,
          channel,
          address,
        }))
      )
    switch addressed {
    | [] =>
      // Wanted-but-unreachable and not-wanted are the two ways to send nothing,
      // and telling them apart is the whole reason `Undeliverable` exists.
      wanted->Array.length == 0
        ? Ok([Suppressed({category, reference})])
        : Ok([Undeliverable({category, reference})])
    | facts => Ok(facts)
    }
  }
