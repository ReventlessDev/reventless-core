/**
The graft's spec surface, written rather than transcribed.

`Notification_Rules` is the competency, compiled once. What a host still needs is
the *declarations* the rules act on — its own commands, events and errors, in its
own vocabulary, in files it owns. Those cannot come from a functor: a host binds
the source module, so the constructor names are the host's, not the trait's.

This is the trait that packages most, because its graft is a set of new
components rather than arms on something the host already had. Nine files are
written whole; the two **relays** are printed, because what a host's events mean
is the one thing a trait cannot be told in names.

**What it does not do.** It never writes the host's wording. What a confirmation
says is the host's sentence, and a config field for it would be a template
language nobody asked for. It is left as a `TODO(graft)` marker in a string
literal, which compiles, runs, and is obvious in a diff.
*/

/**
The names a graft needs, and nothing else.

One field here is not a name and is worth the exception: `transactional`. The
trait owns the *rule* that an absent choice falls back to a posture, and the
posture itself is per category and per host. A set of category names is about as
small as data gets, and without it the emitted graft cannot satisfy the trait's
own suite — which asserts that a matrix has something to choose.
*/
@schema
type config = {
  /** The chapter directory the components land in: `"Notification"`. */
  chapter: string,
  /** What this host calls the person being notified, capitalised and singular:
      `"Recipient"`, `"Subscriber"`, `"Customer"`. Runs through every name the
      graft declares. */
  noun: string,
  /** The kinds this host offers, in the order a settings screen shows them:
      `["OrderConfirmation", "ShippingUpdate", "Marketing"]`. */
  categories: array<string>,
  /** Which of them an unheard-from recipient still gets. The rest are opt-in. */
  transactional: array<string>,
  /** The aggregate whose events announce where somebody is reachable:
      `"Customer"`. Its `Spec.name`, as `sourceNames` spells it. */
  contactSource: string,
  /** Its events that carry a contact: `["Registered", "EmailUpdated"]`. */
  contactEvents: array<string>,
  /** The field they carry it in: `"email"`. */
  contactField: string,
  /** The host event a notification is owed for: `"OrderPlaced"`. */
  occurrence: string,
  /** Its own key: `"orderId"`. */
  occurrenceId: string,
  /** The field naming who to tell: `"customerId"`. */
  occurrenceRecipient: string,
  /** Which kind that occurrence is. Must be one of `categories`. */
  occurrenceCategory: string,
  /** Spliced verbatim between the parentheses of `@authorize(…)` on the two
      client-facing commands. Omitted ⇒ no annotation, and the host's default
      applies. */
  authorize?: string,
  /** Two distinct addresses for the conformance fixtures. Defaulted when absent
      — they are test data, not a decision. */
  addressA?: string,
  addressB?: string,
}

/** A file the graft owns outright, written to disk. */
type file = {path: string, contents: string}

/** Arms for a file the host already owns, or a file only the host can write.
    Printed for a human to place, never written. */
type patch = {into: string, at: string, contents: string}

type output = {files: array<file>, patches: array<patch>}

// ── The vocabulary, derived once ─────────────────────────────────────────────

type names = {
  slice: string,
  send: string,
  relay: string,
  intake: string,
  deliveries: string,
  subscriptions: string,
  announceCmd: string,
  subscribeCmd: string,
  unsubscribeCmd: string,
  requestCmd: string,
  recordCmd: string,
  recordFailureCmd: string,
  announced: string,
  subscribed: string,
  unsubscribed: string,
  requested: string,
  suppressed: string,
  undeliverable: string,
  delivered: string,
  failed: string,
  unknownError: string,
  recipientId: string,
}

let namesOf = (c: config): names => {
  let n = c.noun
  {
    slice: n ++ "Preferences",
    send: "Send" ++ n ++ "Notification",
    relay: "Announce" ++ n ++ "Contact",
    intake: n ++ "NotificationIntake",
    deliveries: n ++ "Deliveries",
    subscriptions: n ++ "Subscriptions",
    announceCmd: "Announce" ++ n,
    subscribeCmd: "Subscribe",
    unsubscribeCmd: "Unsubscribe",
    requestCmd: "RequestNotification",
    recordCmd: "RecordDelivery",
    recordFailureCmd: "RecordDeliveryFailure",
    announced: n ++ "Announced",
    subscribed: "NotificationSubscribed",
    unsubscribed: "NotificationUnsubscribed",
    requested: "NotificationRequested",
    suppressed: "NotificationSuppressed",
    undeliverable: "NotificationUndeliverable",
    delivered: "NotificationDelivered",
    failed: "NotificationFailed",
    unknownError: n ++ "Unknown",
    recipientId: (n->String.slice(~start=0, ~end=1))->String.toLowerCase ++
      n->String.slice(~start=1, ~end=n->String.length) ++ "Id",
  }
}

let lines = (ls: array<string>) => ls->Array.join("\n")

let addressA = (c: config) => c.addressA->Option.getOr("buyer@example.com")
let addressB = (c: config) => c.addressB->Option.getOr("new@example.com")

/** What the occurrence is about, named from the id it is keyed by: `"orderId"` ⇒
    `"Order"`. Derived rather than configured because `*Id` naming already says
    which entity an id belongs to everywhere else, and a config field would be one
    more thing to get out of step with `occurrenceId`. Emitted as a literal in the
    graft, so a host whose component is registered under another name edits one
    line rather than discovering the convention. */
let subjectTypeOf = (c: config) => {
  let stem = c.occurrenceId->String.endsWith("Id")
    ? c.occurrenceId->String.slice(~start=0, ~end=c.occurrenceId->String.length - 2)
    : c.occurrenceId
  switch stem {
  | "" => "Subject"
  | s => (s->String.slice(~start=0, ~end=1))->String.toUpperCase ++ s->String.sliceToEnd(~start=1)
  }
}

// `@authorize` is the host's policy, so an absent one emits nothing at all
// rather than a permissive default.
let authorizeOn = (c: config) =>
  switch c.authorize {
  | Some(a) => `  | @authorize(${a})\n  `
  | None => "  | "
  }

let categoryArms = (c: config) => c.categories->Array.map(cat => `  | ${cat}`)

// ── The slice spec ───────────────────────────────────────────────────────────

let sliceSpec = (c: config): string => {
  let n = namesOf(c)
  let id = n.recipientId
  let auth = authorizeOn(c)
  lines(
    Array.flatMap(
      [
        [
          `// ${n.slice} StateChangeSlice: the notification competency's one decision`,
          `// point — where a ${c.noun->String.toLowerCase} is reachable, which kinds they want on which`,
          `// channel, and whether a request to notify them becomes a message.`,
          `//`,
          `// A graft of the Notification trait; the rules are the trait's and are asserted`,
          `// by its conformance suite, bound in the tests.`,
          `//`,
          `// Emitted by the trait. Everything below is this host's own vocabulary, so it is`,
          `// ordinary source from here on — edit it freely.`,
          ``,
          `@@reventless.spec`,
          ``,
          `// The kinds a ${c.noun->String.toLowerCase} subscribes to. Not raw event names: a settings`,
          `// screen listing event types is a log dump, and these are choices a person can`,
          `// hold an opinion about.`,
          `@schema`,
          `type category =`,
        ],
        categoryArms(c),
        [
          ``,
          `// Mirrors \`Reventless.Messaging.channel\`. Declared here as well because a`,
          `// domain type travels on the wire and the capability's does not.`,
          `@schema`,
          `type channel =`,
          `  | Email`,
          `  | Sms`,
          `  | Push`,
          ``,
          `// Its own past facts, and nothing else — which is what lets one component hold`,
          `// the directory and make the dispatch decision.`,
          `@schema`,
          `type consumedEvent =`,
          `  | ${n.announced}({${id}: string, ${c.contactField}: string})`,
          `  | ${n.subscribed}({${id}: string, category: category, channel: channel})`,
          `  | ${n.unsubscribed}({${id}: string, category: category, channel: channel})`,
          ``,
          `@schema`,
          `type command =`,
          `  // Relayed from this host's own announcements, never called by a client — a`,
          `  // caller who could register somebody else's address would redirect their mail.`,
          `  | @noApi ${n.announceCmd}({${id}: string, ${c.contactField}: string})`,
          `  // The client door. \`@owner\` is what stops a caller managing another person's`,
          `  // matrix: the resolver overwrites the field with the authenticated caller.`,
          `${auth}${n.subscribeCmd}({@owner ${id}: string, category: category, channel: channel})`,
          `${auth}${n.unsubscribeCmd}({@owner ${id}: string, category: category, channel: channel})`,
          `  // Also relayed. \`reference\` is the requester's own key, echoed back on`,
          `  // whichever outcome follows, so the relay can tell its work is finished.`,
          `  // \`subjectType\`/\`subjectRef\` say what the notification is ABOUT, which the`,
          `  // reference deliberately does not: its format is the requester's own`,
          `  // business, so a row keyed by it alone cannot be read back. Empty is legal.`,
          `  // Named \`*Ref\` and not \`*Id\` on purpose: two inferences read id fields by`,
          `  // NAME — the DCB partition and the queryable's key field — and a second`,
          `  // \`*Id\` on the row makes both ambiguous, which costs the view its filter`,
          `  // and its orderBy with no error anywhere.`,
          `  | @noApi`,
          `  ${n.requestCmd}({`,
          `      ${id}: string,`,
          `      category: category,`,
          `      reference: string,`,
          `      subjectType: string,`,
          `      subjectRef: string,`,
          `      subject: string,`,
          `      body: string,`,
          `    })`,
          `  // Reported by the send slice once the provider has settled.`,
          `  | @noApi ${n.recordCmd}({${id}: string, reference: string, providerRef: string})`,
          `  | @noApi ${n.recordFailureCmd}({${id}: string, reference: string, reason: string})`,
          ``,
          `@schema`,
          `type error =`,
          `  // A person is at the other end of the two client commands, so this is a`,
          `  // refusal rather than a recorded fact: they can be told.`,
          `  | ${n.unknownError}`,
          ``,
          `@schema`,
          `type event =`,
          `  | ${n.announced}({${id}: string, ${c.contactField}: string})`,
          `  | ${n.subscribed}({${id}: string, category: category, channel: channel})`,
          `  | ${n.unsubscribed}({${id}: string, category: category, channel: channel})`,
          `  // The addressed message. \`address\` is the snapshot delivery uses, which is`,
          `  // why it is on the fact rather than looked up again later — and why it stays`,
          `  // here and off the delivery view: the record of where a message actually went`,
          `  // belongs in the log an investigation reads, not in a general read model.`,
          `  | ${n.requested}({`,
          `      ${id}: string,`,
          `      category: category,`,
          `      reference: string,`,
          `      channel: channel,`,
          `      address: string,`,
          `      subjectType: string,`,
          `      subjectRef: string,`,
          `      subject: string,`,
          `      body: string,`,
          `    })`,
          `  // Two different ways to send nothing. A ${c.noun->String.toLowerCase} who declined is the`,
          `  // system working; one with no address for a channel they enabled is the system`,
          `  // falling short, and one fact for both hides every gap behind a preference.`,
          `  | ${n.suppressed}({`,
          `      ${id}: string,`,
          `      category: category,`,
          `      reference: string,`,
          `      subjectType: string,`,
          `      subjectRef: string,`,
          `    })`,
          `  | ${n.undeliverable}({`,
          `      ${id}: string,`,
          `      category: category,`,
          `      reference: string,`,
          `      subjectType: string,`,
          `      subjectRef: string,`,
          `    })`,
          `  | ${n.delivered}({${id}: string, reference: string, providerRef: string})`,
          `  | ${n.failed}({${id}: string, reference: string, reason: string})`,
          ``,
        ],
      ],
      x => x,
    ),
  )
}

// ── The slice body ───────────────────────────────────────────────────────────

let postureArms = (c: config) => {
  let transactional = c.transactional->Array.map(cat => `  | ("${cat}", Email) => true`)
  Array.concat(transactional, [`  | _ => false`])
}

let sliceBehavior = (c: config): string => {
  let n = namesOf(c)
  let id = n.recipientId
  let first = c.categories->Array.get(0)->Option.getOr("Transactional")
  lines(
    Array.flatMap(
      [
        [
          `@@reventless.behavior`,
          ``,
          `// The directory, the matrix and the dispatch decision are the trait's; this file`,
          `// is the mapping onto them, plus the one thing the trait has no opinion about —`,
          `// whether an unheard-from ${c.noun->String.toLowerCase} gets a given kind.`,
          `module Rules = TraitNotification.Notification_Rules`,
          ``,
          `// TODO(graft): the posture, per category. A kind an unheard-from ${c.noun->String.toLowerCase}`,
          `// should still receive answers \`true\`; the rest are opt-in. Per category and`,
          `// never globally — one default forces both kinds onto whichever answer is worse`,
          `// for the other. Email only: a channel nobody chose is a channel no address was`,
          `// given for.`,
          `let posture = (category: string, channel: Rules.channel) =>`,
          `  switch (category, channel) {`,
        ],
        postureArms(c),
        [
          `  }`,
          ``,
          `let categoryKey = (category: category) =>`,
          `  switch category {`,
        ],
        c.categories->Array.map(cat => `  | ${cat} => "${cat}"`),
        [
          `  }`,
          ``,
          `let categoryOf = (key: string) =>`,
          `  switch key {`,
        ],
        c.categories
        ->Array.filter(cat => cat != first)
        ->Array.map(cat => `  | "${cat}" => ${cat}`),
        [
          `  // A key this build does not know can only come from an event another version`,
          `  // of this slice wrote. The first kind declared is the fallback.`,
          `  | _ => ${first}`,
          `  }`,
          ``,
          `let channelKey = (channel: channel): Rules.channel =>`,
          `  switch channel {`,
          `  | Email => Email`,
          `  | Sms => Sms`,
          `  | Push => Push`,
          `  }`,
          ``,
          `let channelOf = (channel: Rules.channel): channel =>`,
          `  switch channel {`,
          `  | Email => Email`,
          `  | Sms => Sms`,
          `  | Push => Push`,
          `  }`,
          ``,
          `// The trait's own value, refolded per decision. The host stores nothing beside`,
          `// it: what this plugin knows about a ${c.noun->String.toLowerCase}'s preferences IS the directory.`,
          `type state = Rules.t`,
          ``,
          `let initialState = Rules.empty`,
          ``,
          `let evolve = (state, event: consumedEvent) =>`,
          `  switch event {`,
          `  | ${n.announced}({${c.contactField}}) =>`,
          `    state->Rules.evolve(Announced({channel: Email, address: ${c.contactField}}))`,
          `  | ${n.subscribed}({category, channel}) =>`,
          `    state->Rules.evolve(`,
          `      Subscribed({category: categoryKey(category), channel: channelKey(channel)}),`,
          `    )`,
          `  | ${n.unsubscribed}({category, channel}) =>`,
          `    state->Rules.evolve(`,
          `      Unsubscribed({category: categoryKey(category), channel: channelKey(channel)}),`,
          `    )`,
          `  }`,
          ``,
          `// The trait decides; this names what it decided in the host's vocabulary.`,
          `let named = (${id}, fact: Rules.fact) =>`,
          `  switch fact {`,
          `  | Announced({address}) => ${n.announced}({${id}: ${id}, ${c.contactField}: address})`,
          `  | Subscribed({category, channel}) =>`,
          `    ${n.subscribed}({`,
          `      ${id}: ${id},`,
          `      category: categoryOf(category),`,
          `      channel: channelOf(channel),`,
          `    })`,
          `  | Unsubscribed({category, channel}) =>`,
          `    ${n.unsubscribed}({`,
          `      ${id}: ${id},`,
          `      category: categoryOf(category),`,
          `      channel: channelOf(channel),`,
          `    })`,
          `  | Requested({category, reference, channel, address}) =>`,
          `    ${n.requested}({`,
          `      ${id}: ${id},`,
          `      category: categoryOf(category),`,
          `      reference,`,
          `      channel: channelOf(channel),`,
          `      address,`,
          `      // Carried on the command and put back below: the trait holds no sentence,`,
          `      // and refuses to know what an occurrence is.`,
          `      subjectType: "",`,
          `      subjectRef: "",`,
          `      subject: "",`,
          `      body: "",`,
          `    })`,
          `  | Suppressed({category, reference}) =>`,
          `    ${n.suppressed}({`,
          `      ${id}: ${id},`,
          `      category: categoryOf(category),`,
          `      reference,`,
          `      subjectType: "",`,
          `      subjectRef: "",`,
          `    })`,
          `  | Undeliverable({category, reference}) =>`,
          `    ${n.undeliverable}({`,
          `      ${id}: ${id},`,
          `      category: categoryOf(category),`,
          `      reference,`,
          `      subjectType: "",`,
          `      subjectRef: "",`,
          `    })`,
          `  }`,
          ``,
          `let through = (state, ${id}, op) =>`,
          `  switch state->Rules.decide(op, ~posture) {`,
          `  | Ok(facts) => Ok(facts->Array.map(named(${id}, _)))`,
          `  | Error(#RecipientUnknown) => Error(${n.unknownError})`,
          `  }`,
          ``,
          `let decide = (state, command) =>`,
          `  switch command {`,
          `  | ${n.announceCmd}({${id}, ${c.contactField}}) =>`,
          `    through(state, ${id}, Announce({channel: Email, address: ${c.contactField}}))`,
          `  | ${n.subscribeCmd}({${id}, category, channel}) =>`,
          `    through(`,
          `      state,`,
          `      ${id},`,
          `      Subscribe({category: categoryKey(category), channel: channelKey(channel)}),`,
          `    )`,
          `  | ${n.unsubscribeCmd}({${id}, category, channel}) =>`,
          `    through(`,
          `      state,`,
          `      ${id},`,
          `      Unsubscribe({category: categoryKey(category), channel: channelKey(channel)}),`,
          `    )`,
          ``,
          `  // The one arm that is not a rename: the words and the subject belong to the`,
          `  // requester and the trait's facts carry neither, so both are put back on the`,
          `  // way out. All three outcomes get the subject — what a suppressed or`,
          `  // undeliverable notification was about is what makes those rows worth reading.`,
          `  | ${n.requestCmd}({${id}, category, reference, subjectType, subjectRef, subject, body}) =>`,
          `    through(state, ${id}, Request({category: categoryKey(category), reference}))`,
          `    ->Result.map(events =>`,
          `      events->Array.map(event =>`,
          `        switch event {`,
          `        | ${n.requested}(fields) =>`,
          `          ${n.requested}({...fields, subjectType, subjectRef, subject, body})`,
          `        | ${n.suppressed}(fields) => ${n.suppressed}({...fields, subjectType, subjectRef})`,
          `        | ${n.undeliverable}(fields) =>`,
          `          ${n.undeliverable}({...fields, subjectType, subjectRef})`,
          `        | other => other`,
          `        }`,
          `      )`,
          `    )`,
          ``,
          `  // No rule to state — the outcome is whatever the provider said.`,
          `  | ${n.recordCmd}({${id}, reference, providerRef}) =>`,
          `    Ok([${n.delivered}({${id}: ${id}, reference, providerRef})])`,
          `  | ${n.recordFailureCmd}({${id}, reference, reason}) =>`,
          `    Ok([${n.failed}({${id}: ${id}, reference, reason})])`,
          `  }`,
          ``,
        ],
      ],
      x => x,
    ),
  )
}

// ── The send slice ───────────────────────────────────────────────────────────

let sendSpec = (c: config): string => {
  let n = namesOf(c)
  let id = n.recipientId
  lines([
    `// ${n.send} OutboundTranslationSlice: delivers a message that has already`,
    `// been addressed and already been decided on. Everything it needs is on the`,
    `// request — the channel, the address as of the moment the message was composed,`,
    `// and the words — so it reads no state and knows nothing about who anybody is.`,
    `//`,
    `// Emitted by the trait; ordinary source from here on.`,
    ``,
    `@@reventless.spec`,
    ``,
    `// Only the addressed request. The other two outcomes are decisions not to send.`,
    `@schema`,
    `type consumedEvent =`,
    `  | ${n.requested}({`,
    `      ${id}: string,`,
    `      reference: string,`,
    `      channel: ${n.slice}.channel,`,
    `      address: string,`,
    `      subject: string,`,
    `      body: string,`,
    `    })`,
    ``,
    `@schema`,
    `type outboundItem = {`,
    `  ${id}: string,`,
    `  reference: string,`,
    `  channel: ${n.slice}.channel,`,
    `  address: string,`,
    `  subject: string,`,
    `  body: string,`,
    `}`,
    ``,
    `@schema`,
    `type inboundCommand =`,
    `  | ${n.recordCmd}({${id}: string, reference: string, providerRef: string})`,
    `  | ${n.recordFailureCmd}({${id}: string, reference: string, reason: string})`,
    ``,
    `// Retries are for a provider that is down, not one that has refused. The port's`,
    `// own \`retriable\` rule decides which is which, in the translation next door.`,
    `let maxRetries = 3`,
    `let heartbeatInterval = 60`,
    `let targetName = Some("${n.slice}")`,
    ``,
    `// This plugin's own DCB event log.`,
    `let sourceNames: array<string> = []`,
    ``,
    `// Named for the capability rather than a provider: which one is behind it is`,
    `// the deployment's decision, and this slice never learns the answer.`,
    `let externalSystem = Some("Messaging")`,
    ``,
    `// Declared, so a deployment that provisions no sender fails rather than queueing`,
    `// every message until it is abandoned.`,
    `let capabilityNeeds = TraitNotification.Notification.capabilityNeeds`,
    `// The graft's own record of itself — see the trait's \`declaration\`.`,
    `let traits = [TraitNotification.Notification.declaration]`,
    ``,
  ])
}

let sendTranslation = (c: config): string => {
  let n = namesOf(c)
  let id = n.recipientId
  lines([
    `@@reventless.translation`,
    ``,
    `// Keyed by the request's own reference: one message per decision, and a`,
    `// redelivery lands on the row that is already there.`,
    `let collect = (event, ~sourceId as _) =>`,
    `  switch event {`,
    `  | ${n.requested}({${id}, reference, channel, address, subject, body}) => [`,
    `      (reference, {${id}: ${id}, reference, channel, address, subject, body}),`,
    `    ]`,
    `  }`,
    ``,
    `// The one place the domain's channel vocabulary meets the platform's. Two`,
    `// declarations rather than one shared type because a schema type travels on the`,
    `// wire and the capability's does not — and this switch is where a channel the`,
    `// platform grows shows up as a compile error rather than as a silence.`,
    `let recipientFor = (item: outboundItem) =>`,
    `  switch item.channel {`,
    `  | Email =>`,
    `    item.address`,
    `    ->Reventless.Email.fromString`,
    `    ->Result.map(email => Reventless.Messaging.ToEmail(email))`,
    `  | Sms =>`,
    `    item.address`,
    `    ->Reventless.Phone.fromString`,
    `    ->Result.map(phone => Reventless.Messaging.ToSms(phone))`,
    `  | Push => Ok(Reventless.Messaging.ToPush({deviceToken: item.address}))`,
    `  }`,
    ``,
    `let translate = async (_id, item: outboundItem, ~capabilities: Reventless.Capabilities.t) =>`,
    `  switch recipientFor(item) {`,
    `  // An address the directory holds that its own channel's grammar refuses. Not`,
    `  // retryable and not the provider's fault — the row that holds it needs fixing.`,
    `  | Error(why) =>`,
    `    Ok(`,
    `      Some((`,
    `        item.${id},`,
    `        ${n.recordFailureCmd}({`,
    `          ${id}: item.${id},`,
    `          reference: item.reference,`,
    `          reason: why,`,
    `        }),`,
    `      )),`,
    `    )`,
    `  | Ok(recipient) =>`,
    `    switch await capabilities.messaging.send(`,
    `      ~recipient,`,
    `      ~message={subject: item.subject, body: item.body},`,
    `    ) {`,
    `    | Ok({ref}) =>`,
    `      Ok(`,
    `        Some((`,
    `          item.${id},`,
    `          ${n.recordCmd}({`,
    `            ${id}: item.${id},`,
    `            reference: item.reference,`,
    `            providerRef: ref,`,
    `          }),`,
    `        )),`,
    `      )`,
    `    // The retry split, taken from the port rather than re-decided here.`,
    `    | Error(failure) =>`,
    `      Reventless.Messaging.retriable(failure)`,
    `        ? Error(Reventless.Messaging.failureReason(failure))`,
    `        : Ok(`,
    `            Some((`,
    `              item.${id},`,
    `              ${n.recordFailureCmd}({`,
    `                ${id}: item.${id},`,
    `                reference: item.reference,`,
    `                reason: Reventless.Messaging.failureReason(failure),`,
    `              }),`,
    `            )),`,
    `          )`,
    `    }`,
    `  }`,
    ``,
    `// The budget is spent and the provider never answered. Recording it beats leaving`,
    `// the row pending forever — and it is the second reason the capability must be`,
    `// declared, since an unprovisioned sender reaches here every single time.`,
    `let onExhausted = (_id, item: outboundItem, ~lastError) =>`,
    `  Some((`,
    `    item.${id},`,
    `    ${n.recordFailureCmd}({`,
    `      ${id}: item.${id},`,
    `      reference: item.reference,`,
    `      reason: lastError->Option.getOr("the messaging provider never answered"),`,
    `    }),`,
    `  ))`,
    ``,
  ])
}

// ── The conformance binding ──────────────────────────────────────────────────

let conformanceBinding = (c: config): string => {
  let n = namesOf(c)
  let id = n.recipientId
  let first = c.categories->Array.get(0)->Option.getOr("Transactional")
  let optional =
    c.categories
    ->Array.find(cat => !(c.transactional->Array.includes(cat)))
    ->Option.getOr("Marketing")
  let transactional = c.transactional->Array.get(0)->Option.getOr(first)
  lines([
    `// The notification trait's own suite, run against this host's graft.`,
    `//`,
    `// Everything here is the trait's: the directory, the fallback to this host's`,
    `// posture, and the three different facts that mean "nothing was sent". None of it`,
    `// belongs in the slice's own GWT as well — a rule the suite covers must not live`,
    `// in two places, or the two drift and neither is the source of truth.`,
    ``,
    `module Binding = {`,
    `  type category = ${n.slice}.category`,
    `  let transactional: category = ${transactional}`,
    `  let optional: category = ${optional}`,
    ``,
    `  module Spec = ${n.slice}`,
    `  module Behavior = ${n.slice}_Behavior`,
    ``,
    `  // A DCB slice's entity comes into existence with its first fact, so there is`,
    `  // no creation event to seed: an unannounced ${c.noun->String.toLowerCase} is one with no history.`,
    `  let created: array<Spec.consumedEvent> = []`,
    ``,
    `  let ${id} = "${c.noun->String.toLowerCase}-1"`,
    ``,
    `  // Annotated: this slice reads back exactly what it writes, so each of these`,
    `  // names a constructor of both unions and the later declaration would win.`,
    `  let announcedC = (${c.contactField}): Spec.consumedEvent =>`,
    `    ${n.announced}({${id}: ${id}, ${c.contactField}: ${c.contactField}})`,
    `  let subscribedC = (category, channel): Spec.consumedEvent =>`,
    `    ${n.subscribed}({${id}: ${id}, category, channel: Behavior.channelOf(channel)})`,
    `  let unsubscribedC = (category, channel): Spec.consumedEvent =>`,
    `    ${n.unsubscribed}({${id}: ${id}, category, channel: Behavior.channelOf(channel)})`,
    ``,
    `  let announce = ${c.contactField} =>`,
    `    Spec.${n.announceCmd}({${id}: ${id}, ${c.contactField}: ${c.contactField}})`,
    `  let subscribe = (category, channel) =>`,
    `    Spec.${n.subscribeCmd}({${id}: ${id}, category, channel: Behavior.channelOf(channel)})`,
    `  let unsubscribe = (category, channel) =>`,
    `    Spec.${n.unsubscribeCmd}({${id}: ${id}, category, channel: Behavior.channelOf(channel)})`,
    `  // The wording and the subject are this host's and the trait carries neither, so`,
    `  // the suite supplies whatever it likes and asserts nothing about them.`,
    `  let request = (category, reference) =>`,
    `    Spec.${n.requestCmd}({`,
    `      ${id}: ${id},`,
    `      category,`,
    `      reference,`,
    `      subjectType: "${subjectTypeOf(c)}",`,
    `      subjectRef: "subject-1",`,
    `      subject: "subject",`,
    `      body: "body",`,
    `    })`,
    ``,
    `  let announced = ${c.contactField} =>`,
    `    Spec.${n.announced}({${id}: ${id}, ${c.contactField}: ${c.contactField}})`,
    `  let subscribed = (category, channel) =>`,
    `    Spec.${n.subscribed}({${id}: ${id}, category, channel: Behavior.channelOf(channel)})`,
    `  let unsubscribed = (category, channel) =>`,
    `    Spec.${n.unsubscribed}({${id}: ${id}, category, channel: Behavior.channelOf(channel)})`,
    `  let requested = (category, reference, channel, address) =>`,
    `    Spec.${n.requested}({`,
    `      ${id}: ${id},`,
    `      category,`,
    `      reference,`,
    `      channel: Behavior.channelOf(channel),`,
    `      address,`,
    `      subjectType: "${subjectTypeOf(c)}",`,
    `      subjectRef: "subject-1",`,
    `      subject: "subject",`,
    `      body: "body",`,
    `    })`,
    `  // The subject rides through the two decisions not to send as well: what a`,
    `  // suppressed or undeliverable notification was about is the whole reason those`,
    `  // rows are worth reading.`,
    `  let suppressed = (category, reference) =>`,
    `    Spec.${n.suppressed}({`,
    `      ${id}: ${id},`,
    `      category,`,
    `      reference,`,
    `      subjectType: "${subjectTypeOf(c)}",`,
    `      subjectRef: "subject-1",`,
    `    })`,
    `  let undeliverable = (category, reference) =>`,
    `    Spec.${n.undeliverable}({`,
    `      ${id}: ${id},`,
    `      category,`,
    `      reference,`,
    `      subjectType: "${subjectTypeOf(c)}",`,
    `      subjectRef: "subject-1",`,
    `    })`,
    ``,
    `  let recipientUnknown = Spec.${n.unknownError}`,
    ``,
    `  let addressA = "${addressA(c)}"`,
    `  let addressB = "${addressB(c)}"`,
    `  let announcedChannel: TraitNotification.Notification_Rules.channel = Email`,
    `  // This host announces an inbox and nothing else, so SMS is a channel somebody`,
    `  // can want and not be reached on — the state the undeliverable arm exists for.`,
    `  let unreachableChannel = Some(TraitNotification.Notification_Rules.Sms)`,
    `}`,
    ``,
    `module Conformance = TraitNotification.Notification_Conformance.Make(Binding)`,
    ``,
    `Conformance.register()`,
    ``,
  ])
}

// ── The relays, printed ──────────────────────────────────────────────────────
//
// The only part of this graft a trait cannot be handed in names. What a host's
// events *mean* — that `Registered` announces where somebody is, that a placed
// order earns a confirmation and here is what it says — is the host's knowledge,
// and a config field for a sentence would be a template language nobody asked
// for. Printed with the shape filled in and the meaning marked.

let contactRelayPatch = (c: config): patch => {
  let n = namesOf(c)
  let id = n.recipientId
  {
    into: `${c.chapter}/OutboundTranslationSlice/${n.relay}.res (new, plus its _Translation)`,
    at: `a new file — the trait cannot write what this host's events mean`,
    contents: lines(
      Array.flatMap(
        [
          [
            `// Relays this host's contact announcements into the directory, so somebody is`,
            `// reachable because they registered rather than because they visited a screen.`,
            `//`,
            `// An OutboundTranslationSlice rather than an automation, and not by preference:`,
            `// an automation's collect is handed the event and the ambient context and`,
            `// nothing else, and an aggregate's event does not repeat the id that addressed`,
            `// it. This is the one component the framework passes a ~sourceId to.`,
            ``,
            `@@reventless.spec`,
            ``,
            `// TODO(graft): every event of ${c.contactSource} that carries a contact. All of them —`,
            `// an address that changed and was not relayed leaves the directory writing to`,
            `// the old one.`,
            `@schema`,
            `type consumedEvent =`,
          ],
          c.contactEvents->Array.map(e => `  | ${e}({${c.contactField}: string})`),
          [
            ``,
            `@schema`,
            `type outboundItem = {${id}: string, ${c.contactField}: string}`,
            ``,
            `@schema`,
            `type inboundCommand =`,
            `  | ${n.announceCmd}({${id}: string, ${c.contactField}: string})`,
            ``,
            `let maxRetries = 3`,
            `let heartbeatInterval = 60`,
            `let targetName = Some("${n.slice}")`,
            `let sourceNames = ["${c.contactSource}"]`,
            `// No external box: this slice reaches nothing outside the plugin.`,
            `let externalSystem = None`,
            `let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []`,
            `let traits = [TraitNotification.Notification.declaration]`,
            ``,
            `// ── ${n.relay}_Translation.res ──`,
            ``,
            `@@reventless.translation`,
            ``,
            `// Keyed by entity AND address: keying by entity alone would make a later`,
            `// change look like work already done.`,
            `let collect = (event, ~sourceId) =>`,
            `  switch event {`,
          ],
          c.contactEvents->Array.map(e =>
            `  | ${e}({${c.contactField}}) => [(\`\${sourceId}:\${${c.contactField}}\`, {${id}: sourceId, ${c.contactField}: ${c.contactField}})]`
          ),
          [
            `  }`,
            ``,
            `// No service to call. The item completes on this returning Ok, which is what`,
            `// lets the directory's own announce command be idempotent: a re-announced`,
            `// address publishes no event, and no row waits for one.`,
            `let translate = async (_id, item: outboundItem, ~capabilities as _) =>`,
            `  Ok(`,
            `    Some((`,
            `      item.${id},`,
            `      ${n.announceCmd}({${id}: item.${id}, ${c.contactField}: item.${c.contactField}}),`,
            `    )),`,
            `  )`,
            ``,
            `let onExhausted = (_id, _item, ~lastError as _) => None`,
          ],
        ],
        x => x,
      ),
    ),
  }
}

let intakeRelayPatch = (c: config): patch => {
  let n = namesOf(c)
  let id = n.recipientId
  {
    into: `${c.chapter}/AutomationSlice/${n.intake}.res (new, plus its _Automation)`,
    at: `a new file — the wording is this host's sentence, not the trait's`,
    contents: lines([
      `// Turns one of this host's occurrences into a request to notify somebody.`,
      ``,
      `@@reventless.spec`,
      ``,
      `@schema`,
      `type todoItem = {${id}: string, ${c.occurrenceId}: string}`,
      ``,
      `@schema`,
      `type command =`,
      `  ${n.requestCmd}({`,
      `    ${id}: string,`,
      `    category: ${n.slice}.category,`,
      `    reference: string,`,
      `    subjectType: string,`,
      `    subjectRef: string,`,
      `    subject: string,`,
      `    body: string,`,
      `  })`,
      ``,
      `let maxRetries = 3`,
      `let heartbeatInterval = 60`,
      `let targetName = "${n.slice}"`,
      ``,
      `// ── ${n.intake}_Automation.res ──`,
      ``,
      `@@reventless.automation`,
      ``,
      `// A TODO id is also the reference the request carries, so the outcome event`,
      `// echoes back exactly what resolves the row.`,
      `let key = ${c.occurrenceId} => \`notify:\${${c.occurrenceId}}\``,
      ``,
      `module DcbSource = {`,
      `  // MUST equal "<pluginName>DcbEventLog".`,
      `  let name = "TODO(graft)DcbEventLog"`,
      ``,
      `  @schema`,
      `  type event =`,
      `    | ${c.occurrence}({${c.occurrenceId}: string, ${c.occurrenceRecipient}: string})`,
      `    // All three resolve the row: a suppressed notification is finished work,`,
      `    // not failed work.`,
      `    | ${n.requested}({reference: string})`,
      `    | ${n.suppressed}({reference: string})`,
      `    | ${n.undeliverable}({reference: string})`,
      `}`,
      ``,
      `module FromDcb = Mapping.Make(`,
      `  DcbSource,`,
      `  ${n.intake},`,
      `  {`,
      `    open DcbSource`,
      ``,
      `    let collect = (event, _ctx) =>`,
      `      switch event {`,
      `      | ${c.occurrence}({${c.occurrenceId}, ${c.occurrenceRecipient}}) => [`,
      `          (`,
      `            key(${c.occurrenceId}),`,
      `            ({${id}: ${c.occurrenceRecipient}, ${c.occurrenceId}: ${c.occurrenceId}}: ${n.intake}.todoItem),`,
      `          ),`,
      `        ]`,
      `      | ${n.requested}(_)`,
      `      | ${n.suppressed}(_)`,
      `      | ${n.undeliverable}(_) => []`,
      `      }`,
      ``,
      `    let resolve = event =>`,
      `      switch event {`,
      `      | ${n.requested}({reference})`,
      `      | ${n.suppressed}({reference})`,
      `      | ${n.undeliverable}({reference}) =>`,
      `        Some(reference)`,
      `      | ${c.occurrence}(_) => None`,
      `      }`,
      `  },`,
      `)`,
      ``,
      `let mappings: array<module(Mapping)> = [module(FromDcb)]`,
      ``,
      `// What the notification is about, stated plainly beside the reference. The`,
      `// reference is a correlation key whose format is this relay's own business; the`,
      `// subject names the entity, so a delivery row can say what it concerned without`,
      `// anybody decoding that string.`,
      `let subjectType = "${subjectTypeOf(c)}"`,
      ``,
      `// TODO(graft): the wording. A trait declares the kind; what the sentence says`,
      `// is this host's, and a config field for it would be a template language.`,
      `let process = (id, item: ${n.intake}.todoItem) =>`,
      `  Some((`,
      `    item.${id},`,
      `    ${n.intake}.${n.requestCmd}({`,
      `      ${id}: item.${id},`,
      `      category: ${c.occurrenceCategory},`,
      `      reference: id,`,
      `      subjectType,`,
      `      subjectRef: item.${c.occurrenceId},`,
      `      subject: "TODO(graft)",`,
      `      body: "TODO(graft)",`,
      `    }),`,
      `  ))`,
      ``,
      `// A relay that gave up published no command, so the competency never heard of`,
      `// the occurrence — a delivery-failed fact for a message nobody requested would`,
      `// put a row in the log for something that was never attempted.`,
      `let onExhausted = (_id, _item) => None`,
    ]),
  }
}

/**
Emit a graft.

Five files written, two relays printed. The files are the host's from the moment
they land — nothing regenerates them, and nothing compares against them later.
*/
let emit = (~config: config, ~into: string, ~tests: string): output => {
  let n = namesOf(config)
  {
    files: [
      {path: `${into}/StateChangeSlice/${n.slice}.res`, contents: sliceSpec(config)},
      {path: `${into}/StateChangeSlice/${n.slice}_Behavior.res`, contents: sliceBehavior(config)},
      {path: `${into}/OutboundTranslationSlice/${n.send}.res`, contents: sendSpec(config)},
      {
        path: `${into}/OutboundTranslationSlice/${n.send}_Translation.res`,
        contents: sendTranslation(config),
      },
      {path: `${tests}/NotificationConformance_GWT.res`, contents: conformanceBinding(config)},
    ],
    patches: [contactRelayPatch(config), intakeRelayPatch(config)],
  }
}
