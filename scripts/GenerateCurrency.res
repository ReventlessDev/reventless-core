/**
Generates `reventless/spec/src/semantic/Currency.res` from the ISO 4217 table
beside this script (`iso-4217-list-one.xml`, the standard's own "current currency
& funds" publication).

Why generated rather than hand-written: the codes and the minor-unit exponents
have to agree, and the exponent is what makes `Money`'s decimal count derivable
instead of a hardcoded 2. Taking both from one source makes them agree by
construction — nobody has to remember that JPY has no decimals and TND has three.

Only the codes in `active` below become constructors. The rest of the table is
still written out, commented, in every one of the four blocks that mention a
code, so admitting one back is either uncommenting four lines or adding the code
here and re-running — and neither needs the XML re-read or the decision
reconstructed.

Updating to a newer ISO publication:

```
curl -sL https://www.six-group.com/dam/download/financial-information/\
data-center/iso-currrency/lists/list-one.xml \
  -o scripts/iso-4217-list-one.xml
pnpm run generate:currency
```

The output is committed: it is read in review, and a currency appearing or
disappearing is exactly the kind of change that has to show up in a diff.
*/

// ── The curated set ─────────────────────────────────────────────────────────

/**
The currencies the type admits: the five most-traded worldwide (USD, EUR, JPY,
GBP, CNY), the two other majors a global shop meets (AUD, CAD), and the three
European currencies outside the euro that matter most (CHF, NOK, SEK).

JPY earns its place twice over — it is a major currency *and* the only one here
with no decimal place at all, which is what keeps `exponent` load-bearing rather
than a synonym for "two".
*/
let active = ["AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "JPY", "NOK", "SEK", "USD"]

// ── Where things live ───────────────────────────────────────────────────────

// Run from the repo root, which is where pnpm starts a root script.
let repoRoot = NodeProcess.cwd()
let source = NodePath.join([repoRoot, "scripts", "iso-4217-list-one.xml"])
let target = NodePath.join([repoRoot, "reventless", "spec", "src", "semantic", "Currency.res"])

let die = (message: string) => {
  Console.error(message)
  NodeProcess.exit(1)
}

// ── Reading the standard's table ────────────────────────────────────────────

type entry = {code: string, name: string, exponent: int}

let xml = NodeFs.readFileSync(source)

let published = switch RegExp.fromString("<ISO_4217[^>]*Pblshd=\"([^\"]+)\"")->RegExp.exec(xml) {
| Some(result) => result->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x)
| None => None
}

let field = (entry: string, tag: string): option<string> =>
  RegExp.fromString("<" ++ tag ++ ">([^<]*)</" ++ tag ++ ">")
  ->RegExp.exec(entry)
  ->Option.flatMap(result => result->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x))
  ->Option.map(String.trim)

// One entry per country, so a currency used in several countries repeats. Keyed
// by code; a repeat that disagrees about the exponent is a corrupt table, not
// something to pick a winner from.
let byCode: Dict.t<entry> = Dict.make()
let skipped: array<string> = []

let entries = RegExp.fromString("<CcyNtry>([\\s\\S]*?)</CcyNtry>", ~flags="g")
let isWholeNumber = RegExp.fromString("^\\d+$")

let rec readEntries = () =>
  switch entries->RegExp.exec(xml) {
  | None => ()
  | Some(result) =>
    let entry = result->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x)->Option.getOr("")
    switch field(entry, "Ccy") {
    // Territories with no currency of their own (Antarctica) carry no <Ccy>.
    | None => ()
    | Some(code) =>
      let minorUnits = field(entry, "CcyMnrUnts")->Option.getOr("")
      let name = field(entry, "CcyNm")->Option.getOr(code)
      // A non-numeric minor unit means the entry has none at all: the precious
      // metals (XAU, XAG, XPD, XPT), the bond market units (XBA–XBD), XDR, XUA,
      // XSU, the testing code XTS and the "no currency" sentinel XXX. Admitting
      // them would make `exponent` partial, which is the one property this type
      // exists to have — so the standard's own table draws the line rather than
      // a curated opinion. A field holding a weight of gold is not holding money.
      if !(isWholeNumber->RegExp.test(minorUnits)) {
        if !(skipped->Array.includes(code)) {
          skipped->Array.push(code)
        }
      } else {
        let exponent = minorUnits->Int.fromString->Option.getOr(-1)
        switch byCode->Dict.get(code) {
        | Some(seen) if seen.exponent != exponent =>
          die(
            `${code} has two exponents in ${source}: ` ++
            `${seen.exponent->Int.toString} and ${exponent->Int.toString}`,
          )
        | Some(_) => ()
        | None => byCode->Dict.set(code, {code, name, exponent})
        }
      }
    }
    readEntries()
  }

readEntries()

let currencies =
  byCode
  ->Dict.valuesToArray
  ->Array.toSorted((a, b) => String.compare(a.code, b.code))

if currencies->Array.length < 100 {
  die(`only ${currencies->Array.length->Int.toString} currencies parsed — the table did not parse`)
}

switch active->Array.filter(code => byCode->Dict.get(code)->Option.isNone) {
| [] => ()
| missing =>
  die(`\`active\` names ${missing->Array.join(", ")}, which ISO 4217 does not list here`)
}

let admitted = currencies->Array.filter(c => active->Array.includes(c.code))
let dormant = currencies->Array.filter(c => !(active->Array.includes(c.code)))

// ── Emitting ────────────────────────────────────────────────────────────────

// Written with double-quoted strings throughout: what is being emitted is
// ReScript source that contains both backticks and `${…}`, and a template
// literal would have to escape every one of them.

let lines = (xs: array<string>): string => xs->Array.join("\n")

// The dormant half of every block is commented rather than dropped. Uncommenting
// one line in each of the four is the whole restore procedure.
let dormantNote = lines([
  "  // ── Dormant ─────────────────────────────────────────────────────────────",
  "  // The rest of ISO 4217, kept for the day one of them is needed. Uncomment",
  "  // the code here and in the other three blocks — or add it to `active` in",
  "  // scripts/GenerateCurrency.res and regenerate — to admit it.",
])

// The generated file quotes each currency's ISO name beside its constructor, so
// a reviewer reading a three-letter code does not have to look it up.
let constructors = lines(
  Array.concatMany(
    admitted->Array.map(c => "  | /** " ++ c.name ++ " */ " ++ c.code),
    [["", dormantNote], dormant->Array.map(c => "  // | /** " ++ c.name ++ " */ " ++ c.code)],
  ),
)

let toStringArms = lines(
  Array.concat(
    admitted->Array.map(c => "  | " ++ c.code ++ " => \"" ++ c.code ++ "\""),
    dormant->Array.map(c => "  // | " ++ c.code ++ " => \"" ++ c.code ++ "\""),
  ),
)

let exponentArms = lines(
  Array.concat(
    admitted->Array.map(c => "  | " ++ c.code ++ " => " ++ c.exponent->Int.toString),
    dormant->Array.map(c => "  // | " ++ c.code ++ " => " ++ c.exponent->Int.toString),
  ),
)

// Wrapped rather than one long line, so a code admitted or withdrawn shows up as
// a one-line diff.
let pack = (entries: array<entry>, ~prefix: string): string =>
  lines(
    entries->Array.reduce([], (acc, c) => {
      let candidate = switch acc->Array.at(-1) {
      | Some(last) if String.length(last ++ " " ++ c.code ++ ",") <= 96 =>
        Some(last ++ " " ++ c.code ++ ",")
      | _ => None
      }
      switch candidate {
      | Some(extended) => acc->Array.set(acc->Array.length - 1, extended)
      | None => acc->Array.push(prefix ++ c.code ++ ",")
      }
      acc
    }),
  )

let all = lines([pack(admitted, ~prefix="  "), pack(dormant, ~prefix="  // ")])

let exponentCounts =
  admitted
  ->Array.map(c => c.exponent)
  ->Array.reduce([], (acc, e) => acc->Array.includes(e) ? acc : Array.concat(acc, [e]))
  ->Array.toSorted((a, b) => Int.compare(a, b))
  ->Array.map(e =>
    (admitted->Array.filter(c => c.exponent == e)->Array.length)->Int.toString ++
      "×" ++
      e->Int.toString
  )
  ->Array.join(", ")

let out = lines([
  "// AUTO-GENERATED from ISO 4217 (published " ++
  published->Option.getOr("unknown") ++
  ") — do not edit.",
  "// Run `pnpm run generate:currency`, or see `scripts/GenerateCurrency.res` to",
  "// change which codes are admitted or to update the source table first.",
  "",
  "/**",
  "A currency, closed to the " ++
  admitted->Array.length->Int.toString ++
  " codes this framework admits today.",
  "",
  "## Why a type and not a three-letter string",
  "",
  "A string field invites `\"eur\"` beside `\"EUR\"`, and two spellings of one",
  "currency is a class of bug that reads as a data problem long after it became a",
  "correctness problem — the values are present, and they simply never match. A",
  "closed type makes the second spelling unwritable.",
  "",
  "## Why generated, and why a curated set",
  "",
  "Generation buys the property that makes this type worth having: `exponent` comes",
  "from the *same* source as the codes, so it cannot drift from them (" ++
  exponentCounts ++
  " decimal",
  "places across the set). That is what lets `Money` derive how many decimals an",
  "amount may carry instead of hardcoding two, and therefore what makes it correct",
  "for JPY without anyone remembering that JPY is special.",
  "",
  "The set is curated because the whole table is not a choice anyone makes: a picker",
  "holding " ++
  currencies->Array.length->Int.toString ++
  " codes asks a person to find theirs in a list nobody reads, and a",
  "domain that deals in ten does not become more correct for admitting the other " ++
  (currencies->Array.length - admitted->Array.length)->Int.toString ++
  ".",
  "",
  "Every one of those is written out below, commented, in each of the four blocks",
  "that mention a code — so admitting one is uncommenting four lines, or adding it",
  "to `active` in `scripts/GenerateCurrency.res` and regenerating. What a curated",
  "list used to risk was a framework release to fix someone else's compile error;",
  "keeping the rest in the file is what buys that back.",
  "",
  "## What is deliberately absent",
  "",
  "The " ++
  skipped->Array.length->Int.toString ++
  " entries ISO lists with no minor unit at all: the precious metals",
  "(XAG, XAU, XPD, XPT), the bond market units (XBA, XBB, XBC, XBD), the accounting",
  "units (XDR, XSU, XUA), the testing code XTS, and the \"no currency\" sentinel",
  "XXX. Each would make `exponent` partial, and a weight of gold is not an amount",
  "of money. Those are absent from the dormant list too — the standard's own table",
  "draws that line, so it is not a curated opinion after all.",
  "",
  "## The wire form",
  "",
  "A payload-less variant, so the stored and transmitted form is the three-letter",
  "code itself — `{\"amount\": 10.5, \"currency\": \"EUR\"}`. Standard at the boundary,",
  "a checked type in the domain.",
  "*/",
  "@schema",
  "type t =",
  constructors,
  "",
  "/** Every currency the type admits, in code order. `fromString` is derived from",
  "    this, so a code that parses and a code that exists are the same set by",
  "    construction. */",
  "let all: array<t> = [",
  all,
  "]",
  "",
  "/** The currency's ISO 4217 alphabetic code. */",
  "let toString = (currency: t): string =>",
  "  switch currency {",
  toStringArms,
  "  }",
  "",
  "/**",
  "How many decimal places the currency's minor unit is: 2 for EUR, **0 for JPY**.",
  "Among the dormant codes it reaches 3 (TND) and 4 (the Chilean Unidad de",
  "Fomento), which is why nothing here may assume two.",
  "",
  "Total by construction — this is the whole reason the type is closed and the",
  "table is generated. An amount carries exactly this many decimals, so this is the",
  "only thing that says how precise one may be.",
  "*/",
  "let exponent = (currency: t): int =>",
  "  switch currency {",
  exponentArms,
  "  }",
  "",
  "let byCode: dict<t> = {",
  "  let d = Dict.make()",
  "  all->Array.forEach(c => d->Dict.set(toString(c), c))",
  "  d",
  "}",
  "",
  "/**",
  "Parse an ISO 4217 alphabetic code, saying why when it is not one.",
  "",
  "Case-sensitive on purpose: `\"eur\"` is rejected rather than repaired. This type",
  "exists because a silent case mismatch is expensive to find, and quietly",
  "accepting the wrong spelling at the boundary would put it back — a producer",
  "sending lowercase codes should learn that at its first request, not at the first",
  "report that two halves of a ledger disagree.",
  "",
  "A code the standard defines but this type does not admit is rejected the same",
  "way, and the message says so: the caller's next move is to admit it, not to",
  "correct the spelling.",
  "*/",
  "let fromString = (raw: string): result<t, string> =>",
  "  switch byCode->Dict.get(raw) {",
  "  | Some(c) => Ok(c)",
  "  | None =>",
  "    Error(",
  "      `expected one of the ISO 4217 codes this framework admits (${all",
  "        ->Array.map(toString)",
  "        ->Array.join(\", \")}), got ${raw",
  "        ->JSON.Encode.string",
  "        ->JSON.stringify}. Codes are upper-case and exactly three letters.`,",
  "    )",
  "  }",
  "",
])

NodeFs.writeFileSync(target, out)

Console.log(
  `Currency.res: ${admitted->Array.length->Int.toString} currencies admitted ` ++
  `(${exponentCounts} decimals), ${dormant->Array.length->Int.toString} dormant, ` ++
  `ISO 4217 published ${published->Option.getOr("unknown")}, ` ++
  `${skipped->Array.length->Int.toString} minor-unit-less entries skipped.`,
)
