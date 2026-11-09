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
