/***
ICU MessageFormat 1, parsed once and used twice: `generate-catalogue check` reads a text's
placeholders off it, and a server message is formatted from it. One parser, so a text the
check passes is a text the server can format.

Covers what a catalogue holds: simple arguments, `number`, `date`, `time` with or without a
style, `plural`, `selectordinal` and `select` (each needing an `other` case), `offset:`, `#`,
and apostrophe quoting. Formatting goes through the runtime's `Intl`, so no package is added.
*/

type rec part =
  | Literal(string)
  /** `#` inside a plural: the number, less the offset. */
  | Pound
  | Arg(string)
  /** `{name, number}`, `{name, date, short}`: the type and its style or skeleton, if any. */
  | Typed({name: string, kind: string, style?: string})
  | Plural({name: string, ordinal: bool, offset: float, cases: array<(string, t)>})
  | Select({name: string, cases: array<(string, t)>})
and t = array<part>

exception Syntax(string)

/** The message's parts, or why it does not parse, with the character it stopped at. */
let parse = (text: string): result<t, string> => {
  let n = String.length(text)
  let i = ref(0)
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
  // Inside a quote, after its opening apostrophe: `''` is one apostrophe, a lone one closes it.
  let rec quoted = (buffer: array<string>) =>
    switch (at(i.contents), at(i.contents + 1)) {
    | (None, _) => ()
    | (Some("'"), Some("'")) =>
      buffer->Array.push("'")
      i := i.contents + 2
      quoted(buffer)
    | (Some("'"), _) => i := i.contents + 1
    | (Some(ch), _) =>
      buffer->Array.push(ch)
      i := i.contents + 1
      quoted(buffer)
    }
  // At an apostrophe. `''` is one apostrophe; one before a syntax character quotes up to the
  // next lone apostrophe (or the end); anywhere else it is itself.
  let quote = (~inPlural, buffer: array<string>) =>
    switch at(i.contents + 1) {
    | Some("'") =>
      buffer->Array.push("'")
      i := i.contents + 2
    | Some("{") | Some("}") | Some("|") =>
      i := i.contents + 1
      quoted(buffer)
    | Some("#") if inPlural =>
      i := i.contents + 1
      quoted(buffer)
    | _ =>
      buffer->Array.push("'")
      i := i.contents + 1
    }
  let rec message = (~inPlural, ~nested): t => {
    let parts = []
    let buffer = []
    let flush = () =>
      if buffer->Array.length > 0 {
        parts->Array.push(Literal(buffer->Array.join("")))
        buffer->Array.splice(~start=0, ~remove=Array.length(buffer), ~insert=[])
      }
    let rec go = () =>
      switch at(i.contents) {
      | None => nested ? fail("a '{' is not closed") : ()
      | Some("}") => nested ? () : fail("a '}' closes nothing")
      | Some("{") =>
        flush()
        i := i.contents + 1
        parts->Array.push(argument(~inPlural))
        go()
      | Some("'") =>
        quote(~inPlural, buffer)
        go()
      | Some("#") if inPlural =>
        flush()
        parts->Array.push(Pound)
        i := i.contents + 1
        go()
      | Some(ch) =>
        buffer->Array.push(ch)
        i := i.contents + 1
        go()
      }
    go()
    flush()
    parts
  }
  and argument = (~inPlural): part => {
    skipSpace()
    let name = word()
    if name == "" {
      fail("an argument has no name")
    }
    skipSpace()
    switch at(i.contents) {
    | Some("}") =>
      i := i.contents + 1
      Arg(name)
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
        | Some("}") =>
          i := i.contents + 1
          Typed({name, kind})
        | Some(",") =>
          i := i.contents + 1
          let start = i.contents
          style(0)
          Typed({
            name,
            kind,
            style: String.slice(text, ~start, ~end=i.contents - 1)->String.trim,
          })
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
  and cases = (~kind, ~name, ~inPlural): part => {
    skipSpace()
    let offset = ref(0.0)
    if kind != "select" && String.slice(text, ~start=i.contents, ~end=i.contents + 7) == "offset:" {
      i := i.contents + 7
      skipSpace()
      switch word()->Float.fromString {
      | Some(value) => offset := value
      | None => fail(`the ${kind} "${name}" has an offset without a number`)
      }
    }
    let found = []
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
        let body = message(~inPlural, ~nested=true)
        expect("}", "a '{' is not closed")
        found->Array.push((selector, body))
        next()
      }
    }
    next()
    if !(found->Array.some(((selector, _)) => selector == "other")) {
      fail(`the ${kind} "${name}" has no "other" case`)
    }
    kind == "select"
      ? Select({name, cases: found})
      : Plural({name, ordinal: kind == "selectordinal", offset: offset.contents, cases: found})
  }
  try {
    Ok(message(~inPlural=false, ~nested=false))
  } catch {
  | Syntax(reason) => Error(reason)
  }
}

/** The argument names a message uses, sorted and once each. */
let rec namesOf = (message: t, names: Set.t<string>) =>
  message->Array.forEach(part =>
    switch part {
    | Literal(_) | Pound => ()
    | Arg(name) | Typed({name}) => names->Set.add(name)
    | Plural({name, cases}) | Select({name, cases}) =>
      names->Set.add(name)
      cases->Array.forEach(((_, body)) => namesOf(body, names))
    }
  )

/** The argument names a text uses, sorted and once each, or why it does not parse. */
let placeholders = (text: string): result<array<string>, string> =>
  parse(text)->Result.map(message => {
    let names = Set.make()
    namesOf(message, names)
    names->Set.values->Iterator.toArray->Array.toSorted(String.compare)
  })

// ── Formatting ────────────────────────────────────────────────────────────────

/** An argument's value, written the way the message's language writes it. */
type value =
  | Text(string)
  | Number(float)
  | Instant(Date.t)
  /** A length of time, in words: `7 days`, `7 Tage`. */
  | Duration(Duration.t)
  /** Names joined as the language joins them: `A and B`, `A und B`. */
  | List(array<string>)

let numberFormat = (~locale, ~style=?) => {
  let options: Intl.NumberFormat.options = switch style {
  | Some("percent") => {style: #percent}
  | Some("integer") => {maximumFractionDigits: #0}
  | _ => {}
  }
  Intl.NumberFormat.make(~locales=[locale], ~options)
}

let dateFormat = (~locale, ~kind, ~style=?) => {
  let length = switch style {
  | Some("short") => #short
  | Some("long") => #long
  | Some("full") => #full
  | _ => #medium
  }
  let options: Intl.DateTimeFormat.options =
    kind == "time" ? {timeStyle: length} : {dateStyle: length}
  Intl.DateTimeFormat.make(~locales=[locale], ~options)
}

let plainOf = (~locale, value) =>
  switch value {
  | Text(s) => s
  | Number(x) => numberFormat(~locale)->Intl.NumberFormat.format(x)
  | Instant(d) => Intl.DateTimeFormat.make(~locales=[locale])->Intl.DateTimeFormat.format(d)
  | Duration(d) => Duration.format(~locale, d)
  | List(names) =>
    Intl.ListFormat.make(
      ~locales=[locale],
      ~options={\"type": #conjunction, style: #long},
    )->Intl.ListFormat.format(names)
  }

/**
 The message with its arguments filled in for a locale. An argument with no value is written
 as it is in the text (`{name}`), so a missing value shows rather than vanishing; a plural or a
 select without one takes its `other` case.
 */
let format = (message: t, ~locale: string, ~values: dict<value>): string => {
  let out = []
  let rec go = (message: t, ~pound: option<float>) =>
    message->Array.forEach(part =>
      switch part {
      | Literal(s) => out->Array.push(s)
      | Pound =>
        out->Array.push(
          pound->Option.mapOr("#", x => numberFormat(~locale)->Intl.NumberFormat.format(x)),
        )
      | Arg(name) =>
        out->Array.push(values->Dict.get(name)->Option.mapOr(`{${name}}`, plainOf(~locale, ...)))
      | Typed({name, kind, ?style}) =>
        out->Array.push(
          switch (values->Dict.get(name), kind) {
          | (None, _) => `{${name}}`
          | (Some(Number(x)), "number") =>
            numberFormat(~locale, ~style?)->Intl.NumberFormat.format(x)
          | (Some(Instant(d)), "date" | "time") =>
            dateFormat(~locale, ~kind, ~style?)->Intl.DateTimeFormat.format(d)
          | (Some(value), _) => plainOf(~locale, value)
          },
        )
      | Select({name, cases}) =>
        let selector = switch values->Dict.get(name) {
        | Some(Text(s)) => s
        | _ => "other"
        }
        let body =
          cases
          ->Array.find(((case, _)) => case == selector)
          ->Option.orElse(cases->Array.find(((case, _)) => case == "other"))
        body->Option.forEach(((_, body)) => go(body, ~pound))
      | Plural({name, ordinal, offset, cases}) =>
        let other = () => cases->Array.find(((case, _)) => case == "other")
        switch values->Dict.get(name) {
        | Some(Number(x)) =>
          let exact = cases->Array.find(((case, _)) => case == `=${Float.toString(x)}`)
          let rule =
            Intl.PluralRules.make(
              ~locales=[locale],
              ~options={\"type": ordinal ? #ordinal : #cardinal},
            )->Intl.PluralRules.select(x -. offset)
          let body =
            exact
            ->Option.orElse(cases->Array.find(((case, _)) => case == (rule :> string)))
            ->Option.orElse(other())
          body->Option.forEach(((_, body)) => go(body, ~pound=Some(x -. offset)))
        | _ => other()->Option.forEach(((_, body)) => go(body, ~pound=None))
        }
      }
    )
  go(message, ~pound=None)
  out->Array.join("")
}
