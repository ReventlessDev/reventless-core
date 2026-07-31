#!/usr/bin/env node
// Generates `src/semantic/Currency.res` from the ISO 4217 table beside this
// script (`iso-4217-list-one.xml`, the standard's own "current currency & funds"
// publication).
//
// Why generated rather than hand-written: the codes and the minor-unit
// exponents have to agree, and the exponent is what makes `Money.format`
// derivable instead of a hardcoded `/100`. Taking both from one source makes
// them agree by construction — nobody has to remember that JPY has no decimals
// and TND has three.
//
// Updating to a newer ISO publication:
//
//     curl -sL https://www.six-group.com/dam/download/financial-information/\
//     data-center/iso-currrency/lists/list-one.xml \
//       -o reventless/spec/scripts/iso-4217-list-one.xml
//     pnpm --filter @reventlessdev/reventless-spec run generate:currency
//
// The output is committed: it is read in review, and a currency appearing or
// disappearing is exactly the kind of change that has to show up in a diff.

import {readFileSync, writeFileSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const source = join(here, 'iso-4217-list-one.xml')
const target = join(here, '..', 'src', 'semantic', 'Currency.res')

const xml = readFileSync(source, 'utf8')

const published = xml.match(/<ISO_4217[^>]*Pblshd="([^"]+)"/)?.[1]
if (!published) throw new Error(`no Pblshd date in ${source} — is this the ISO 4217 list?`)

const field = (entry, tag) => entry.match(new RegExp(`<${tag}>([^<]*)</${tag}>`))?.[1]?.trim()

// One entry per country, so a currency used in several countries repeats. Keyed
// by code; a repeat that disagrees about the exponent is a corrupt table, not
// something to pick a winner from.
const byCode = new Map()
const skipped = []

for (const [, entry] of xml.matchAll(/<CcyNtry>([\s\S]*?)<\/CcyNtry>/g)) {
  const code = field(entry, 'Ccy')
  // Territories with no currency of their own (Antarctica) carry no <Ccy>.
  if (!code) continue
  const minorUnits = field(entry, 'CcyMnrUnts')
  const name = field(entry, 'CcyNm')

  // `N.A.` means the entry has no minor unit at all: the precious metals (XAU,
  // XAG, XPD, XPT), the bond market units (XBA–XBD), XDR, XUA, XSU, the testing
  // code XTS and the "no currency" sentinel XXX. Admitting them would make
  // `exponent` partial, which is the one property this type exists to have — so
  // the standard's own table draws the line rather than a curated opinion. A
  // field holding a weight of gold is not holding money.
  if (!/^\d+$/.test(minorUnits ?? '')) {
    if (!skipped.some(s => s.code === code)) skipped.push({code, name, minorUnits})
    continue
  }

  const exponent = Number(minorUnits)
  const seen = byCode.get(code)
  if (seen && seen.exponent !== exponent) {
    throw new Error(
      `${code} has two exponents in ${source}: ${seen.exponent} and ${exponent}`,
    )
  }
  if (!seen) byCode.set(code, {code, name, exponent})
}

const currencies = [...byCode.values()].sort((a, b) => a.code.localeCompare(b.code))
if (currencies.length < 100) {
  throw new Error(`only ${currencies.length} currencies parsed — the table did not parse`)
}

// The generated file quotes each currency's ISO name beside its constructor, so
// a reviewer reading a three-letter code does not have to look it up.
const constructors = currencies
  .map(c => `  | /** ${c.name} */ ${c.code}`)
  .join('\n')

const exponentArms = currencies
  .map(c => `  | ${c.code} => ${c.exponent}`)
  .join('\n')

const toStringArms = currencies.map(c => `  | ${c.code} => "${c.code}"`).join('\n')

// Wrapped rather than one 1,000-character line, so a code added or removed by a
// future ISO publication shows up as a one-line diff.
const all = currencies
  .map(c => c.code)
  .reduce((lines, code) => {
    const last = lines[lines.length - 1]
    if (last && `${last} ${code},`.length <= 96) lines[lines.length - 1] = `${last} ${code},`
    else lines.push(`  ${code},`)
    return lines
  }, [])
  .join('\n')

const exponentCounts = [...new Set(currencies.map(c => c.exponent))]
  .sort()
  .map(e => `${currencies.filter(c => c.exponent === e).length}×${e}`)
  .join(', ')

const skippedCodes = skipped.map(s => s.code).sort()
const group = codes => codes.filter(c => skippedCodes.includes(c)).join(', ')
const metals = group(['XAG', 'XAU', 'XPD', 'XPT'])
const bondUnits = group(['XBA', 'XBB', 'XBC', 'XBD'])
const rights = group(['XDR', 'XSU', 'XUA'])

const out = `// AUTO-GENERATED from ISO 4217 (published ${published}) — do not edit.
// Run \`pnpm --filter @reventlessdev/reventless-spec run generate:currency\`,
// or see \`scripts/generate-currency.mjs\` to update the source table first.

/**
A currency, closed to the ${currencies.length} codes ISO 4217 defines a minor unit for.

## Why a type and not a three-letter string

A string field invites \`"eur"\` beside \`"EUR"\`, and two spellings of one
currency is a class of bug that reads as a data problem long after it became a
correctness problem — the values are present, and they simply never match. A
closed type makes the second spelling unwritable.

## Why generated, and why every code

The alternative was a curated handful (EUR, USD, GBP, JPY, …), which is small
and readable and wrong the first time an application needs a currency nobody
listed — a compile error in someone else's domain, fixable only by a framework
release. The thing being avoided by curating is ${currencies.length} constructors that are
machine-written and never read in full; the thing being risked is a release.

Generation also buys the property that makes this type worth having: \`exponent\`
comes from the *same* source as the codes, so it cannot drift from them
(${exponentCounts} decimal places across the set). That is what lets
\`Money.format\` derive its decimal placement instead of hardcoding \`/100\`, and
therefore what makes it correct for JPY and TND without anyone remembering that
those two are special.

## What is deliberately absent

The ${skipped.length} entries ISO lists with no minor unit: the precious metals
(${metals}), the bond market units (${bondUnits}), the accounting
units (${rights}), the testing code XTS, and the "no currency"
sentinel XXX. Each would make \`exponent\` partial, and a weight of gold is not
an amount of money. The standard's own table draws that line, so it is not a
curated opinion after all.

## The wire form

A payload-less variant, so the stored and transmitted form is the three-letter
code itself — \`{"amount": 1000, "currency": "EUR"}\`. Standard at the boundary,
a checked type in the domain.
*/
@schema
type t =
${constructors}

/** Every currency, in code order. \`fromString\` is derived from this, so a code
    that parses and a code that exists are the same set by construction. */
let all: array<t> = [
${all}
]

/** The currency's ISO 4217 alphabetic code. */
let toString = (currency: t): string =>
  switch currency {
${toStringArms}
  }

/**
How many decimal places the currency's minor unit is: 2 for EUR, **0 for JPY**,
**3 for TND**, 4 for the Chilean Unidad de Fomento.

Total by construction — this is the whole reason the type is closed and the
table is generated. An amount is stored in integer minor units, so this is the
only thing that says where its decimal point goes.
*/
let exponent = (currency: t): int =>
  switch currency {
${exponentArms}
  }

let byCode: dict<t> = {
  let d = Dict.make()
  all->Array.forEach(c => d->Dict.set(toString(c), c))
  d
}

/**
Parse an ISO 4217 alphabetic code, saying why when it is not one.

Case-sensitive on purpose: \`"eur"\` is rejected rather than repaired. This type
exists because a silent case mismatch is expensive to find, and quietly
accepting the wrong spelling at the boundary would put it back — a producer
sending lowercase codes should learn that at its first request, not at the first
report that two halves of a ledger disagree.
*/
let fromString = (raw: string): result<t, string> =>
  switch byCode->Dict.get(raw) {
  | Some(c) => Ok(c)
  | None =>
    Error(
      \`expected an ISO 4217 currency code such as "EUR", got \${raw
        ->JSON.Encode.string
        ->JSON.stringify}. Codes are upper-case and exactly three letters.\`,
    )
  }
`

writeFileSync(target, out)
console.log(
  `Currency.res: ${currencies.length} currencies (${exponentCounts} decimals), ` +
    `ISO 4217 published ${published}, ${skipped.length} minor-unit-less entries skipped.`,
)
