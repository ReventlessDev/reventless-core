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

/**
What `@pii` records about a field: whose data it is, and whether the value lives
in a store. Read by the seal and open pass, by log redaction and by the JSON schema.
*/
type marker = {
  /** The name of the sibling field holding the subject's id, the key's owner. */
  subject: string,
  /** The value is a reference to an object in a store: erasure deletes the object
      rather than destroying a key. */
  forgettable: bool,
}

let piiId: S.Metadata.Id.t<marker> = S.Metadata.Id.make(~namespace="reventless", ~name="pii")

/**
The schema of a personal field of an **event**: the wrapper's codec, the marker,
and `@sensitive`, which `@pii` implies. What `@pii` expands to on an event field.
*/
let marked = (~subject: string, ~forgettable: bool=false, inner: S.t<'a>): S.t<t<'a>> =>
  schema(inner)->S.Metadata.set(~id=piiId, {subject, forgettable})->Sensitive.mark

/**
The schema of a personal field of a **command**: the field keeps its plain type,
because a command is never stored and its handler needs the value, and gains the
marker and `@sensitive`, so it is redacted in logs. What `@pii` expands to there.
*/
let mark = (~subject: string, ~forgettable: bool=false, inner: S.t<'a>): S.t<'a> =>
  inner->S.Metadata.set(~id=piiId, {subject, forgettable})->Sensitive.mark

/** The marker on this exact schema. Does not look through wrappers. */
let markerOf = (schema: S.t<unknown>): option<marker> => S.Metadata.get(schema, ~id=piiId)

/** The marker of a *field*, looking through an optional wrapper as
    `Sensitive.isFieldSensitive` does. */
let fieldMarker = (schema: S.t<unknown>): option<marker> =>
  switch markerOf(schema) {
  | Some(m) => Some(m)
  | None => schema->Semantic.unwrapOptional->Option.flatMap(markerOf)
  }

/** The personal fields of an object schema with their markers, in declaration order. */
let fieldsOf = (schema: S.t<unknown>): array<(string, marker)> =>
  switch schema {
  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((name, field)) => field->fieldMarker->Option.map(m => (name, m)))
  | _ => []
  }

/** The personal fields of one constructor of a command or event union. */
let variantFields = (schema: S.t<unknown>, ~variant: string): array<(string, marker)> =>
  schema->Semantic.unionVariant(~variant)->Option.mapOr([], fieldsOf)

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
  /** Loads the keys these ids name, so `openNow` can use them without waiting.
      Called by `prepare` at each batch's entry, never per field. */
  prefetch: array<string> => promise<result<unit, error>>,
  /** Opens one stored form with the keys already at hand: synchronous, because
      the decoders that call it are. A key that was not prefetched is an `Error`,
      never a wrong value. */
  openNow: (~field: string, JSON.t) => result<JSON.t, error>,
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
  prefetch: _ => Promise.resolve(Ok()),
  openNow: (~field, json) =>
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
  release: (~subject as _, ~ref as _) => Promise.resolve(Ok()),
}

@val
external requireEncryptionEnv: Nullable.t<string> = "process.env.REVENTLESS_PII_REQUIRE_ENCRYPTION"

/** The provider of this process. A deployment installs its own once, at start. */
module Provider = {
  let current: ref<provider> = ref(plain)
  /** An install still in flight, which sealing and key fetching wait for. */
  let pending: ref<option<promise<unit>>> = ref(None)
  /** Why the last install in flight failed: until another install, nothing that
      needs the provider proceeds. */
  let failed: ref<option<string>> = ref(None)

  let install = (provider: provider) => {
    current := provider
    pending := None
    failed := None
  }
  let get = () => current.contents

  /**
  Install a provider that is still being built, such as one that must unwrap its
  key with a remote service at cold start. Until it settles, `sealData` and
  `prepare` wait for it rather than run with whatever was installed before; if it
  fails, they refuse with its reason. A deployment's cold-start hook calls this
  without awaiting, so the runtime starts at once and only the first write or
  read of personal data waits.
  */
  let installWhen = (building: promise<result<provider, string>>) => {
    failed := None
    let waiting = ref(Promise.resolve())
    waiting :=
      building
      ->Promise.thenResolve(result =>
        // A later `install` or `installWhen` replaced this one: it decides.
        if pending.contents->Option.mapOr(false, p => p === waiting.contents) {
          switch result {
          | Ok(provider) => install(provider)
          | Error(why) =>
            failed := Some(why)
            pending := None
          }
        }
      )
      ->Promise.catch(exn => {
        if pending.contents->Option.mapOr(false, p => p === waiting.contents) {
          failed :=
            Some(exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown"))
          pending := None
        }
        Promise.resolve()
      })
    pending := Some(waiting.contents)
  }

  /**
  Whether this deployment requires an encrypting provider: the deploy program
  says so with `REVENTLESS_PII_REQUIRE_ENCRYPTION=true` when it provisions one.
  Then a marked field is never stored as it is: a runtime whose provider failed
  to install, or was never installed, refuses the write instead.
  */
  let isRequired = () =>
    switch requireEncryptionEnv->Nullable.toOption {
    | Some("true") | Some("1") => true
    | _ => false
    }

  /** The installed provider, once any install in flight has settled. */
  let ready = async (): result<provider, error> => {
    switch pending.contents {
    | Some(waiting) => await waiting
    | None => ()
    }
    switch failed.contents {
    | Some(why) =>
      Error(ProviderFailed({message: `the personal-data provider did not install: ${why}`}))
    | None =>
      let provider = current.contents
      if isRequired() && !provider.encrypts {
        Error(
          ProviderFailed({
            message: "this deployment requires an encrypting personal-data provider and none is installed",
          }),
        )
      } else {
        Ok(provider)
      }
    }
  }
}

// ── The seal and open pass ───────────────────────────────────────────────────
//
// Runs on an encoded payload (`{TAG, …fields}` split into its type and fields) at
// the event log's seam: `sealData` before an append, `openData` after a read. Both
// read the schema's markers once per schema and do nothing for a type without
// any, so a log that holds no personal data pays one dictionary lookup.

let fieldsMemo: WeakMap.t<S.t<unknown>, dict<array<(string, marker)>>> = WeakMap.make()

/** The marked fields of `variant` in `schema`, memoized per schema. */
let markedFields = (schema: S.t<'a>, ~variant: string): array<(string, marker)> => {
  let schema = schema->S.castToUnknown
  let byVariant = switch fieldsMemo->WeakMap.get(schema) {
  | Some(d) => d
  | None =>
    let d = Dict.make()
    let _ = fieldsMemo->WeakMap.set(schema, d)
    d
  }
  switch byVariant->Dict.get(variant) {
  | Some(fields) => fields
  | None =>
    let fields = variantFields(schema, ~variant)
    byVariant->Dict.set(variant, fields)
    fields
  }
}

let isPresent = (json: option<JSON.t>) =>
  switch json {
  | None | Some(Null) => false
  | Some(_) => true
  }

/**
`data` with every personal field of `eventType` sealed by the installed provider.
The subject is read off the same payload, or, for an aggregate's field
that names none, is the stream's id the event log passes as `~streamId`. Fails, never degrades: a field whose
subject is missing, or whose key cannot be fetched, is an `Error` and nothing is
appended.
*/
/** The subject of a field in an aggregate's event that names none: the aggregate
    itself. Its id names the stream and is not a field, so the event log hands it
    to `sealData` as `~streamId`. The PPX writes it; kept in step there. */
let streamSubject = "$stream"

/** Seal `fields` of `data` with the installed provider. `label` names the type in
    an error; `~bare` stores a sealed string as its stored form alone, for a store
    whose readers see the type's own field types (a work item served as a
    `String`). */
let sealFields = async (
  ~fields: array<(string, marker)>,
  ~label: string,
  ~streamId: option<string>=?,
  ~bare: bool=false,
  data: dict<JSON.t>,
): result<dict<JSON.t>, error> => {
  // A type without personal fields never waits for, or needs, a provider.
  let provider = fields == [] ? Ok(plain) : await Provider.ready()
  switch provider {
  | Error(e) => Error(e)
  | Ok(provider) if !provider.encrypts || fields == [] => Ok(data)
  | Ok(provider) =>
    let out = data->Dict.copy
    let failure = ref(None)
    for i in 0 to fields->Array.length - 1 {
      let (field, {subject, forgettable}) = fields->Array.getUnsafe(i)
      if failure.contents->Option.isNone && data->Dict.get(field)->isPresent {
        let subjectId =
          subject == streamSubject
            ? streamId
            : data->Dict.get(subject)->Option.flatMap(JSON.Decode.string)
        switch subjectId {
        | None =>
          failure :=
            Some(
              KeyUnavailable({
                subject: subject == streamSubject
                  ? `<no stream id for ${label}>`
                  : `<no ${subject} on ${label}>`,
              }),
            )
        | Some(subjectId) =>
          let value = data->Dict.getUnsafe(field)
          switch await provider.seal(~subject=subjectId, ~field, ~forgettable, value) {
          | Ok(sealed) =>
            out->Dict.set(
              field,
              switch (bare, value, sealed->unwrap) {
              | (true, String(_), Some(form)) => JSON.Encode.string(form)
              | _ => sealed
              },
            )
          | Error(e) => failure := Some(e)
          }
        }
      }
    }
    switch failure.contents {
    | Some(e) => Error(e)
    | None => Ok(out)
    }
  }
}

let sealData = (
  schema: S.t<'a>,
  ~eventType: string,
  ~streamId: option<string>=?,
  data: dict<JSON.t>,
): promise<result<dict<JSON.t>, error>> =>
  sealFields(~fields=markedFields(schema, ~variant=eventType), ~label=eventType, ~streamId?, data)

/** The personal fields of a record type, such as an outbound work item. */
let recordFields = (schema: S.t<'a>): array<(string, marker)> => schema->S.castToUnknown->fieldsOf

/**
A record's personal fields sealed for a store its own readers serve, such as an
outbound work list: a string field holds its bare stored form, so it still reads
as a string. `openRecord` reverses it.
*/
let sealRecord = (schema: S.t<'a>, data: dict<JSON.t>): promise<result<dict<JSON.t>, error>> =>
  sealFields(~fields=recordFields(schema), ~label="the record", ~bare=true, data)

/** Whether `data` holds a stored form `openData` would open: checked first, so a
    read of a log with nothing sealed in it costs no promise per event. */
let needsOpen = (schema: S.t<'a>, ~eventType: string, data: dict<JSON.t>): bool =>
  markedFields(schema, ~variant=eventType)->Array.some(((field, _)) =>
    data->Dict.get(field)->Option.mapOr(false, v => v->unwrap->Option.isSome)
  )

/** The key ids the ciphertext anywhere in `json` names, at any depth. */
let rec keyIdsIn = (json: JSON.t, ~into: array<string>=[]): array<string> => {
  switch json->unwrap->Option.flatMap(parseStored) {
  | Some(Cipher({keyId})) =>
    if !(into->Array.includes(keyId)) {
      into->Array.push(keyId)
    }
  | Some(_) => ()
  | None =>
    switch json {
    | Object(obj) =>
      obj
      ->Dict.valuesToArray
      ->Array.forEach(v => {
        let _ = keyIdsIn(v, ~into)
      })
    | Array(items) =>
      items->Array.forEach(v => {
        let _ = keyIdsIn(v, ~into)
      })
    | _ => ()
    }
  }
  into
}

/**
Make the keys a batch of stored messages needs available to the decoders. Called
once at each entry where a batch arrives, before anything decodes it: the decoders
are synchronous and open with what is at hand. A batch holding no ciphertext asks
the provider nothing.
*/
let prepare = (jsons: array<JSON.t>): promise<result<unit, error>> => {
  let into = []
  jsons->Array.forEach(j => {
    let _ = keyIdsIn(j, ~into)
  })
  if into == [] {
    Promise.resolve(Ok())
  } else {
    Provider.ready()->Promise.then(provider =>
      switch provider {
      | Ok(provider) => provider.prefetch(into)
      // A reader is not refused for a deployment's requirement: a plain provider
      // still opens what it can, and says which forms it cannot.
      | Error(_) if Provider.failed.contents->Option.isNone => Provider.get().prefetch(into)
      | Error(e) => Promise.resolve(Error(e))
      }
    )
  }
}

/** `data` with every stored form of `eventType`'s personal fields opened, with
    the keys at hand: the plain value, or the marker of a value that is gone. */
let openDataNow = (schema: S.t<'a>, ~eventType: string, data: dict<JSON.t>): result<
  dict<JSON.t>,
  error,
> => {
  let fields = markedFields(schema, ~variant=eventType)
  let sealed =
    fields->Array.filter(((field, _)) =>
      data->Dict.get(field)->Option.mapOr(false, v => v->unwrap->Option.isSome)
    )
  if sealed == [] {
    Ok(data)
  } else {
    let provider = Provider.get()
    sealed->Array.reduce(Ok(data->Dict.copy), (acc, (field, _)) =>
      switch acc {
      | Error(_) => acc
      | Ok(out) =>
        provider.openNow(~field, out->Dict.getUnsafe(field))->Result.map(opened => {
          out->Dict.set(field, opened)
          out
        })
      }
    )
  }
}

/** The same, fetching the keys first: for a seam that reads one event at a time. */
let openData = async (schema: S.t<'a>, ~eventType: string, data: dict<JSON.t>): result<
  dict<JSON.t>,
  error,
> =>
  switch await prepare([JSON.Object(data)]) {
  | Error(e) => Error(e)
  | Ok() => openDataNow(schema, ~eventType, data)
  }

/**
A record `sealRecord` stored, opened with the installed provider: each personal
field its plain value, or the marker of a value that is gone (`goneField` names
the first such field). A field still in the clear, written before a provider was
installed, is left as it is.
*/
let openRecord = async (schema: S.t<'a>, data: dict<JSON.t>): result<dict<JSON.t>, error> => {
  let out = data->Dict.copy
  let sealed = []
  recordFields(schema)->Array.forEach(((field, _)) =>
    switch out->Dict.get(field) {
    | Some(String(form)) if form->parseStored->Option.isSome =>
      out->Dict.set(field, wrap(form))
      sealed->Array.push(field)
    | Some(v) if v->unwrap->Option.isSome => sealed->Array.push(field)
    | _ => ()
    }
  )
  if sealed == [] {
    Ok(out)
  } else {
    switch await prepare([JSON.Object(out)]) {
    | Error(e) => Error(e)
    | Ok() =>
      let provider = Provider.get()
      sealed->Array.reduce(Ok(out), (acc, field) =>
        switch acc {
        | Error(_) => acc
        | Ok(out) =>
          provider.openNow(~field, out->Dict.getUnsafe(field))->Result.map(opened => {
            out->Dict.set(field, opened)
            out
          })
        }
      )
    }
  }
}

/** The first personal field of an opened record whose value is gone: its subject
    was erased, or its object forgotten. */
let goneField = (schema: S.t<'a>, data: dict<JSON.t>): option<string> =>
  recordFields(schema)
  ->Array.find(((field, _)) =>
    switch data->Dict.get(field)->Option.flatMap(unwrap) {
    | Some(form) => form == erasedMarker || form == forgottenMarker
    | None => false
    }
  )
  ->Option.map(((field, _)) => field)

/**
A message's event, opened for a decoder: the `{TAG, …fields}` object with its
sealed fields opened, or the message untouched when it holds none. Throws, naming
the event type and the field's error, never the value, when a key is not at hand:
a decoder that read on would either fail or, worse, drop the event.
*/
let openEventNow = (schema: S.t<'a>, json: JSON.t): JSON.t =>
  switch json {
  | Object(obj) =>
    switch obj->Dict.get("TAG") {
    | Some(String(eventType)) if needsOpen(schema, ~eventType, obj) =>
      switch openDataNow(schema, ~eventType, obj) {
      | Ok(opened) => JSON.Object(opened)
      | Error(e) => JsError.throwWithMessage(`cannot open ${eventType}: ${errorMessage(e)}`)
      }
    | _ => json
    }
  | _ => json
  }

/**
The append's last check: with a provider that encrypts installed, the first
personal field of `eventType` that is present and not in a stored form. `None`
when every one is sealed, or when nothing encrypts. Names the field, never the
value.
*/
let unsealedField = (schema: S.t<'a>, ~eventType: string, data: dict<JSON.t>): option<string> =>
  if !Provider.get().encrypts {
    None
  } else {
    markedFields(schema, ~variant=eventType)
    ->Array.find(((field, _)) =>
      switch data->Dict.get(field) {
      | None | Some(Null) => false
      | Some(v) =>
        switch v->unwrap->Option.flatMap(parseStored) {
        | Some(Cipher(_)) | Some(ForgottenForm(_)) | Some(ErasedForm(_)) => false
        | None => true
        }
      }
    )
    ->Option.map(((field, _)) => field)
  }

/** `prepare`, failing the batch when a key cannot be fetched: a reader must not
    read on past a value it cannot open. */
let prepareOrThrow = async (jsons: array<JSON.t>): unit =>
  switch await prepare(jsons) {
  | Ok() => ()
  | Error(e) => JsError.throwWithMessage(`cannot fetch the keys a batch needs: ${errorMessage(e)}`)
  }

/** Whether a batch names any key, checked without waiting: a caller awaits
    `prepareOrThrow` only when it does, so a path that holds no ciphertext keeps
    its timing to the microtask. */
let needsPrepare = (jsons: array<JSON.t>): bool => {
  let into = []
  jsons->Array.forEach(j => {
    let _ = keyIdsIn(j, ~into)
  })
  into != []
}
