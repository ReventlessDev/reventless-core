/***
How far an app's catalogues are translated, and whether a language may be released.

The catalogues come in layers, in the order a platform merges them: each plugin's generated
`i18n/`, then the app's overrides. A key belongs to the first layer whose English has it; its
text in a language is the one the last layer with it supplies, as on screen.

Per language and key, one state:

| state | meaning |
|---|---|
| confirmed | translated, and a reviewer marked it after the English last changed |
| proposed | translated, not reviewed (or never marked, so a change of the English cannot show) |
| missing | no layer has it in this language |
| stale | marked against an English text that has changed since |

A register variant (`de-x-du`) holds only the texts that address the reader and falls back to
its base language (`de`), so a key the base has is not missing in the variant.

`<lang>.lock.json` beside a translation records, per key, the hash of the English it was
written or reviewed against and whether it was reviewed. The English source catalogue's own
lock (`en.lock.json`, from the generator) has another shape and is not read here.
*/

/** The language every catalogue is translated from: the identifiers' language. */
let sourceLanguage = "en"

// ── ICU MessageFormat 1: syntax and placeholders ─────────────────────────────

exception Syntax(string)

/**
 The argument names a message uses, sorted and once each, or why it does not parse.

 Covers the MessageFormat 1 a catalogue holds: simple arguments, `number`, `date`, `time` with
 or without a style, `plural`, `selectordinal` and `select` (each needing an `other` case),
 `offset:`, `#`, and apostrophe quoting.
 */
let placeholders = (text: string): result<array<string>, string> => {
  let n = String.length(text)
  let i = ref(0)
  let names = Set.make()
  let at = j => j < n ? Some(String.charAt(text, j)) : None
  let fail = message => throw(Syntax(`${message} (at character ${Int.toString(i.contents + 1)})`))
  let isSpace = ch => ch == " " || ch == "\n" || ch == "\t" || ch == "\r"
  let rec skipSpace = () =>
    switch at(i.contents) {
    | Some(ch) if isSpace(ch) =>
      i := i.contents + 1
      skipSpace()
    | _ => ()
    }
  let word = () => {
    let start = i.contents
    let rec go = () =>
      switch at(i.contents) {
      | Some(ch) if !isSpace(ch) && ch != "," && ch != "{" && ch != "}" =>
        i := i.contents + 1
        go()
      | _ => ()
      }
    go()
    String.slice(text, ~start, ~end=i.contents)
  }
  let expect = (ch, message) =>
    if at(i.contents) == Some(ch) {
      i := i.contents + 1
    } else {
      fail(message)
    }
  // At an apostrophe. `''` is one apostrophe; one before a syntax character quotes up to the
  // next lone apostrophe (or the end); anywhere else it is itself.
  let rec closeQuote = () =>
    switch (at(i.contents), at(i.contents + 1)) {
    | (None, _) => ()
    | (Some("'"), Some("'")) =>
      i := i.contents + 2
      closeQuote()
    | (Some("'"), _) => i := i.contents + 1
    | _ =>
      i := i.contents + 1
      closeQuote()
    }
  let quote = (~inPlural) =>
    switch at(i.contents + 1) {
    | Some("'") => i := i.contents + 2
    | Some("{") | Some("}") | Some("|") =>
      i := i.contents + 1
      closeQuote()
    | Some("#") if inPlural =>
      i := i.contents + 1
      closeQuote()
    | _ => i := i.contents + 1
    }
  let rec message = (~inPlural, ~nested) =>
    switch at(i.contents) {
    | None => nested ? fail("a '{' is not closed") : ()
    | Some("}") => nested ? () : fail("a '}' closes nothing")
    | Some("{") =>
      i := i.contents + 1
      argument(~inPlural)
      message(~inPlural, ~nested)
    | Some("'") =>
      quote(~inPlural)
      message(~inPlural, ~nested)
    | Some(_) =>
      i := i.contents + 1
      message(~inPlural, ~nested)
    }
  and argument = (~inPlural) => {
    skipSpace()
    let name = word()
    if name == "" {
      fail("an argument has no name")
    }
    names->Set.add(name)
    skipSpace()
    switch at(i.contents) {
    | Some("}") => i := i.contents + 1
    | Some(",") =>
      i := i.contents + 1
      skipSpace()
      let kind = word()
      skipSpace()
      switch kind {
      | "plural" | "selectordinal" | "select" =>
        expect(",", `the ${kind} "${name}" has no cases`)
        cases(~kind, ~name, ~inPlural=inPlural || kind != "select")
      | "number" | "date" | "time" | "spellout" | "ordinal" | "duration" =>
        switch at(i.contents) {
        | Some("}") => i := i.contents + 1
        | Some(",") =>
          i := i.contents + 1
          style(0)
        | _ => fail(`the argument "${name}" is not closed`)
        }
      | "" => fail(`the argument "${name}" has no type after its comma`)
      | other => fail(`the argument "${name}" has an unknown type "${other}"`)
      }
    | _ => fail(`the argument "${name}" is not closed`)
    }
  }
  // A style or skeleton: everything up to the '}' that closes the argument.
  and style = depth =>
    switch at(i.contents) {
    | None => fail("a '{' is not closed")
    | Some("{") =>
      i := i.contents + 1
      style(depth + 1)
    | Some("}") =>
      i := i.contents + 1
      if depth > 0 {
        style(depth - 1)
      }
    | Some(_) =>
      i := i.contents + 1
      style(depth)
    }
  and cases = (~kind, ~name, ~inPlural) => {
    skipSpace()
    if kind != "select" && String.slice(text, ~start=i.contents, ~end=i.contents + 7) == "offset:" {
      i := i.contents + 7
      skipSpace()
      if word() == "" {
        fail(`the ${kind} "${name}" has an offset without a number`)
      }
    }
    let selectors = []
    let rec next = () => {
      skipSpace()
      switch at(i.contents) {
      | None => fail("a '{' is not closed")
      | Some("}") => i := i.contents + 1
      | Some(_) =>
        let selector = word()
        if selector == "" {
          fail(`the ${kind} "${name}" has a case without a selector`)
        }
        skipSpace()
        expect("{", `the case "${selector}" of "${name}" has no message`)
        message(~inPlural, ~nested=true)
        expect("}", "a '{' is not closed")
        selectors->Array.push(selector)
        next()
      }
    }
    next()
    if !(selectors->Array.includes("other")) {
      fail(`the ${kind} "${name}" has no "other" case`)
    }
  }
  try {
    message(~inPlural=false, ~nested=false)
    Ok(names->Set.values->Iterator.toArray->Array.toSorted(String.compare))
  } catch {
  | Syntax(reason) => Error(reason)
  }
}

// ── Layers, marks and languages ───────────────────────────────────────────────

/** What `<lang>.lock.json` keeps per key of a translation; `terms`, the glossary terms a text
    was written from with the hash of each one's translation, is kept as a glossary wrote it. */
type mark = {source: string, confirmed: bool, terms?: dict<string>}

/** One directory of catalogues: `catalogues` and `marks` per language. */
type layer = {name: string, catalogues: dict<dict<string>>, marks: dict<dict<mark>>}

type release = Draft | Released

/** The base a register variant falls back to: `de-x-du` → `de`. */
let baseOf = (language: string): option<string> =>
  switch language->String.indexOf("-x-") {
  | -1 => None
  | at => Some(language->String.slice(~start=0, ~end=at))
  }

/** Every language a layer has a catalogue for or `languages.json` names, the source first. */
let languagesOf = (layers: array<layer>, ~releases: dict<release>): array<string> => {
  let all = Set.make()
  layers->Array.forEach(l =>
    l.catalogues->Dict.keysToArray->Array.forEach(lang => all->Set.add(lang))
  )
  releases->Dict.keysToArray->Array.forEach(lang => all->Set.add(lang))
  all->Set.delete(sourceLanguage)->ignore
  [sourceLanguage, ...all->Set.values->Iterator.toArray->Array.toSorted(String.compare)]
}

/** The English a reader of the key sees: the last layer's that has it. */
let englishOf = (layers: array<layer>): dict<string> => {
  let merged = Dict.make()
  layers->Array.forEach(l =>
    l.catalogues
    ->Dict.get(sourceLanguage)
    ->Option.forEach(c => c->Dict.forEachWithKey((text, key) => merged->Dict.set(key, text)))
  )
  merged
}

/** The layer each key belongs to: the first whose English has it. */
let ownerOf = (layers: array<layer>, key: string): option<string> =>
  layers->Array.findMap(l =>
    l.catalogues
    ->Dict.get(sourceLanguage)
    ->Option.flatMap(c => c->Dict.get(key))
    ->Option.map(_ => l.name)
  )

/** The layer that supplies the key's text in a language, and that text: the last that has it. */
let supplierOf = (layers: array<layer>, ~language, key): option<(layer, string)> =>
  layers
  ->Array.toReversed
  ->Array.findMap(l =>
    l.catalogues->Dict.get(language)->Option.flatMap(c => c->Dict.get(key))->Option.map(t => (l, t))
  )

type state = Confirmed | Proposed | Missing | Stale

type keyStatus = {
  key: string,
  layer: string,
  state: state,
  /** Proposed but never marked: a later change of the English would not show as stale. */
  unmarked: bool,
}

let stateOf = (layers, ~english: dict<string>, ~hash, ~language, key): keyStatus => {
  let layer = ownerOf(layers, key)->Option.getOr("")
  let chain = Array.concat([language], baseOf(language)->Option.mapOr([], b => [b]))
  switch chain->Array.findMap(lang =>
    supplierOf(layers, ~language=lang, key)->Option.map(((l, _)) => (lang, l))
  ) {
  | None => {key, layer, state: Missing, unmarked: false}
  | Some((lang, supplier)) =>
    switch supplier.marks->Dict.get(lang)->Option.flatMap(m => m->Dict.get(key)) {
    | None => {key, layer, state: Proposed, unmarked: true}
    | Some(mark) =>
      let current = english->Dict.get(key)->Option.mapOr("", hash)
      let state = mark.source != current ? Stale : mark.confirmed ? Confirmed : Proposed
      {key, layer, state, unmarked: false}
    }
  }
}

type counts = {
  total: int,
  confirmed: int,
  proposed: int,
  missing: int,
  stale: int,
  unmarked: int,
}

let countOf = (statuses: array<keyStatus>): counts => {
  let count = state => statuses->Array.filter(s => s.state == state)->Array.length
  {
    total: statuses->Array.length,
    confirmed: count(Confirmed),
    proposed: count(Proposed),
    missing: count(Missing),
    stale: count(Stale),
    unmarked: statuses->Array.filter(s => s.unmarked)->Array.length,
  }
}

/** Shown on screen without a fallback: confirmed or proposed. */
let ready = (c: counts): int => c.confirmed + c.proposed

let percent = (c: counts): int =>
  c.total == 0 ? 100 : Float.toInt(Math.floor(Int.toFloat(ready(c) * 100) /. Int.toFloat(c.total)))

type languageStatus = {
  language: string,
  release: release,
  source: bool,
  keys: array<keyStatus>,
  /** Per layer, in merge order; a layer that owns no key is left out. */
  layers: array<(string, counts)>,
  all: counts,
  /** Keys a translation has that no English has: usually a renamed key's old one. */
  unknown: array<string>,
}

let status = (layers: array<layer>, ~releases: dict<release>, ~hash: string => string): array<
  languageStatus,
> => {
  let english = englishOf(layers)
  let keys = english->Dict.keysToArray->Array.toSorted(String.compare)
  languagesOf(layers, ~releases)->Array.map(language => {
    let source = language == sourceLanguage
    let statuses =
      keys->Array.map(key =>
        source
          ? {key, layer: ownerOf(layers, key)->Option.getOr(""), state: Confirmed, unmarked: false}
          : stateOf(layers, ~english, ~hash, ~language, key)
      )
    let unknown =
      layers
      ->Array.flatMap(l =>
        l.catalogues->Dict.get(language)->Option.mapOr([], c => c->Dict.keysToArray)
      )
      ->Array.filter(key => english->Dict.get(key)->Option.isNone)
    {
      language,
      release: releases->Dict.get(language)->Option.getOr(Draft),
      source,
      keys: statuses,
      layers: layers->Array.filterMap(l =>
        switch statuses->Array.filter(s => s.layer == l.name) {
        | [] => None
        | owned => Some((l.name, countOf(owned)))
        }
      ),
      all: countOf(statuses),
      unknown: Set.fromArray(unknown)->Set.values->Iterator.toArray->Array.toSorted(String.compare),
    }
  })
}

// ── The release gate ──────────────────────────────────────────────────────────

type problem = {language: string, layer: string, key: string, reason: string}

/**
 What stops a release. In any language, a text that does not parse or whose placeholders differ
 from the English's; in a released one also a missing or a stale key. A draft language may be
 incomplete, but what it has must render.
 */
let problems = (layers: array<layer>, ~releases: dict<release>, ~hash): array<problem> => {
  let english = englishOf(layers)
  let out = []
  layers->Array.forEach(l =>
    l.catalogues->Dict.forEachWithKey((catalogue, language) =>
      catalogue
      ->Dict.toArray
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
      ->Array.forEach(
        ((key, text)) =>
          switch placeholders(text) {
          | Error(reason) => out->Array.push({language, layer: l.name, key, reason})
          | Ok(names) =>
            switch english->Dict.get(key)->Option.map(placeholders) {
            | Some(Ok(expected)) if language != sourceLanguage && names != expected =>
              out->Array.push({
                language,
                layer: l.name,
                key,
                reason: `its placeholders {${names->Array.join(
                    ", ",
                  )}} are not the English's {${expected->Array.join(", ")}}`,
              })
            | _ => ()
            }
          },
      )
    )
  )
  status(layers, ~releases, ~hash)->Array.forEach(s =>
    if s.release == Released && !s.source {
      s.keys->Array.forEach(k =>
        switch k.state {
        | Missing =>
          out->Array.push({language: s.language, layer: k.layer, key: k.key, reason: "missing"})
        | Stale =>
          out->Array.push({
            language: s.language,
            layer: k.layer,
            key: k.key,
            reason: "stale: the English changed after it was translated",
          })
        | Confirmed | Proposed => ()
        }
      )
    }
  )
  out
}

// ── Marking a translation ────────────────────────────────────────────────────

/** Whether a key is meant by a `--key` pattern: the key itself, or a prefix ending in `*`. */
let matches = (pattern: string, key: string): bool =>
  pattern->String.endsWith("*")
    ? key->String.startsWith(pattern->String.slice(~start=0, ~end=-1))
    : pattern == key

/**
 New marks for a language, per layer name: each translated key's mark set in the layer that
 supplies it, against the English a reader sees now.

 With `~confirmed`, every key the patterns name (all, when there are none) becomes confirmed.
 Without it, a key the patterns name becomes proposed; with no pattern, only keys with no mark
 or a stale one are marked, so a review already recorded is not undone.
 */
let mark = (
  layers: array<layer>,
  ~language: string,
  ~patterns: array<string>,
  ~confirmed: bool,
  ~hash,
): array<(string, dict<mark>)> => {
  let english = englishOf(layers)
  let next =
    layers->Array.map(l => (
      l.name,
      l.marks->Dict.get(language)->Option.mapOr(Dict.make(), Dict.copy),
    ))
  let named = key =>
    switch patterns {
    | [] => true
    | patterns => patterns->Array.some(p => matches(p, key))
    }
  english
  ->Dict.toArray
  ->Array.forEach(((key, text)) =>
    switch supplierOf(layers, ~language, key) {
    | None => ()
    | Some((supplier, _)) =>
      let source = hash(text)
      let marks = next->Array.find(((name, _)) => name == supplier.name)->Option.map(Pair.second)
      marks->Option.forEach(marks => {
        let needed = switch marks->Dict.get(key) {
        | None => true
        | Some(m) => m.source != source
        }
        if named(key) && (confirmed || patterns != [] || needed) {
          let terms = marks->Dict.get(key)->Option.flatMap(m => m.terms)
          marks->Dict.set(key, {source, confirmed, ?terms})
        }
      })
    }
  )
  next
}

// ── The files ─────────────────────────────────────────────────────────────────

let marksText = (marks: dict<mark>): string =>
  JSON.stringify(
    Catalogue.sortedObject(
      marks->Dict.mapValues(m => {
        let fields = dict{
          "source": JSON.Encode.string(m.source),
          "confirmed": JSON.Encode.bool(m.confirmed),
        }
        m.terms->Option.forEach(t =>
          fields->Dict.set("terms", Catalogue.sortedObject(t->Dict.mapValues(JSON.Encode.string)))
        )
        JSON.Encode.object(fields)
      }),
    ),
    ~space=2,
  ) ++ "\n"

let readMarks = (text: string): dict<mark> =>
  try JSON.parseOrThrow(text)
  ->JSON.Decode.object
  ->Option.getOr(Dict.make())
  ->Dict.toArray
  ->Array.filterMap(((key, v)) =>
    v
    ->JSON.Decode.object
    ->Option.flatMap(o =>
      o
      ->Dict.get("source")
      ->Option.flatMap(JSON.Decode.string)
      ->Option.map(
        source => (
          key,
          {
            source,
            confirmed: o
            ->Dict.get("confirmed")
            ->Option.flatMap(JSON.Decode.bool)
            ->Option.getOr(false),
            terms: ?(
              o
              ->Dict.get("terms")
              ->Option.flatMap(JSON.Decode.object)
              ->Option.map(
                t =>
                  t
                  ->Dict.toArray
                  ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
                  ->Dict.fromArray,
              )
            ),
          },
        ),
      )
    )
  )
  ->Dict.fromArray catch {
  | _ => Dict.make()
  }

/** `languages.json`: `{"de": "released", "en": "draft"}`. Anything else is a mistake. */
let readReleases = (text: string): result<dict<release>, string> =>
  switch try Some(JSON.parseOrThrow(text)) catch {
  | _ => None
  } {
  | None => Error("languages.json is not JSON")
  | Some(json) =>
    switch json->JSON.Decode.object {
    | None => Error(`languages.json is not an object of language → "draft" or "released"`)
    | Some(o) =>
      o
      ->Dict.toArray
      ->Array.reduce(Ok(Dict.make()), (acc, (language, value)) =>
        acc->Result.flatMap(releases =>
          switch value->JSON.Decode.string {
          | Some("draft") =>
            releases->Dict.set(language, Draft)
            Ok(releases)
          | Some("released") =>
            releases->Dict.set(language, Released)
            Ok(releases)
          | _ => Error(`languages.json: "${language}" is neither "draft" nor "released"`)
          }
        )
      )
    }
  }

/** A catalogue's file name gives its language: `de.json`, `de-x-du.json`. A tag has no dot, so
    `de.lock.json` and `de.proposed.json`, texts not yet served, are not catalogues. */
let languageOfFile = (file: string): option<string> =>
  switch file->String.endsWith(".json") && file != "languages.json" {
  | false => None
  | true =>
    let language = file->String.slice(~start=0, ~end=-5)
    language->String.includes(".") ? None : Some(language)
  }

/** A layer from its directory's files, as `(file name, text)`: each catalogue, and beside a
    translation its marks. A catalogue that is not JSON is an error naming it. */
let layerOf = (~name: string, files: array<(string, string)>): result<layer, string> => {
  let catalogues = Dict.make()
  let marks = Dict.make()
  let text = file => files->Array.find(((f, _)) => f == file)->Option.map(Pair.second)
  files
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
  ->Array.reduce(Ok(), (acc, (file, content)) =>
    acc->Result.flatMap(() =>
      switch languageOfFile(file) {
      | None => Ok()
      | Some(language) =>
        switch try Some(JSON.parseOrThrow(content)) catch {
        | _ => None
        } {
        | None => Error(`${name}/${file} is not JSON`)
        | Some(_) =>
          catalogues->Dict.set(language, Catalogue.readCatalogue(content))
          if language != sourceLanguage {
            marks->Dict.set(language, readMarks(text(language ++ ".lock.json")->Option.getOr("{}")))
          }
          Ok()
        }
      }
    )
  )
  ->Result.map(() => {name, catalogues, marks})
}
