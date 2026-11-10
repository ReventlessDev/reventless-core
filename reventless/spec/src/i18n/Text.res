/***
A server's words in the recipient's language: the capability a slice formats a message
through, so no slice reads a catalogue file or an identity's locale itself.

A message is a key and the English it falls back to, written in code beside the code that
sends it, so a deployment that declares no catalogue still sends something readable. The text
is looked up along one chain: the language asked for, its base (`de-x-du` → `de`), the
platform's default, then that English.

What is recorded about a sent message is its key and language, never its text: the text is
the catalogue's, and the catalogue changes.
*/

/** A message a server sends: its key in the catalogue and the English it falls back to, in
    ICU MessageFormat. */
type message = {key: string, source: string}

/** The catalogue's language for the English a message is written in. */
let sourceLanguage = CatalogueStatus.sourceLanguage

type t = {
  /** The language a deployment writes in where nothing says otherwise. */
  default: string,
  /** The language to write to this recipient in: the one their account says where they have
      one, else `requested` (the language a request was made in, for a person with no account
      yet), else `default` — each only where the deployment offers it. */
  languageFor: (Messaging.recipient, ~requested: string=?) => promise<string>,
  /** A language's catalogue: `Ok(None)` where the deployment has none for it, `Error` where
      it could not be read, so the send is tried again rather than made in another language. */
  catalogue: string => promise<result<option<dict<string>>, string>>,
}

/** A deployment with no catalogue: every message in the English it is written in. */
let sourceOnly: t = {
  default: sourceLanguage,
  languageFor: async (_, ~requested as _=?) => sourceLanguage,
  catalogue: async _ => Ok(None),
}

/**
 The language to write in for a tag a person or a request gave: the tag itself where it is
 offered, else its language without the region (`de-AT` → `de`) where that is, else none. A
 register variant is offered as its own tag (`de-x-du`), so it matches as itself.
 */
let offeredFor = (~offered: array<string>, tag: string): option<string> => {
  let primary = tag->String.split("-")->Array.getUnsafe(0)->String.toLowerCase
  offered
  ->Array.find(o => o->String.toLowerCase == tag->String.toLowerCase)
  ->Option.orElse(offered->Array.find(o => o->String.toLowerCase == primary))
}

/** The language for a recipient whose own `locale` is `own`, asked for in `requested`: the first
    of the two the deployment offers, else `default`. */
let choose = (~offered, ~default, ~own: option<string>, ~requested: option<string>): string =>
  own
  ->Option.flatMap(tag => offeredFor(~offered, tag))
  ->Option.orElse(requested->Option.flatMap(tag => offeredFor(~offered, tag)))
  ->Option.getOr(default)

/** A deployment whose catalogues are at hand, by language: the languages it has catalogues
    for are the ones it offers. `localeOf` is a recipient's own language, where they have one. */
let fromCatalogues = (
  ~default: string,
  ~localeOf: Messaging.recipient => promise<option<string>>=async _ => None,
  catalogues: dict<dict<string>>,
): t => {
  default,
  languageFor: async (recipient, ~requested=?) =>
    choose(
      ~offered=Array.concat([default], catalogues->Dict.keysToArray),
      ~default,
      ~own=await localeOf(recipient),
      ~requested,
    ),
  catalogue: async language => Ok(catalogues->Dict.get(language)),
}

/** A message in the English it is written in, its values filled in: what a deployment with no
    catalogue sends. */
let inSource = (message: message, ~values: dict<MessageFormat.value>=Dict.make()): string =>
  switch MessageFormat.parse(message.source) {
  | Ok(parsed) => parsed->MessageFormat.format(~locale=sourceLanguage, ~values)
  | Error(_) => message.source
  }

/** A message's text: what it says, the language it says it in, and its key. */
type text = {key: string, language: string, text: string}

let chainOf = (t: t, language: string): array<string> =>
  [Some(language), CatalogueStatus.baseOf(language), Some(t.default)]
  ->Array.filterMap(x => x)
  ->Array.reduce([], (seen, l) => seen->Array.includes(l) ? seen : Array.concat(seen, [l]))

/**
 A message in a language, its values filled in. The first language along the chain whose
 catalogue has the key and whose text parses supplies it; the English in code is the last
 resort. `Error` only where a catalogue could not be read.
 */
let format = async (
  t: t,
  message: message,
  ~language: string,
  ~values: dict<MessageFormat.value>=Dict.make(),
): result<text, string> => {
  let rec along = async (languages: list<string>) =>
    switch languages {
    | list{} =>
      switch MessageFormat.parse(message.source) {
      | Ok(parsed) =>
        Ok({
          key: message.key,
          language: sourceLanguage,
          text: parsed->MessageFormat.format(~locale=sourceLanguage, ~values),
        })
      | Error(reason) => Error(`${message.key}: the English does not parse: ${reason}`)
      }
    | list{language, ...rest} =>
      switch await t.catalogue(language) {
      | Error(reason) => Error(reason)
      | Ok(catalogue) =>
        switch catalogue
        ->Option.flatMap(c => c->Dict.get(message.key))
        ->Option.map(MessageFormat.parse) {
        | Some(Ok(parsed)) =>
          Ok({
            key: message.key,
            language,
            text: parsed->MessageFormat.format(~locale=language, ~values),
          })
        | Some(Error(_)) | None => await along(rest)
        }
      }
    }
  await along(chainOf(t, language)->List.fromArray)
}

/**
 A subject and a body for a recipient, in their language; `requested` is the language the
 request that occasioned it was made in, for a recipient with no account to say. The message
 carries the body's language, which is the one a mail is labeled with.
 */
let compose = async (
  t: t,
  ~recipient: Messaging.recipient,
  ~requested: option<string>=?,
  ~subject: message,
  ~body: message,
  ~values: dict<MessageFormat.value>=Dict.make(),
): result<Messaging.message, string> => {
  let language = await t.languageFor(recipient, ~requested?)
  switch await format(t, subject, ~language, ~values) {
  | Error(reason) => Error(reason)
  | Ok(subject) =>
    switch await format(t, body, ~language, ~values) {
    | Error(reason) => Error(reason)
    | Ok(body) => Ok({subject: subject.text, body: body.text, language: body.language})
    }
  }
}

/** A catalogue as the English its messages are written in: what a package ships as
    `i18n/en.json`, so a translator has the keys to translate. */
let englishOf = (messages: array<message>): dict<string> =>
  messages->Array.map(m => (m.key, m.source))->Dict.fromArray
