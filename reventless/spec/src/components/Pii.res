/**
Personal data: a field whose value is about a person, and the forms it is stored in.

`@pii` (step PD2) marks such a field. On an event it gives the field the type
`Pii.t<'a>`, so code that reads it must say what it does when the value is gone;
on a command it only marks, and on a read model it is refused. This module holds
what the annotation stands on: the type, the stored forms, the field codec, and
the provider seam a deployment may fill with one that encrypts.

## Two halves, because a codec cannot fetch a key

A sury codec is synchronous and sees one field at a time. An encrypting provider
needs neither: it fetches keys from a store, which is asynchronous, and it files a
value under its *subject*, which is a sibling field of the same record. So the work
is split:

- **The field codec** (`schema`) is synchronous, declarative and provider-free. It
  reads a value, or one of the two markers a provider leaves when a value is gone,
  and nothing else.
- **The provider** (`provider`) runs at the event log's seam, on the whole encoded
  payload, before an append (`seal`) and after a read (`open_`). It turns a value
  into a stored form and back, and it may fetch keys there.

A payload that skipped the provider is loud on both sides: an append refuses an
unsealed field when an encrypting provider is installed (PD9), and the field codec
fails on a stored form it was handed unopened.

## The stored forms

Every non-plain form is an object under one reserved key, `$pii`, like `@offload`'s
`$offload`: no ReScript record field encodes to a key starting with `$`, so a plain
value — of any type, including a string that happens to read `erased:v1` — can never
be mistaken for one.

| Form | Wire | Written by |
|---|---|---|
| plain | the value itself | the plain provider, the default |
| ciphertext | `{"$pii": "enc:v1:<keyId>:<alg>:<base64>"}` | an encrypting provider |
| erased | `{"$pii": "erased:v1"}` | a provider whose key is gone, or a masking sweep |
| forgotten | `{"$pii": "ref:v1:<ref>"}` | a provider, for a value that lives in a store |

The key id makes a value re-keyable, the version migratable. The decoder never fails
on the last two. Once opened, a value is the plain value again, or one of the two
markers `{"$pii": "erased:v1"}` and `{"$pii": "forgotten:v1"}`, which is all the field
codec ever reads.
*/
/** What app code reads from a personal field. */
type t<'a> =
  /** The value. Without an encrypting provider, the only case there is. */
  | Value('a)
  /** The value existed, and its key has been destroyed. */
  | Erased
  /** The value lived in a store, and the object has been deleted. */
  | Forgotten

/** The key every non-plain form sits under. */
let sentinelKey = "$pii"

/** The marker of a value whose key is gone, stored and opened alike. */
let erasedMarker = "erased:v1"

/** The marker an opened, forgotten value carries. The stored form keeps its ref. */
let forgottenMarker = "forgotten:v1"

/** A stored form, parsed. */
type stored =
  | Cipher({version: int, keyId: string, alg: string, bytes: string})
  | ErasedForm({version: int})
  | ForgottenForm({version: int, ref: string})

let printStored = (form: stored): string =>
  switch form {
  | Cipher({version, keyId, alg, bytes}) => `enc:v${version->Int.toString}:${keyId}:${alg}:${bytes}`
  | ErasedForm({version}) => `erased:v${version->Int.toString}`
  | ForgottenForm({version, ref}) => `ref:v${version->Int.toString}:${ref}`
  }

let parseVersion = (raw: string): option<int> =>
  raw->String.startsWith("v")
    ? raw->String.slice(~start=1)->Int.fromString->Option.filter(v => v > 0)
    : None

/**
Parse a stored form's string. A key id and an algorithm hold no `:`; the base64 of
the ciphertext holds none either, and a ref is everything after its version, so a
ref may hold one.
*/
let parseStored = (raw: string): option<stored> =>
  switch raw->String.split(":") {
  | ["enc", v, keyId, alg, bytes] if keyId != "" && alg != "" && bytes != "" =>
    parseVersion(v)->Option.map(version => Cipher({version, keyId, alg, bytes}))
  | ["erased", v] => parseVersion(v)->Option.map(version => ErasedForm({version: version}))
  | parts if parts->Array.get(0) == Some("ref") && parts->Array.length >= 3 =>
    let ref = parts->Array.slice(~start=2)->Array.join(":")
    ref == ""
      ? None
      : parts
        ->Array.getUnsafe(1)
        ->parseVersion
        ->Option.map(version => ForgottenForm({version, ref}))
  | _ => None
  }

/** The object a stored form or a marker is written as. */
let wrap = (form: string): JSON.t =>
  Dict.fromArray([(sentinelKey, JSON.Encode.string(form))])->JSON.Encode.object

/** The form under the sentinel, when the value is one; `None` for a plain value. */
let unwrap = (json: JSON.t): option<string> =>
  switch json {
  | Object(obj) if obj->Dict.keysToArray->Array.length == 1 =>
    obj->Dict.get(sentinelKey)->Option.flatMap(JSON.Decode.string)
  | _ => None
  }

/**
The field codec for a personal field of inner type `'a`.

Declared arms only, as `Offload.schema` explains: a transform arm is opaque to sury
and brings back the failures that codec documents. The two markers are tried first,
so a marker is never read as a value; a stored form that was never opened matches
neither marker nor, being an object under `$pii`, a plain value of any record type,
and the decode fails rather than handing the app ciphertext.
*/
let schema = (inner: S.t<'a>): S.t<t<'a>> => {
  let erasedArm = S.object(s => {
    s.tag(sentinelKey, erasedMarker)
    Erased
  })
  let forgottenArm = S.object(s => {
    s.tag(sentinelKey, forgottenMarker)
    Forgotten
  })
  let valueArm = inner->S.shape(value => Value(value))
  S.union([erasedArm, forgottenArm, valueArm])
}

/** The value, when there is one. */
let toOption = (value: t<'a>): option<'a> =>
  switch value {
  | Value(v) => Some(v)
  | Erased | Forgotten => None
  }

/** The value, or a fallback for a value that is gone. */
let getOr = (value: t<'a>, fallback: 'a): 'a => value->toOption->Option.getOr(fallback)

/** Why a provider could not seal or open a field. Never holds the value. */
type error =
  | KeyUnavailable({subject: string})
  | UnknownForm({field: string})
  | ProviderFailed({message: string})

let errorMessage = (error: error): string =>
  switch error {
  | KeyUnavailable({subject}) => `no key could be fetched for subject ${subject}`
  | UnknownForm({field}) => `the stored form of field ${field} is not one this provider reads`
  | ProviderFailed({message}) => message
  }

/**
The seam an encrypting provider fills. One is installed per process and per
platform: a subject's fields are written by several plugins, so its keys are a
platform resource every plugin's runtime reaches.

- `seal` turns a field's plain JSON into what is stored. `~forgettable` says the
  value lives in a store (an upload, an `@offload` or `@storageRef` field): it is
  filed for deletion under its subject, not encrypted.
- `open_` turns what was stored into the plain JSON, or into one of the two markers.
- `release` deletes a forgettable value's object on erasure.

A provider fails rather than degrades: a key it cannot fetch is an `Error`, never a
plain value written in its place.
*/
type provider = {
  name: string,
  /** Whether `seal` changes anything; the append refusal of PD9 runs only when it does. */
  encrypts: bool,
  seal: (
    ~subject: string,
    ~field: string,
    ~forgettable: bool,
    JSON.t,
  ) => promise<result<JSON.t, error>>,
  @as("open")
  open_: (~field: string, JSON.t) => promise<result<JSON.t, error>>,
  release: (~subject: string, ~ref: string) => promise<result<unit, error>>,
}

/**
The provider the framework ships: values are stored as they are. It still reads the
forms another provider left, so a deployment that uninstalls one keeps reading its
log: an erased value opens as erased and a forgotten one as forgotten. Ciphertext it
cannot open, and says so.
*/
let plain: provider = {
  name: "plain",
  encrypts: false,
  seal: (~subject as _, ~field as _, ~forgettable as _, json) => Promise.resolve(Ok(json)),
  open_: (~field, json) =>
    Promise.resolve(
      switch json->unwrap {
      | None => Ok(json)
      | Some(form) =>
        switch form->parseStored {
        | Some(ErasedForm(_)) => Ok(wrap(erasedMarker))
        | Some(ForgottenForm(_)) => Ok(wrap(forgottenMarker))
        | Some(Cipher(_)) | None =>
          form == erasedMarker || form == forgottenMarker
            ? Ok(json)
            : Error(UnknownForm({field: field}))
        }
      },
    ),
  release: (~subject as _, ~ref as _) => Promise.resolve(Ok()),
}

/** The provider of this process. A deployment installs its own once, at start. */
module Provider = {
  let current: ref<provider> = ref(plain)
  let install = (provider: provider) => current := provider
  let get = () => current.contents
}
