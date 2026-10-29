// Recording fakes for `Reventless.Capabilities.t`: every call a `translate` makes
// is kept, in order, and each answer can be scripted. What an outbound test
// asserts with `thenSent`.

module Capabilities = Reventless.Capabilities
module Geocoding = Reventless.Geocoding
module Messaging = Reventless.Messaging
module IdentityProvider = Reventless.IdentityProvider
module Secrets = Reventless.Secrets
module Stash = Reventless.Stash

/** One call a slice made through its capabilities. */
type call =
  | Geocoded({text: string})
  | Sent({recipient: Messaging.recipient, message: Messaging.message})
  | PrincipalCreated({
      contact: Messaging.recipient,
      credential: IdentityProvider.credential,
      groups: array<string>,
    })
  | AddedToGroup({principal: IdentityProvider.principal, group: string})
  | RemovedFromGroup({principal: IdentityProvider.principal, group: string})
  | PrincipalDeleted({principal: IdentityProvider.principal})
  | TokenDrawn({length: int, alphabet: Secrets.alphabet})
  | Hashed({input: string})
  /** A value put in the stash. The value itself is recorded, so a test can
      assert which secret was handed over — a fake has no log to keep it out of. */
  | Stashed({key: string, value: string, ttl: Reventless.Duration.t})
  | Taken({key: string})

type t = {
  capabilities: Capabilities.t,
  /** The calls made so far, oldest first. */
  calls: unit => array<call>,
}

/**
Fakes whose answers are given per capability. An answer left out is a plain
success: a geocoder with no candidates, a send with a numbered receipt, a
principal with a numbered id, `token` (or `t` repeated to length), and a hash
that prefixes `"hash:"`. `~secrets` replaces the secret source whole, e.g. with
`Secrets.unavailable`; its calls are still recorded. The stash holds what is put
in it and hands each value over once, starting from `~stashed`; `~stash`
replaces it whole, e.g. with `Stash.unavailable`.
*/
let make = (
  ~geocode: option<Geocoding.search>=?,
  ~send: option<Messaging.send>=?,
  ~channels: array<Messaging.channel>=[Email, Sms],
  ~pushServices: array<Messaging.pushService>=[],
  ~createPrincipal: option<
    (
      ~contact: Messaging.recipient,
      ~credential: IdentityProvider.credential,
      ~groups: array<string>,
    ) => promise<result<IdentityProvider.principal, IdentityProvider.failure>>,
  >=?,
  ~token: option<string>=?,
  ~hash: option<string => string>=?,
  ~secrets: option<Secrets.t>=?,
  ~stashed: array<(string, string)>=[],
  ~stash: option<Stash.t>=?,
  (),
): t => {
  let log: array<call> = []
  let record = c => log->Array.push(c)
  let geocode = async (~text) => {
    record(Geocoded({text: text}))
    switch geocode {
    | Some(f) => await f(~text)
    | None => Ok([])
    }
  }
  let send = async (~recipient, ~message) => {
    record(Sent({recipient, message}))
    switch send {
    | Some(f) => await f(~recipient, ~message)
    | None => Ok({Messaging.ref: `receipt-${Int.toString(log->Array.length)}`})
    }
  }
  let createPrincipal = async (~contact, ~credential, ~groups) => {
    record(PrincipalCreated({contact, credential, groups}))
    switch createPrincipal {
    | Some(f) => await f(~contact, ~credential, ~groups)
    | None => Ok({IdentityProvider.providerId: `principal-${Int.toString(log->Array.length)}`})
    }
  }
  let held = Dict.fromArray(stashed)
  let capabilities: Capabilities.t = {
    geocode,
    messaging: Messaging.makeProvider(~emailAndSms=channels, ~pushServices, ~send),
    identityProvider: IdentityProvider.make(
      ~createPrincipal,
      ~addToGroup=async (~principal, ~group) => {
        record(AddedToGroup({principal, group}))
        Ok()
      },
      ~removeFromGroup=async (~principal, ~group) => {
        record(RemovedFromGroup({principal, group}))
        Ok()
      },
      ~deletePrincipal=async (~principal) => {
        record(PrincipalDeleted({principal: principal}))
        Ok()
      },
      ~operations=[CreatePrincipal, AddToGroup, RemoveFromGroup, DeletePrincipal],
    ),
    secrets: {
      randomToken: (~length, ~alphabet) => {
        record(TokenDrawn({length, alphabet}))
        switch secrets {
        | Some(s) => s.randomToken(~length, ~alphabet)
        | None => Ok(token->Option.getOr("t"->String.repeat(length)))
        }
      },
      hash: input => {
        record(Hashed({input: input}))
        switch secrets {
        | Some(s) => s.hash(input)
        | None => Ok(hash->Option.mapOr(`hash:${input}`, f => f(input)))
        }
      },
      fingerprint: (~purpose, input) =>
        switch secrets {
        | Some(s) => s.fingerprint(~purpose, input)
        | None => Ok(Reventless.Secrets.fixedFingerprint(~purpose, input))
        },
    },
    stash: {
      put: async (~key, ~value, ~ttl) => {
        record(Stashed({key, value, ttl}))
        switch stash {
        | Some(s) => await s.put(~key, ~value, ~ttl)
        | None =>
          held->Dict.set(key, value)
          Ok()
        }
      },
      take: async (~key) => {
        record(Taken({key: key}))
        switch stash {
        | Some(s) => await s.take(~key)
        | None =>
          let found = held->Dict.get(key)
          held->Dict.delete(key)
          Ok(found)
        }
      },
    },
  }
  {capabilities, calls: () => log->Array.copy}
}

/** A readable rendering of a call, for a mismatch. */
let toJson = (c: call): JSON.t => {
  let recipientText = (r: Messaging.recipient) =>
    switch r {
    | ToEmail(email) => `email:${email}`
    | ToSms(phone) => `sms:${phone}`
    | ToPush(address) => `push:${address->Messaging.serviceOf->Messaging.pushServiceToString}`
    }
  let obj = (tag, fields) =>
    JSON.Encode.object(Dict.fromArray([("TAG", JSON.Encode.string(tag)), ...fields]))
  let str = JSON.Encode.string
  switch c {
  | Geocoded({text}) => obj("Geocoded", [("text", str(text))])
  | Sent({recipient, message}) =>
    obj(
      "Sent",
      [
        ("recipient", str(recipientText(recipient))),
        ("subject", message.subject->Option.mapOr(JSON.Encode.null, str)),
        ("body", str(message.body)),
      ],
    )
  | PrincipalCreated({contact, groups, _}) =>
    obj(
      "PrincipalCreated",
      [
        ("contact", str(recipientText(contact))),
        ("groups", groups->Array.map(str)->JSON.Encode.array),
      ],
    )
  | AddedToGroup({principal, group}) =>
    obj("AddedToGroup", [("principal", str(principal.providerId)), ("group", str(group))])
  | RemovedFromGroup({principal, group}) =>
    obj("RemovedFromGroup", [("principal", str(principal.providerId)), ("group", str(group))])
  | PrincipalDeleted({principal}) =>
    obj("PrincipalDeleted", [("principal", str(principal.providerId))])
  | TokenDrawn({length, _}) => obj("TokenDrawn", [("length", JSON.Encode.int(length))])
  | Hashed({input}) => obj("Hashed", [("input", str(input))])
  | Stashed({key, ttl, _}) => obj("Stashed", [("key", str(key)), ("ttl", JSON.Encode.int(ttl))])
  | Taken({key}) => obj("Taken", [("key", str(key))])
  }
}
