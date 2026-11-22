/***
How a person comes to hold a role: they sign themselves up, someone invites them,
or an administrator makes the account by hand.

A plugin declares one strategy per role in its own `src/Admission.res`, over its
`Roles.t`, so a misspelled role does not compile. The declaration is the hard cap:
a role that is not `SelfService` has no door for visitors, one that is not
`Invitation` cannot be invited to, and no runtime state changes that. A role the
table does not name is `Provisioned`.

`Invitation` is a declaration only. The framework ships no invitation door; a
plugin that provides one marks it, and a deployment declaring a role by
invitation without such a door is refused at deploy and at start.

Keyed by role rather than group, as rules are: the group an account lands in is
`Role.groupOf(role)`, read when the account is made, so a deployment that renames
a role still grants the right one.
*/

type strategy<'role> =
  | SelfService
  | Invitation({by: array<'role>})
  | Provisioned

type entry = {role: Role.name, strategy: strategy<Role.name>}

type t = array<entry>

/** What a slice from a package is applied to, so it reads the app's table
    without importing the app's module: a plugin's `src/Admission.res`, which
    satisfies it as written. */
module type Declaration = {
  let table: t
}

/**
The part a slice plays in admission, declared on its spec as
`let admissionDoor = Reventless.Admission.Start`: the inbound doors that start,
complete and invite, the one view (`OpenRoles`) that tells a visitor which
self-service roles are open right now, and the decision (`Policy`) an
administrator opens and closes a role with: one command whose name starts with
`Open`, one whose name starts with `Close`, and the outbound slice (`Mail`) that
writes to the addresses visitors name, whose mail a deployment caps per day. The platform collects the marked slices
into the shell's configuration, so nobody names a mutation or a query by hand,
and the deploy check reads them: a role declared by invitation needs a door that
invites.
*/
type door =
  | @as("start") Start
  | @as("complete") Complete
  | @as("invite") Invite
  | @as("openRoles") OpenRoles
  | @as("policy") Policy
  | @as("mail") Mail

/** Every door, in declaration order: what `doorOfName` reads against. */
let doors = [Start, Complete, Invite, OpenRoles, Policy, Mail]

/** The door's word, as a marked door's `part` carries it. */
let doorName = (door: door): string => (door :> string)

let doorOfName = (name: string): option<door> => doors->Array.find(door => doorName(door) == name)

/** A marked door as the plugin structure carries it: the component and its part. */
@schema
type doorDef = {component: string, part: string}

/** A strategy's word as the plugin structure carries it. A word this build does
    not know decodes as `OtherStrategy`, keeping the word, so a structure written
    by a newer plugin still decodes in an older reader and is written back as it
    came. */
@unboxed @schema
type strategyWord =
  | @as("SelfService") SelfServiceWord
  | @as("Invitation") InvitationWord
  | @as("Provisioned") ProvisionedWord
  | OtherStrategy(string)

/** One row of the table as the plugin structure carries it. Strings for the
    roles, so a structure written by a newer plugin still decodes in an older
    reader. */
@schema
type def = {role: string, strategy: strategyWord, invitedBy?: array<string>}

// A payload-less case is its name at run time, so the pairs are the same values
// once every role in them has been checked to be one.
external _named: array<('role, strategy<'role>)> => array<(Role.name, strategy<Role.name>)> =
  "%identity"

let _checkCase = (role: Role.name) =>
  if Type.typeof(role) != #string {
    JsError.throwWithMessage(
      `Admission: a role must be a case of a plugin's Roles.t without a payload, got ${JSON.stringifyAny(
          role,
        )->Option.getOr("?")}`,
    )
  }

/** A plugin's table, written over its own `Roles.t`. Every role must be a case
    without a payload, which is its name at run time; anything else is refused. */
let declare = (pairs: array<('role, strategy<'role>)>): t =>
  pairs
  ->_named
  ->Array.map(((role, strategy)) => {
    _checkCase(role)
    switch strategy {
    | Invitation({by}) => by->Array.forEach(_checkCase)
    | SelfService | Provisioned => ()
    }
    ({role, strategy}: entry)
  })

/** The strategy for `role`; `Provisioned` when the table does not name it. */
let strategyOf = (table: t, role: Role.name): strategy<Role.name> =>
  switch table->Array.find(e => e.role == role) {
  | Some({strategy}) => strategy
  | None => Provisioned
  }

let isSelfService = (table: t, role: Role.name): bool =>
  switch strategyOf(table, role) {
  | SelfService => true
  | Invitation(_) | Provisioned => false
  }

/** The roles a visitor may sign up for, in declaration order. */
let selfService = (table: t): array<Role.name> =>
  table->Array.filterMap(e =>
    switch e.strategy {
    | SelfService => Some(e.role)
    | Invitation(_) | Provisioned => None
    }
  )

let strategyWordOf = (s: strategy<_>): strategyWord =>
  switch s {
  | SelfService => SelfServiceWord
  | Invitation(_) => InvitationWord
  | Provisioned => ProvisionedWord
  }

/** A word read from text: every word is one, a word this build does not know
    being `OtherStrategy`. */
external strategyWordOfString: string => strategyWord = "%identity"

/**
Refuse a table that cannot mean what it says: a role named twice, a role or an
inviter outside `roles`, or an invitation nobody may send. Refused rather than
read past, because each would otherwise leave a role admitted differently from
how it was declared.
*/
let validate = (table: t, ~roles: array<Role.name>): result<t, string> => {
  let known = r => roles->Array.includes(r)
  let problems = table->Array.flatMapWithIndex((e, i) => {
    let role = (e.role :> string)
    let duplicate =
      table->Array.findIndex(other => other.role == e.role) < i ? [`${role} is declared twice`] : []
    let unknown = known(e.role) ? [] : [`${role} is not a role of this plugin`]
    let inviters = switch e.strategy {
    | Invitation({by: []}) => [`${role} is by invitation, but nobody may invite`]
    | Invitation({by}) =>
      by
      ->Array.filter(r => !known(r))
      ->Array.map(r => `${role} is by invitation from ${(r :> string)}, which is not a role`)
    | SelfService | Provisioned => []
    }
    Array.concatMany(duplicate, [unknown, inviters])
  })
  switch problems {
  | [] => Ok(table)
  | _ => Error(`Admission: ${problems->Array.join("; ")}`)
  }
}

let toDefs = (table: t): array<def> =>
  table->Array.map(({role, strategy}): def =>
    switch strategy {
    | Invitation({by}) => {
        role: (role :> string),
        strategy: strategyWordOf(strategy),
        invitedBy: by->Array.map(r => (r :> string)),
      }
    | SelfService | Provisioned => {role: (role :> string), strategy: strategyWordOf(strategy)}
    }
  )

/** Read a table off a structure. A strategy this build does not know refuses,
    for the reason `fromJson` does. */
let fromDefs = (defs: array<def>): result<t, string> => {
  let read = defs->Array.map((d): result<entry, string> =>
    switch (d.strategy, d.invitedBy) {
    | (SelfServiceWord, _) => Ok({role: Role.make(d.role), strategy: SelfService})
    | (ProvisionedWord, _) => Ok({role: Role.make(d.role), strategy: Provisioned})
    | (InvitationWord, Some(by)) =>
      Ok({role: Role.make(d.role), strategy: Invitation({by: by->Array.map(Role.make)})})
    | (InvitationWord, None) => Error(`${d.role}: an invitation names who may send it`)
    | (OtherStrategy(other), _) => Error(`${d.role}: ${other} is not a strategy`)
    }
  )
  switch read->Array.filterMap(r =>
    switch r {
    | Error(why) => Some(why)
    | Ok(_) => None
    }
  ) {
  | [] =>
    Ok(
      read->Array.filterMap(r =>
        switch r {
        | Ok(e) => Some(e)
        | Error(_) => None
        }
      ),
    )
  | problems => Error(`Admission: ${problems->Array.join("; ")}`)
  }
}

/** The table as JSON: `{"Shopper": "SelfService", "Merchandiser": {"Invitation":
    {"by": ["Admin"]}}, "Admin": "Provisioned"}`. */
let toJson = (table: t): JSON.t =>
  table
  ->Array.map(({role, strategy}) => (
    (role :> string),
    switch strategy {
    | SelfService | Provisioned => JSON.String((strategyWordOf(strategy) :> string))
    | Invitation({by}) =>
      JSON.Object(
        Dict.fromArray([
          (
            (InvitationWord :> string),
            JSON.Object(
              Dict.fromArray([("by", JSON.Array(by->Array.map(r => JSON.String((r :> string)))))]),
            ),
          ),
        ]),
      )
    },
  ))
  ->Dict.fromArray
  ->JSON.Object

let _strategyFromJson = (role: string, json: JSON.t): result<strategy<Role.name>, string> =>
  switch json {
  | String(word) =>
    switch strategyWordOfString(word) {
    | SelfServiceWord => Ok(SelfService)
    | ProvisionedWord => Ok(Provisioned)
    | _ => Error(`${role}: ${JSON.stringify(json)} is not a strategy`)
    }
  | Object(o) =>
    switch (
      o->Dict.keysToArray->Array.map(strategyWordOfString),
      o->Dict.get((InvitationWord :> string)),
    ) {
    | ([InvitationWord], Some(Object(inv))) =>
      switch inv->Dict.get("by") {
      | Some(Array(by)) =>
        let names = by->Array.filterMap(r =>
          switch r {
          | String(s) => Some(Role.make(s))
          | _ => None
          }
        )
        names->Array.length == by->Array.length
          ? Ok(Invitation({by: names}))
          : Error(`${role}: an inviter must be a role name`)
      | _ => Error(`${role}: an invitation names who may send it, as "by"`)
      }
    | _ => Error(`${role}: ${JSON.stringify(json)} is not a strategy`)
    }
  | _ => Error(`${role}: ${JSON.stringify(json)} is not a strategy`)
  }

/** Read a table written by `toJson`, refusing an unknown strategy or role rather
    than reading it as `Provisioned`. */
let fromJson = (json: JSON.t, ~roles: array<Role.name>): result<t, string> =>
  switch json {
  | Object(o) =>
    let read = o->Dict.toArray->Array.map(((role, s)) => (role, _strategyFromJson(role, s)))
    switch read->Array.filterMap(((_, r)) =>
      switch r {
      | Error(why) => Some(why)
      | Ok(_) => None
      }
    ) {
    | [] =>
      read
      ->Array.filterMap(((role, r)) =>
        switch r {
        | Ok(strategy) => Some(({role: Role.make(role), strategy}: entry))
        | Error(_) => None
        }
      )
      ->validate(~roles)
    | problems => Error(`Admission: ${problems->Array.join("; ")}`)
    }
  | _ => Error("Admission: a table is an object from role to strategy")
  }

// ── The starting state ──────────────────────────────────────────────────────

/**
What a self-service role is while no administrator has opened or closed it, or once
the window one opened has ended: open, or closed.

Deploy configuration, not domain state. Whether a deployment is a laptop or a
public address is a fact of the environment; what an administrator did since is
recorded, and wins. Locally a self-service role starts open, so a developer signs
up with no command first; on AWS it starts closed, so a public address takes no
stranger until someone opens it, for a while.

The sign-up door stamps it onto the request (`Register`), so the ledger that reads
it stays a function of what it is told. A request stamped with nothing was made
before there was a starting state, when every role started open, and reads as open.
*/
@schema
type initially =
  | @as("open") InitiallyOpen
  | @as("closed") InitiallyClosed

/** The setting as an environment variable, on the local platform. */
let initiallyEnvKey = "REVENTLESS_SELF_REGISTRATION_INITIALLY"

/** The setting as a stack's configuration, on AWS. */
let initiallyConfigKey = "platform:selfRegistrationInitially"

/** Open: a developer signing up on their own machine needs no command first. */
let localInitially = InitiallyOpen

/** Closed: a public address takes no stranger until someone decides so. */
let awsInitially = InitiallyClosed

let initiallyName = (i: initially): string => (i :> string)

/**
`open` or `closed`. Refuses anything else rather than reading the platform's
default, because a setting someone wrote and mistyped would otherwise be replaced
by one they did not choose.
*/
let parseInitially = (raw: string, ~key: string): result<initially, string> =>
  switch raw->String.trim {
  | "open" => Ok(InitiallyOpen)
  | "closed" => Ok(InitiallyClosed)
  | _ => Error(`${key}: "${raw}" is not a starting state — write open or closed`)
  }

/** The starting state a platform reads: its setting when one is given, else the
    platform's default. An empty setting is no setting. */
let initiallyFrom = (raw: option<string>, ~key: string, ~default: initially): result<
  initially,
  string,
> =>
  switch raw->Option.map(String.trim) {
  | None | Some("") => Ok(default)
  | Some(given) => parseInitially(given, ~key)
  }
