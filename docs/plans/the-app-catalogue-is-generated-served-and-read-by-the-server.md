# Plan: the app's catalogue is generated from the plugin structure, served per platform and language, and read by the server's messages (core, waves AW2 and AW3)

**Date:** 2026-11-08
**Status:** 📝 Drafted; nothing built.
**Part of:** the business repo's
[the-app-speaks-the-viewers-language-orchestrator.md](https://github.com/ReventlessLab/reventless-business/blob/HEAD/docs/plans/the-app-speaks-the-viewers-language-orchestrator.md)
(AL8, AL9, AL10, AL13, AL14, AL15, AL16; decisions AD2, AD4, AD5, AD8). The UI kit's half of
the same waves (AL7, AL11) is in the ui repo's plan; wave AW1 (the kit's own words) precedes
this one and nothing here is needed for it.
**Facts from:** this repo at `8636d33`, surveyed 2026-11-08
([the multi-language analysis §13.1](https://github.com/ReventlessLab/reventless-business/blob/HEAD/docs/analysis/multi-language-tooling-and-source.md#131-what-moved-since-october)).

## The gap

A generated app's human-facing words are humanized identifiers in the UI kit and hard-coded
English on the server. `pluginStructure` already publishes everything a catalogue's keys need
(`readSideDef.queryField`, `singleQueryField`, `labelField`; `commandDef.mutationField`; the
error variants of every command's schema; `requiredStoreDeclarations`), but nothing derives
message keys from it, nothing serves a text per language beside `config.json`, and
`Messaging.message` is `{subject?, body}` with no language. Two places still derive names by
the English rule in two copies (`Api_Naming` and the PPX's `Util.ml`), and `@plural` does not
exist. The registration package's challenge and invitation mails
(`reventless/registration/src/Registration/OutboundTranslation/SendRegistrationChallenge_Translation.res`)
are the first server-rendered end-user text, and they are English.

The steps are **CA1 to CA7**. **CA** stands for *core, app catalogue*.

| Step | Orchestrator | What | Size |
|---|---|---|---|
| CA1 | AL8 | `@plural("…")` on a view and on an uploadable field, read by the PPX and `Api_Naming`, published on `readSideDef` and the store declaration | S–M |
| CA2 | AL9 | `generate-catalogue`: message keys from `pluginStructure` into `i18n/en.json`, with the lock file; orphans reported | M |
| CA3 | AL10 | the catalogue served: the local platform emits `i18n/<lang>.json` beside `config.json` the way it emits `ui-hints.json`; the deploy writes `languages` into `config.json` and uploads the merged files | S–M |
| CA4 | AL13 | `i18n status` and `i18n check`: coverage per language and layer, `languages.json` with *draft* and *released*, the release gate | S–M |
| CA5 | AL14 | `Messaging.message` gains `language?`; the recipient's language resolved; the registration mails and `Template` read the compiled catalogue | M |
| CA6 | AL15 | the user pool's `locale` attribute readable and writable for the app client; the claim in the id token | S |
| CA7 | AL16 | the seam for the glossary: the key records its element, the lock file has room for term hashes | S |

## Step CA1 — `@plural("…")`

- **Where it is read.** `packages/reventless-ppx/src/ppx/Vocabulary.ml` gains the attribute; on a
  `@schema type state` of a ReadModel or StateViewSlice it sets the plural the list field and
  plural type are built from, on an uploadable field it sets the store name. The derived rule
  (`Util.pluralize`, `Api_Naming.pluralize`) applies where it is absent, so no existing app
  changes a GraphQL field.
- **Where it is published.** `readSideDef` gains `plural?: string` and `pluralSource: Declared |
  Derived`, next to `labelField` and `labelFieldSource`, which already carry the same shape;
  `requiredStoreDeclarations` gains `annotation` already and names `@plural` there.
- **The two copies stay identical** because both read one declared value first; the derived rule
  keeps its *"if either side changes, change both"* comment. Deleting the copies is the ui plan's
  AL7 on the kit's side and not this repo's.
- **Checks.** A `@plural` that equals the derived plural fails `check:fresh-outputs`'s neighbour
  the way a redundant `@noDcbTag` does: reported, since it says nothing.

## Step CA2 — `generate-catalogue`

- **A bin per app** in `reventless-spec` (`run-generate-catalogue.mjs`, `Reventless.CliArgs` like
  every other bin; usage, `-h`, exit 2 on a usage mistake), run from the platform package, so the
  merge across plugins and the orphan report are per app (orchestrator AQ1).
- **Keys**, one scheme for every reader: `<plugin>.<Element>.<kind>`, with `Element` the
  identifier and `kind` one of `name`, `plural`, `new`, `empty`, `count`, `confirm`, `done`,
  `activity`, `field.<name>`, `state.<Value>`, `error.<Variant>`, `role.<Role>`. The source text
  is the humanized identifier (AD8), the sentences the kit's English patterns filled in, so a
  fresh `en.json` reads exactly as the kit reads today.
- **Idempotent.** A rerun adds new keys, updates a source text only if it is still the text it
  generated last time (the lock file's hash), and reports an orphan rather than deleting it,
  because a rename needs the old key's translations.
- **The lock file** `i18n/<lang>.lock.json`: per key the hash of the source text it was
  translated from; `i18n/<lang>.proposed.json` for text not yet confirmed. Confirming moves a
  proposal into `<lang>.json`; the generator never writes a translation.
- **What it reads.** `pluginStructure` as the baked manifest reads it
  (`reventless/core/src/admin/Platform_BakedManifest.res`), so a plugin that compiles has a
  catalogue, and the GraphQL error enums come from `Spec.errorSchema`'s variants as
  `CommandTopic_Helpers.rejectedResult` names them.

## Step CA3 — the catalogue served

- **Local.** `reventless/local/src/UiHints.res` writes `ui-hints.json` into the directory the
  platform serves and points `config.json` at it. An `I18n.res` beside it does the same for
  `i18n/<lang>.json`: merged from the kit's catalogue (shipped in the host-shell package), each
  plugin's `i18n/` and the app's overrides, in that precedence, and `config.json` gains
  `languages: {default, offered, register?}` from the platform's declaration (the local
  `Platform` options; on AWS the stack's inputs).
- **AWS.** `Util_ShellConfig.res` writes `languages` the way it writes `manifestUrl` and
  `mapStyle`; the stage step (`reventless-ui-stage`, in the ui repo) merges the files into the
  served directory, and the deploy uploads them with the shell. Nothing here is a Lambda's
  concern; the Lambdas get the compiled catalogue in CA5.
- **Watch.** The local platform's `UiHints.watch` re-emits on a change; `I18n` watches the
  app's `i18n/` the same way, so a confirmed German key shows without a restart.

## Step CA4 — `i18n status` and `i18n check`

- Two subcommands of the same bin (`generate-catalogue status`, `… check`), per language and
  per layer (kit, each plugin, app): total, confirmed, proposed, missing, stale, ready.
- `i18n/languages.json` names each offered language *draft* or *released*. `check` fails only
  for a released language with a missing or stale key, for an ICU syntax error
  (`@formatjs/icu-messageformat-parser`) or for placeholders that differ from the source's.
- The platform's deploy runs `check` before it uploads; CI runs it on the examples once the
  online shop has a German catalogue.

## Step CA5 — the server's messages

- `Messaging.message` becomes `{subject?: string, body: string, language?: string}`
  (`reventless/spec/src/semantic/Messaging.res`); a channel that carries a language header
  (e-mail) sets it, the others ignore it, as `subject` is today.
- **The recipient's language** is resolved once, in `reventless/core`: the identity's `locale`
  (CA6), else the platform's default from the same `languages` declaration. A slice that sends
  gets it through its capabilities (`capabilities.messaging.languageFor(recipient)`), so no
  slice reads Cognito.
- **The catalogue in the Lambda.** The compiled `i18n/<lang>.json` of the platform is bundled
  with every Lambda that sends (the registration package's outbound translation, the
  notification trait's sender), and one `Text` module in core formats ICU with the same
  FormatJS runtime the kit uses, so a subject and a body are keys: `registration.challenge.subject`,
  `registration.invited.body`, with the duration and the link as placeholders. `Reventless.Duration.format`
  gains a locale, read from the message's language.
- **`Template.res`** (`reventless/spec/src/semantic/Template.res`) formatters take a locale for
  `money`, `percent`, `bytes`, `duration`, `dateRange`; `raw` stays raw. Its formatter list is
  the semantic vocabulary and does not grow.
- **No display text in events** holds: the catalogue is read at send time; an event records the
  message's key and language, never its text.

## Step CA6 — the identity's `locale`

- `Platform_Stack.res` (`PulumiAws.Cognito.UserPool.make`, line 277 today) declares the standard
  `locale` attribute as mutable and readable and writable for the app client. Standard
  attributes exist on every pool; this changes the client's read and write lists, which is an
  in-place update, not a pool replacement. To be measured first, the way the identity plan
  measured the login identifier, because a replaced pool is emptied.
- The id token then carries `locale`, and the shell reads it (the ui plan's UK4). The local
  platform's accounts carry a `locale` in the same place they carry an e-mail.

## Step CA7 — the seam for the glossary

- A key's entry in the lock file records `element` (plugin, identifier, kind) and leaves a
  `terms: {<term>: hash}` map empty. When the tools' GL1 writes terms into ESDM and the ontology
  plan's ON3 attaches them to the compiled model, a proposal can record which terms it used and
  `status` can count *stale by term*. Nothing else is built here.

## Verification

- `@plural("Statuses")` on a view publishes `plural: "Statuses"`, `pluralSource: Declared`, and
  the list field reads `shop_Statuses`; without it the derived `shop_Statuss` stays, so no
  existing field moves.
- `generate-catalogue` on the online shop writes `i18n/en.json` with one key per view, command,
  field, state, role and error variant, reruns byte-identical, and reports an orphan after a
  rename in a spec.
- The local platform serves `i18n/en.json` and `i18n/de.json` beside `config.json`, `config.json`
  carries `languages`, and a confirmed German key appears without a restart.
- `generate-catalogue check` fails on a released language with one missing key and passes on a
  draft one; it fails on `{count, plural, one {#} }` with a syntax error.
- A registration challenge sent to an account whose `locale` is `de` arrives with a German
  subject and body; one with no `locale` arrives in the platform's default language; the audit
  row records the key and the language, not the text.
- The user pool update that exposes `locale` is a Pulumi `update`, not a `replace`, on the
  alpha stack.
- `pnpm run check:fresh-outputs`, `check:lifecycle`, `check:dcb-scope` and the GWT suites stay
  green.

## Out of scope

The kit's words and switch (wave AW1), the kit's consumption of `singleQueryField` and the
deletion of `Inflect` (AL7), the hint labels through the catalogue (AL11), the tools' glossary
(GL1 to GL8), and any translation written by this repo: every German text is a proposal in the
app's repository, confirmed by a person.
