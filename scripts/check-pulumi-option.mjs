#!/usr/bin/env node
// Fail when a Pulumi Output can reach ReScript's generic option combinators.
//
// `Pulumi.Output.t` is an ES6 Proxy that answers any property access with a new
// Output. ReScript's option runtime detects a nested option by probing one
// property, `BS_PRIVATE_NESTED_SOME_NONE` (@rescript/runtime Primitive_option.js):
//
//   some(x)          -> x.BS_PRIVATE_NESTED_SOME_NONE !== undefined
//                       ? {BS_PRIVATE_NESTED_SOME_NONE: x.BS_… + 1 | 0}   // Output + 1 | 0 === 0
//                       : x
//   valFromOption(x) -> same probe, then depth - 1 | 0
//
// The Proxy answers the probe, so both helpers return the sentinel object and the
// Output is gone. Measured against the real @pulumi/pulumi: `some(pulumi.output(
// "real-name"))` yields `{"BS_PRIVATE_NESTED_SOME_NONE":0}` and reads back as None.
//
// What this checks, and why it is two rules rather than one:
//
// Rule 1 is the declaration. `option<Pulumi.Output.t<_>>` is banned repo-wide
// (CLAUDE.md, .claude/rules/component-guidelines.md); this ratchets that rule
// against an allowlist of the sites that already exist, so the population can
// only shrink. Syntactic and exact.
//
// Rule 2 is the hazard itself. Declaring the type is not what corrupts —
// `Output.res` declares `type t<'a> = {}`, an empty *record*, so the compiler
// proves it non-option and construction (`Some(o)`, `{a: o}`, `r := Some(o)`,
// `~x=?o`) emits the bare value with no boxing at all. Only the GENERIC
// combinators corrupt, because inside Stdlib_Option `'a` is a type variable and
// the runtime helpers must run. That is why an `option<Output>` field can sit
// unharmed for years and then break when someone adds one `->Option.map(...)`
// that looks entirely innocuous in review. Rule 2 is the one that catches that.
//
// Rule 2 covers only names declared as `option<Output>` and *never* as an option
// of anything else. That exclusion is load-bearing: the runtime entry points
// carry records with the same field names (`eventTopicArn`, `schedulerRoleArn`)
// typed `option<string>` after JSON/env decoding, where `Option.getOr("")` is
// correct and common. Checking those names repo-wide would report a wall of
// false positives and the check would be turned off. Ambiguous names are listed
// in the output so the gap stays visible rather than silent; Rule 1 still guards
// their declarations.
//
// Plain .mjs rather than ReScript for the same reason as the sibling checks: this
// is untyped reflection over source text, with no domain model for types to earn
// their keep on. It reads `.res` rather than the compiled `.res.mjs` because the
// emitted JS has no types — `Stdlib_Option.getOr(x, "")` looks identical whether
// `x` is an Output or a string.
//
// Usage: pnpm run check:pulumi-option

import { execSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")

// Stdlib_Option members whose compiled body calls Primitive_option.some or
// .valFromOption. Derived by reading the runtime, not by intuition:
//   grep -c 'Primitive_option\.\(some\|valFromOption\)' per function body.
// `orElse`, `isSome` and `isNone` only compare against undefined, so they are
// safe on a Proxy and deliberately absent here.
const UNSAFE = [
  "filter", "forEach", "getOrThrow", "mapOr", "map", "flatMap",
  "getOr", "equal", "compare", "all", "all2", "all3", "all4", "all5", "all6",
]

// Sites that already exist. Each is `<repo-relative file>::<binding name>` —
// keyed by name, not line, so edits above a site do not churn this list.
// Shrink it; never grow it. See docs/analysis/option-field-to-optional-field-inventory.md §4.
const ALLOWLIST = new Set([
  "reventless/aws/src/Platform.res::baseUrl",
  "reventless/aws/src/Platform.res::mergedSchemaPushedRef",
  "reventless/aws/src/Platform.res::storeServingBaseUrl",
  "reventless/aws/src/adapter/Api/AppSync_EventsApi.res::codeHandlersInput",
  "reventless/aws/src/adapter/Api/AppSync_EventsApi.res::handlerConfigsInput",
  "reventless/aws/src/adapter/Api/AppSync_Resolver_Retrying.res::dataSourceName",
  "reventless/aws/src/adapter/DcbEventLog/DcbBackend.res::collectorQueueUrl",
  "reventless/aws/src/adapter/DcbEventLog/DcbBackend.res::collectorQueueArn",
  "reventless/aws/src/adapter/EventLog/EventLogBackend.res::collectorQueueUrl",
  "reventless/aws/src/adapter/EventLog/EventLogBackend.res::collectorQueueArn",
  "reventless/aws/src/adapter/Runtime/AggregateRuntime_Builder_Single.res::pluginRmTableName",
  "reventless/aws/src/adapter/Runtime/AutomationSliceRuntime_Builder_Single.res::dcbQueueUrlRef",
  "reventless/aws/src/adapter/Runtime/StateChangeSliceRuntime_Builder_Single.res::dcbTableName",
  "reventless/aws/src/components/Api/AppSync_Adapter.res::userPoolConfig",
  "reventless/aws/src/plugin/runtime/PluginExtensionPointRuntime_Builder.res::pluginReadModelTableName",
  "reventless/aws/src/plugin/runtime/PluginExtensionPointRuntime_Builder.res::schedulerRoleArn",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::eventTopicArn",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::pluginReadModelTableName",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::schedulerRoleArn",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::schedulerQueueArn",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::schedulerQueueName",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::appSyncApiId",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::dcbTableName",
  "reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res::epQueueUrl",
  "reventless/core/src/adapter/Monitoring/Monitoring.res::logLocator",
  "reventless/core/src/components/Dcb/Dcb_Builder.res::dcbPublishJsons",
  "reventless/core/src/plugin/component/Plugin_Helpers.res::connectPluginExtensionIncomingEventHandler",
  "reventless/core/src/plugin/component/Plugin_Helpers.res::connectPluginExtensionOutputs",
  "reventless/core/src/plugin/component/Plugin_Helpers.res::scheduler",
  "rescript/pulumi-aws/src/IAM/IAM.res::tags",
])

const sources = execSync("git ls-files '*.res' '*.resi'", { cwd: ROOT, encoding: "utf8" })
  .trim()
  .split("\n")
  .filter(Boolean)
  .filter((f) => !f.includes("/layer-builder/"))

// ReScript spells an option two ways, and BOTH must be recognised — the second
// one is why this check reported eight false positives on its first run. The
// runtime entry points declare `pluginReadModelTableName?: string`, and a scanner
// that only knew `name: option<…>` did not see them, so the name looked
// exclusively Output-typed and every `Option.getOr("")` on the string record was
// reported. Optional fields are options; treat them as such.
//
//   name: option<X>   — record field, let binding, ref, labelled argument
//   name?: X          — optional record field, optional labelled argument
//
// Comment lines are dropped first: several of these files discuss
// `option<Pulumi.Output.t<_>>` in prose precisely because it is banned, and prose
// must not register as a site.
const DECL_OPTION = /(?:^|[\s~({,])([a-z_][A-Za-z0-9_']*)\s*:\s*((?:ref<)?option<[^\n]*)/
const DECL_OPTIONAL = /(?:^|[\s~({,])([a-z_][A-Za-z0-9_']*)\s*\?\s*:\s*([^\n]*)/
const isOutput = (type) => /(?:Pulumi\.)?(?:Output|Input)\./.test(type)

// Angle-bracket depth, ignoring the two operators that merely contain a bracket.
// `>=` is deliberately NOT one of them: in ReScript that is a closing bracket
// meeting an argument default (`option<T>=?`, `option<T>=None`), and reading it
// as a comparison leaves the type looking unclosed — which pulls the NEXT
// declaration's type in and reports the wrong name.
const angleDepth = (s) => {
  const t = s.replace(/->|=>/g, "")
  return (t.match(/</g) || []).length - (t.match(/>/g) || []).length
}

// `[^\n]*` is greedy to end of line, so a capture runs past the declaration's
// own type — in `(logGroup: option<LogGroup.t>): option<Pulumi.Input.t<_>>` it
// swallows the RETURN type and reports it against `logGroup`. Cutting at the
// matching close keeps each name judged on its own type. Arrows become spaces
// rather than vanishing, so the slice index still lines up with the input.
const truncateAtClose = (s) => {
  const t = s.replace(/->|=>/g, "  ")
  let depth = 0
  for (let k = 0; k < t.length; k++) {
    if (t[k] === "<") depth++
    else if (t[k] === ">" && --depth === 0) return s.slice(0, k + 1)
  }
  return s
}

// The formatter wraps a long annotation, so a type can span lines:
//
//   let handlerConfigsInput: option<
//     Pulumi.Input.t<ChannelNamespace.handlerConfigsArgs>,
//   > = …
//
// Read one line at a time that captures the bare `option<` and classifies it as
// an option of something else — which loses the site AND poisons
// `namesOtherOption`, silently disabling Rule 2 for the name everywhere. So a
// type left open at end of line pulls in its continuations before classifying;
// only unbalanced types extend, so single-line declarations are untouched.
const declaredType = (lines, i, type) => {
  let joined = type
  for (let j = i + 1; angleDepth(joined) > 0 && j < lines.length && j - i <= 12; j++) {
    joined += " " + lines[j].replace(/\/\/.*$/, "").trim()
  }
  return truncateAtClose(joined)
}

const declaredOutput = new Map() // "file::name" -> {file, name, line}
// Every name seen in a declaration position, however it was classified. This is
// what lets a missing allowlist entry be diagnosed instead of assumed: a name
// still declared here but absent from `declaredOutput` was READ and rejected,
// which is a different event from a name that is gone.
const declaredAny = new Map() // "file::name" -> {file, name, line, type}
const namesOutput = new Set()
const namesOtherOption = new Set()

const noteDeclaration = (file, name, line, type) => {
  const key = `${file}::${name}`
  if (!declaredAny.has(key)) declaredAny.set(key, { file, name, line, type })
}

for (const file of sources) {
  const lines = fs.readFileSync(path.join(ROOT, file), "utf8").split("\n")
  lines.forEach((raw, i) => {
    const line = raw.replace(/\/\/.*$/, "")
    if (/^\s*[*/]/.test(raw)) return // block-comment body

    const opt = DECL_OPTION.exec(line)
    if (opt) {
      const [, name, rawType] = opt
      const type = declaredType(lines, i, rawType)
      noteDeclaration(file, name, i + 1, type)
      if (/option<\s*(?:Pulumi\.)?(?:Output|Input)\./.test(type)) {
        // Rule 1's population: the spelling CLAUDE.md bans.
        declaredOutput.set(`${file}::${name}`, { file, name, line: i + 1 })
        namesOutput.add(name)
      } else {
        namesOtherOption.add(name)
      }
      return
    }

    const optional = DECL_OPTIONAL.exec(line)
    if (optional) {
      const [, name, rawType] = optional
      const type = declaredType(lines, i, rawType)
      noteDeclaration(file, name, i + 1, type)
      // A `name?: NonOutput` declaration is what disambiguates: it proves the
      // name is used for an option of something that is not a Proxy, so Rule 2
      // must not claim it. `name?: Pulumi.Input.t<…>` contributes nothing — it
      // is the idiom of every Pulumi resource-arg record in rescript/pulumi-aws
      // (hundreds, all legitimate), so it neither disambiguates nor belongs in
      // Rule 1, which stays on the one spelling CLAUDE.md bans.
      if (!isOutput(type)) namesOtherOption.add(name)
    }
  })
}

// Rule 2's population: declared as an Output option somewhere and as an option of
// anything else nowhere.
const unambiguous = new Set([...namesOutput].filter((n) => !namesOtherOption.has(n)))
const ambiguous = [...namesOutput].filter((n) => namesOtherOption.has(n)).sort()

// `name->Option.map(`, `x.name->Option.getOr(`, and `Option.map(name`.
const applications = (line, name) => {
  const alt = UNSAFE.join("|")
  return (
    new RegExp(`\\b${name}\\s*->\\s*Option\\.(${alt})\\b`).test(line) ||
    new RegExp(`\\bOption\\.(${alt})\\s*\\(\\s*${name}\\b`).test(line)
  )
}

const newDeclarations = []
const hazards = []

for (const [key, site] of declaredOutput) {
  if (!ALLOWLIST.has(key)) newDeclarations.push(site)
}

for (const file of sources) {
  const lines = fs.readFileSync(path.join(ROOT, file), "utf8").split("\n")
  lines.forEach((raw, i) => {
    const line = raw.replace(/\/\/.*$/, "")
    if (/^\s*[*/]/.test(raw)) return
    for (const name of unambiguous) {
      if (applications(line, name)) hazards.push({ file, name, line: i + 1, src: raw.trim() })
    }
  })
}

// An allowlist entry can fall out of `declaredOutput` two ways, and they call
// for opposite responses — so the check must not report one as the other.
//
//   gone         the name is not declared in that file any more. The ratchet
//                working as designed: the site was removed, so remove the entry.
//
//   unrecognised the declaration is still sitting there, and the scanner read it
//                and did not classify it as `option<Pulumi.Output.t<_>>`.
//
// The second is what a formatter reflow produced here: wrapping a long
// annotation across lines left two live sites unreadable, and — because an
// unclassified name lands in `namesOtherOption` — silently switched Rule 2 off
// for them repo-wide. The old message called both "the site is gone, remove
// them", so following it would have retired two working guards and gone green
// forever. Whatever the scanner actually parsed is printed with the second kind,
// because that string is the evidence for which of the two you are looking at.
const missing = [...ALLOWLIST].filter((k) => !declaredOutput.has(k))
const stale = missing.filter((k) => !declaredAny.has(k))
const unrecognised = missing.filter((k) => declaredAny.has(k)).map((k) => declaredAny.get(k))

let failed = false

if (hazards.length) {
  failed = true
  console.error(`\n${hazards.length} generic option combinator(s) applied to a Pulumi Output:\n`)
  for (const h of hazards) {
    console.error(`  ${h.file}:${h.line}  ${h.name}`)
    console.error(`    ${h.src}`)
  }
  console.error(
    "\nStdlib_Option.map/getOr/flatMap/forEach/… run Primitive_option.some or\n" +
      ".valFromOption over the value; a Pulumi Output answers their nested-option\n" +
      "probe and is replaced by {BS_PRIVATE_NESTED_SOME_NONE: 0} — silently, at\n" +
      "deploy time. Replace with a `switch` (compiles to a plain ternary), or drop\n" +
      "the option: a plain Output.t<string> with \"\" meaning absent.\n",
  )
}

if (newDeclarations.length) {
  failed = true
  console.error(`\n${newDeclarations.length} new option-wrapped Pulumi Output declaration(s):\n`)
  for (const d of newDeclarations) console.error(`  ${d.file}:${d.line}  ${d.name}`)
  console.error(
    "\n`option<Pulumi.Output.t<_>>` is banned repo-wide. Construction is safe, but\n" +
      "the field is then one ->Option.map away from silent corruption and nothing\n" +
      "in the type system says so. Use a plain Output with a sentinel, or the\n" +
      "`hookedValue<'a> = {val: 'a}` wrapper in Plugin_Helpers.res — a plain record\n" +
      "carries no BS_PRIVATE_NESTED_SOME_NONE, so the probe passes it through.\n",
  )
}

if (stale.length) {
  failed = true
  console.error(
    `\n${stale.length} stale allowlist entr(ies) — the name is no longer declared ` +
      `in that file, remove them:\n`,
  )
  for (const k of stale) console.error(`  ${k}`)
  console.error("")
}

if (unrecognised.length) {
  failed = true
  console.error(
    `\n${unrecognised.length} allowlisted site(s) still declared, but no longer ` +
      `read as option<Pulumi.Output.t<_>>:\n`,
  )
  for (const u of unrecognised) {
    console.error(`  ${u.file}:${u.line}  ${u.name}`)
    console.error(`    parsed as: ${u.type}`)
  }
  console.error(
    "\nRead the declaration before touching the allowlist. If the type genuinely\n" +
      "changed, the entry has done its job — drop it. If it still spells\n" +
      "option<Pulumi.Output.t<_>>, this scanner has stopped seeing it: fix the\n" +
      "scanner, because an unclassified name also falls out of Rule 2, so the\n" +
      "->Option.map guard is off for it everywhere until the type parses again.\n" +
      "Deleting the entry here would make that permanent, and green.\n",
  )
}

if (failed) process.exit(1)

console.log(
  `ok ${declaredOutput.size} option-wrapped Outputs, all allowlisted; ` +
    `${unambiguous.size} name(s) checked for unsafe combinators`,
)
if (ambiguous.length) {
  console.log(
    `note: ${ambiguous.length} name(s) also declared as a non-Output option, so not ` +
      `combinator-checked: ${ambiguous.join(", ")}`,
  )
}
