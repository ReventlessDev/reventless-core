/**
Classifies the caller behind a request for the purposes of `@owner` enforcement:
whose id gets stamped into an owner-marked command field, and whose rows an
owner-scoped read is narrowed to.

This is deliberately one function rather than a check written twice. The write
path and the read path must agree about who is exempt — an implementation that
scopes reads but not writes labels rows correctly and shows them to everyone,
and one that scopes writes but not reads does the reverse. Both call `resolve`.

⚠️ **`Identity.t` is not trustworthy at this boundary, and this module is where
that stops mattering.** The AppSync resolver templates build the identity object
in generated JavaScript and hand it to a handler that types it as `Identity.t`
without decoding it. For a Cognito caller the shape matches. For an IAM-signed
caller — every AppSync API in a deployed estate carries `AWS_IAM` as an
additional provider for service-to-service traffic — the template emits
`{userArn, accountId, username, provider: 'IAM'}`: no `userId`, no `groups`, and
a `provider` string that is not one of the three the variant models. So the
fields this module reads are typed non-optional and are, at runtime, sometimes
absent. Every read here goes through a nullable cast for that reason; deleting
one restores a silent failure rather than a type error.
*/

/** Whether a JS value is a primitive string — `Cognito` and `InMemory` compile to
    bare strings while `Custom(_)` compiles to an object, so this is how a modelled
    provider is told from an unmodelled one that arrived as raw JSON. */
let isJsString: 'a => bool = %raw(`v => typeof v === "string"`)

external asNullableString: string => Nullable.t<string> = "%identity"
external asNullableArray: array<string> => Nullable.t<array<string>> = "%identity"
external asString: Identity.provider => string = "%identity"
external asNullableIdentity: Identity.t => Nullable.t<Identity.t> = "%identity"

/**
The caller, classified.

`System` and `Elevated` behave identically today — neither is stamped, neither is
scoped — and are still separate cases because they are different claims. `System`
says the platform is calling itself; `Elevated` says a named human holds an
operator group. Collapsing them would make an audit unable to tell a service
write from an administrator's.

`Unidentified` carries a short reason because it is the fail-closed branch, and
the fail-closed branch is the one someone will be debugging.
*/
type t =
  | System
  | Elevated({userId: string})
  | Owned({userId: string})
  | Unidentified(string)

/**
Providers that identify a *machine*, not a person. Members are exempt from
stamping and scoping.

An allowlist rather than "anything not modelled", because the fallback direction
is the whole safety property here: a provider nobody has classified must land in
`Unidentified` and be refused, not in `System` and be handed unscoped reads. Add
to this list deliberately.
*/
let systemProviders = ["IAM"]

/**
Groups whose members read across every owner.

A single deployment-wide list, not a parameter of the annotation. Per-annotation
elevation would let two views disagree about who an operator is, so a caller
scoped on one view would be unscoped on the next — and the gap would appear one
view at a time, as views were added.

Resolved as: an explicit `setElevatedGroups` wins, else the environment, else
empty. The env fallback exists because a deployment is **two kinds of process**,
not one. On a cloud provider the read predicate for a table-backed view is baked
into resolver source by the deploy program, while stamping and the SQL-backed
reads run later inside separate function runtimes the deploy never enters. A
value set in the deploy program alone reaches the first and not the second — and
the failure that produces is a *wrong write*, not a narrow read: an operator
acting on someone's behalf gets the row stamped with their own id, because the
runtime believes nobody is elevated. An environment variable is the only carrier
both kinds of process share, which is the same reason the logger's level is one.

Empty remains the default in both directions: a deployment that configures
nothing shows operators too little rather than showing customers each other.
*/
@val
external _elevatedGroupsEnv: option<string> = "process.env.REVENTLESS_ELEVATED_GROUPS"

let explicitElevatedGroups: ref<option<array<string>>> = ref(None)

/** Set the list for this process. Wins over the environment — a platform root
    that states its operator groups in code means it, and should not be silently
    overridden by a stray variable. */
let setElevatedGroups = (groups: array<string>) => explicitElevatedGroups := Some(groups)

/** Forget an explicit setting and fall back to the environment again. */
let clearElevatedGroups = () => explicitElevatedGroups := None

let parseElevatedGroups = (raw: string): array<string> =>
  raw
  ->String.split(",")
  ->Array.map(String.trim)
  ->Array.filter(part => part->String.length > 0)

/**
The groups exempt from owner scoping, right now.

A function rather than a `ref` anyone can read: the answer depends on the
environment as well as on what was set, and it is re-read per call so a value
appearing later in a process still takes effect. Reading a raw ref would have
frozen whichever half happened to be consulted first.
*/
let elevatedGroups = (): array<string> =>
  switch explicitElevatedGroups.contents {
  | Some(groups) => groups
  | None =>
    switch _elevatedGroupsEnv {
    | Some(raw) => parseElevatedGroups(raw)
    | None => []
    }
  }

// Order matters: the provider is examined before `userId`, because the IAM
// caller fails the `userId` test for a reason that has nothing to do with being
// anonymous and must not be refused as though it did.
let classify = (identity: Identity.t, ~elevated: array<string>): t => {
  let provider = identity.provider
  let providerName = isJsString(provider) ? Some(provider->asString) : None

  switch providerName {
  | Some(name) if systemProviders->Array.includes(name) => System
  // A modelled string provider, or `Custom(_)` (an object, so `providerName` is
  // None) — either way a caller claiming to be a person. Unmodelled strings fall
  // through to the refusal below.
  | Some("Cognito") | Some("InMemory") | None =>
    switch identity.userId->asNullableString->Nullable.toOption {
    | None => Unidentified("identity carries no userId")
    | Some("") => Unidentified("identity carries an empty userId")
    | Some(userId) if userId == Identity.anonymous.userId =>
      Unidentified("caller is anonymous")
    | Some(userId) =>
      let groups = identity.groups->asNullableArray->Nullable.toOption->Option.getOr([])
      groups->Array.some(g => elevated->Array.includes(g))
        ? Elevated({userId: userId})
        : Owned({userId: userId})
    }
  | Some(name) => Unidentified(`unrecognised identity provider "${name}"`)
  }
}

/**
Classify a caller. `~elevated` defaults to the configured list so call sites do
not each have to remember to read it.
*/
let resolve = (identity: Identity.t, ~elevated: array<string>=elevatedGroups()): t =>
  // The whole identity, not just its fields, can be missing: an internal caller
  // that builds a payload without one reaches here with `undefined`. Reading
  // through it would raise a TypeError, which surfaces as a crash rather than as
  // the refusal this case actually is.
  switch identity->asNullableIdentity->Nullable.toOption {
  | None => Unidentified("request carries no identity")
  | Some(identity) => classify(identity, ~elevated)
  }

/**
The id an owner-marked field takes, and the value an owner-scoped read matches.

`None` for `System` and `Elevated` means "do not stamp, do not scope" — and it
means the same for `Unidentified`, which is why no caller may treat this as the
whole answer. A write must refuse an `Unidentified` caller outright rather than
publish an unstamped command; use `resolve` directly there.
*/
let ownerId = (scope: t): option<string> =>
  switch scope {
  | Owned({userId}) => Some(userId)
  | System | Elevated(_) | Unidentified(_) => None
  }

/** Whether the caller reads and writes across every owner. */
let isExempt = (scope: t): bool =>
  switch scope {
  | System | Elevated(_) => true
  | Owned(_) | Unidentified(_) => false
  }

/**
What owner scoping does to one read of one view.

`RefuseOwned` is kept apart from "scope to a value nobody holds" because the two
produce the same empty page for different reasons, and only one of them is a
refusal — a door that wants to say so needs to be able to tell.
*/
type decision =
  | Unscoped
  | ScopeTo(string, string)
  | RefuseOwned

/**
Combine a view's declared owner field with the caller behind the request.

Lives here rather than at each read path because there are four of them —
the shared list spec, two SQL push-downs and the generated AppSync resolver —
and they must answer identically. Four copies of this `switch` would be four
chances to decide that an unidentified caller "just sees nothing".
*/
let decide = (
  identity: Identity.t,
  ~ownerField: option<string>,
  ~elevated: array<string>=elevatedGroups(),
): decision =>
  switch ownerField {
  | None => Unscoped
  | Some(field) =>
    switch resolve(identity, ~elevated) {
    | System | Elevated(_) => Unscoped
    | Owned({userId}) => ScopeTo(field, userId)
    // The view records an owner and the caller has none. Scoping to a value
    // nobody holds would be indistinguishable from an empty view.
    | Unidentified(_) => RefuseOwned
    }
  }

/** The `(field, value)` pair a list query narrows on, or `None` when it does not. */
let scopeOf = (decision: decision): option<(string, string)> =>
  switch decision {
  | ScopeTo(field, required) => Some((field, required))
  | Unscoped | RefuseOwned => None
  }

/**
What `@retired` does to one read of one view.

Deliberately in this module rather than beside the annotation. Owner scoping and
retirement narrowing are two rules over the same question — which rows does this
caller get — and they resolve the caller with the same `resolve`, against the
same deployment-wide `elevatedGroups`. Written apart, they could disagree about
who an operator is, and the disagreement would be invisible until a caller
elevated for one rule turned out to be scoped by the other.

`ExcludeRetired` carries the field rather than a `(field, value)` pair like
`ScopeTo`: the excluded value is always `true`, and a parameter that can only
hold one value is a parameter a call site can pass wrongly.
*/
type retiredDecision =
  | RetiredVisible
  | ExcludeRetired(string)

/**
Combine a view's declared retirement flag with the caller behind the request.

`~asked` is the caller's `includeRetired` request, honoured only where the
caller was going to see those rows anyway. Reading it before classifying would
make the argument the decision rather than a request.

`Unidentified` excludes rather than refuses, which is where this parts company
with `decide`. An owner-scoped read of an unidentified caller has no value to
match, so scoping it would be indistinguishable from an empty view and a refusal
says more. Retirement has no such value — the predicate is the same for every
non-exempt caller — so the fail-closed action is simply the narrow read.
*/
let decideRetired = (
  identity: Identity.t,
  ~retiredField: option<string>,
  ~asked: bool=false,
  ~elevated: array<string>=elevatedGroups(),
): retiredDecision =>
  switch retiredField {
  | None => RetiredVisible
  | Some(field) =>
    switch resolve(identity, ~elevated) {
    | System | Elevated(_) => asked ? RetiredVisible : ExcludeRetired(field)
    | Owned(_) | Unidentified(_) => ExcludeRetired(field)
    }
  }

/**
The field a read excludes on, or `None` when it excludes nothing.

Note that an exempt caller who did not ask still gets `Some`: retired rows are
withheld from everyone by default, and elevation buys the ability to ask for
them rather than a standing exemption. An archive that is always underfoot is
not an archive.
*/
let retiredScopeOf = (decision: retiredDecision): option<string> =>
  switch decision {
  | ExcludeRetired(field) => Some(field)
  | RetiredVisible => None
  }
