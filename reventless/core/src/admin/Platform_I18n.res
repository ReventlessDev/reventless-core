// Where a deployment's catalogues go, how they are merged, and what the shell is told about its
// languages.
//
// Stated once, in core, for the reason `Platform_UiSlots` gives: the AWS deploy and the local
// platform both write `i18n/<lang>.json` beside `config.json` and both write the `languages`
// key, and a platform that spelled either differently would serve catalogues nothing reads.
//
// The merge is per language and key: each source's `<lang>.json` in the order declared, a later
// source winning a key. A deployment lists each plugin's `i18n/` first and its own overrides
// last, so an app can reword a plugin's text without editing the plugin.

/** The `config.json` key naming the languages. */
let configKey = "languages"

/** Where a language's catalogue is served, relative to `config.json`. */
let fileName = (language: string): string => `i18n/${language}.json`

let isTag = (tag: string): bool => {
  let parts = tag->String.split("-")
  parts->Array.length > 0 &&
  parts->Array.every(p => /^[A-Za-z0-9]{1,8}$/->RegExp.test(p)) &&
  /^[A-Za-z]{2,3}$/->RegExp.test(parts->Array.getUnsafe(0))
}

/** The declaration checked, with the default among the offered languages. A mistake is the
    deployment's own and is stated, never repaired silently: a catalogue that is quietly not
    served reads as a translation that does nothing. */
let validate = (i18n: ReventlessInfra.Platform.i18n): result<
  ReventlessInfra.Platform.i18n,
  string,
> =>
  switch Array.concat([i18n.default], i18n.offered)->Array.filter(t => !isTag(t)) {
  | [] =>
    switch i18n.register {
    | Some(r) if r != "Sie" && r != "du" =>
      Error(`i18n: register must be "Sie" or "du", got "${r}"`)
    | _ =>
      Ok({
        ...i18n,
        offered: i18n.offered->Array.includes(i18n.default)
          ? i18n.offered
          : Array.concat([i18n.default], i18n.offered),
      })
    }
  | bad => Error(`i18n: not a language tag: ${bad->Array.join(", ")}`)
  }

/** `config.json`'s `languages`, in the shape the shell reads. */
let configEntry = (i18n: ReventlessInfra.Platform.i18n): (string, JSON.t) => {
  let fields = dict{
    "default": JSON.Encode.string(i18n.default),
    "offered": i18n.offered->Array.map(JSON.Encode.string)->JSON.Encode.array,
  }
  i18n.register->Option.forEach(r => fields->Dict.set("register", JSON.Encode.string(r)))
  (configKey, JSON.Encode.object(fields))
}

/** A source's catalogue for a language, as text: `None` where the source has no file for it. */
type read = (~dir: string, ~language: string) => option<string>

/** One language's merged catalogue as written: keys sorted, two-space indent, a final newline. */
let merged = (i18n: ReventlessInfra.Platform.i18n, ~language: string, ~read: read): result<
  string,
  string,
> => {
  let out = Dict.make()
  let problem = i18n.sources->Array.findMap(dir =>
    switch read(~dir, ~language) {
    | None => None
    | Some(text) =>
      switch text->JSON.parseOrThrow->JSON.Decode.object {
      | Some(entries) =>
        entries->Dict.forEachWithKey((value, key) =>
          value->JSON.Decode.string->Option.forEach(s => out->Dict.set(key, JSON.Encode.string(s)))
        )
        None
      | None => Some(`i18n: ${dir}/${language}.json is not a JSON object`)
      | exception _ => Some(`i18n: ${dir}/${language}.json is not JSON`)
      }
    }
  )
  switch problem {
  | Some(message) => Error(message)
  | None =>
    Ok(
      JSON.stringify(
        out
        ->Dict.toArray
        ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
        ->Dict.fromArray
        ->JSON.Encode.object,
        ~space=2,
      ) ++ "\n",
    )
  }
}

// ── The release gate ──────────────────────────────────────────────────────────

/** A source directory's JSON files as `(file name, text)`; none for a directory that is not. */
let filesIn = (dir: string): array<(string, string)> =>
  switch NodeFs.readdirSyncNames(dir, {}) {
  | names =>
    names
    ->Array.filter(f => f->String.endsWith(".json"))
    ->Array.toSorted(String.compare)
    ->Array.map(f => (f, NodeFs.readFileSync(NodePath.join([dir, f]))))
  | exception _ => []
  }

/** A source's name in a message: the package its `i18n/` sits in. */
let sourceName = (dir: string): string => {
  let base = NodePath.basename(dir)
  base == "i18n" ? NodePath.basename(NodePath.dirname(dir)) : base
}

/**
 What `generate-catalogue check` checks, before a deployment serves its catalogues: in any
 language a text that does not parse or names other placeholders than the English, and in a
 language the last source's `languages.json` releases also a key missing or stale.
 */
let gate = (
  i18n: ReventlessInfra.Platform.i18n,
  ~files: string => array<(string, string)>,
  ~hash: string => string,
): result<unit, string> => {
  module Status = Reventless.CatalogueStatus
  let layers =
    i18n.sources->Array.reduce(Ok([]), (acc, dir) =>
      acc->Result.flatMap(done =>
        Status.layerOf(~name=sourceName(dir), files(dir))->Result.map(l => Array.concat(done, [l]))
      )
    )
  let releases =
    i18n.sources
    ->Array.at(-1)
    ->Option.flatMap(dir =>
      files(dir)->Array.find(((f, _)) => f == "languages.json")->Option.map(Pair.second)
    )
    ->Option.mapOr(Ok(Dict.make()), Status.readReleases)
  switch (layers, releases) {
  | (Error(e), _) | (_, Error(e)) => Error("i18n: " ++ e)
  | (Ok(layers), Ok(releases)) =>
    switch Status.problems(layers, ~releases, ~hash) {
    | [] => Ok()
    | found =>
      Error(
        `i18n: ${found->Array.length->Int.toString} problem(s) in the catalogues:\n` ++
        found
        ->Array.map(p => `  ${p.language}  ${p.layer}  ${p.key}: ${p.reason}`)
        ->Array.join("\n"),
      )
    }
  }
}

/** Every offered language's merged catalogue, as `(file name, text)`, or the first mistake. */
let files = (i18n: ReventlessInfra.Platform.i18n, ~read: read): result<
  array<(string, string)>,
  string,
> =>
  validate(i18n)->Result.flatMap(i18n =>
    i18n.offered->Array.reduce(Ok([]), (acc, language) =>
      acc->Result.flatMap(
        done =>
          merged(i18n, ~language, ~read)->Result.map(
            text => Array.concat(done, [(fileName(language), text)]),
          ),
      )
    )
  )

// ── The server's words ────────────────────────────────────────────────────────

/** A served catalogue's text as its keys and texts; a value that is not a string is skipped. */
let parseCatalogue = (text: string): result<dict<string>, string> =>
  switch text->JSON.parseOrThrow->JSON.Decode.object {
  | Some(entries) =>
    Ok(
      entries
      ->Dict.toArray
      ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
      ->Dict.fromArray,
    )
  | None => Error("a catalogue is not a JSON object")
  | exception _ => Error("a catalogue is not JSON")
  }

/**
 The language to write in for a person's own `locale`: the tag itself where it is offered, else
 its language without the region (`de-DE` → `de`) where that is, else none, and the default
 applies. A register variant is offered as its own tag (`de-x-du`), so it matches as itself.
 */
let offeredFor = (i18n: ReventlessInfra.Platform.i18n, locale: string): option<string> => {
  let offered = Array.concat([i18n.default], i18n.offered)
  let primary = locale->String.split("-")->Array.getUnsafe(0)->String.toLowerCase
  offered
  ->Array.find(tag => tag->String.toLowerCase == locale->String.toLowerCase)
  ->Option.orElse(offered->Array.find(tag => tag->String.toLowerCase == primary))
}

/**
 What a slice formats a message with on a deployment that declared its languages: a recipient
 in their own `locale` where `localeOf` knows it and the deployment offers it, else the declared
 default; and a language's catalogue as `catalogue` fetches it. A language that is not offered
 has none.
 */
let text = (
  i18n: ReventlessInfra.Platform.i18n,
  ~catalogue: string => promise<result<option<dict<string>>, string>>,
  ~localeOf: Reventless.Messaging.recipient => promise<option<string>>=async _ => None,
): Reventless.Text.t => {
  default: i18n.default,
  languageFor: async recipient =>
    (await localeOf(recipient))
    ->Option.flatMap(locale => offeredFor(i18n, locale))
    ->Option.getOr(i18n.default),
  catalogue: async language =>
    Array.concat([i18n.default], i18n.offered)->Array.includes(language)
      ? await catalogue(language)
      : Ok(None),
}

/** The languages as a sending Lambda reads them, `{"default", "offered"}`. */
let languagesJson = (i18n: ReventlessInfra.Platform.i18n): string =>
  JSON.stringify(
    dict{
      "default": JSON.Encode.string(i18n.default),
      "offered": i18n.offered->Array.map(JSON.Encode.string)->JSON.Encode.array,
    }->JSON.Encode.object,
  )

/** The languages `languagesJson` wrote, as a declaration with no sources: what a Lambda knows. */
let languagesOfJson = (text: string): option<ReventlessInfra.Platform.i18n> =>
  switch text->JSON.parseOrThrow->JSON.Decode.object {
  | Some(o) =>
    switch (
      o->Dict.get("default")->Option.flatMap(JSON.Decode.string),
      o->Dict.get("offered")->Option.flatMap(JSON.Decode.array),
    ) {
    | (Some(default), Some(offered)) =>
      Some({default, offered: offered->Array.filterMap(JSON.Decode.string), sources: []})
    | _ => None
    }
  | None => None
  | exception _ => None
  }
