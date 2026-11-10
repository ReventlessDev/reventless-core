# Plan: the app's catalogue is generated from the plugin structure, served per platform and language, and read by the server's messages

**Date:** 2026-11-08<br/>
**Status:** 🚧 [CA2](#step-ca2--generate-catalogue) and [CA3](#step-ca3--the-catalogue-served) built 2026-11-09;
[CA4](#step-ca4--i18n-status-and-i18n-check) and [CA7](#step-ca7--the-seam-for-a-glossary) built
2026-11-10; [CA1](#step-ca1--plural), [CA5](#step-ca5--the-servers-messages) and
[CA6](#step-ca6--the-identitys-locale) not started.<br/>
**Facts from:** this repo at `8636d33`, surveyed 2026-11-08.

## The gap

A generated app's human-facing words are humanized identifiers on screen and hard-coded English
on the server. `pluginStructure` already publishes everything a catalogue's keys need
(`readSideDef.queryField`, `singleQueryField`, `labelField`; `commandDef.mutationField`; the
error variants of every command's schema; `requiredStoreDeclarations`), but nothing derives
message keys from it, nothing serves a text per language beside `config.json`, and
`Messaging.message` is `{subject?, body}` with no language. Two places still derive names by
the English rule in two copies (`Api_Naming` and the PPX's `Util.ml`), and `@plural` does not
exist. The registration package's challenge and invitation mails
(`reventless/registration/src/Registration/OutboundTranslation/SendRegistrationChallenge_Translation.res`)
are the first server-rendered end-user text, and they are English.

The steps are **CA1 to CA7**. **CA** stands for *core, app catalogue*.

| Step | What | Size |
|---|---|---|
| CA1 | `@plural("…")` on a view and on an uploadable field, read by the PPX and `Api_Naming`, published on `readSideDef` and the store declaration | S–M |
| CA2 | `generate-catalogue`: message keys from `pluginStructure` into `i18n/en.json`, with the lock file; orphans reported | M |
| CA3 | the catalogue served: the local platform emits `i18n/<lang>.json` beside `config.json` the way it emits `ui-hints.json`; the deploy writes `languages` into `config.json` and uploads the merged files | S–M |
| CA4 | `i18n status` and `i18n check`: coverage per language and layer, `languages.json` with *draft* and *released*, the release gate | S–M |
| CA5 | `Messaging.message` gains `language?`; the recipient's language resolved; the registration mails and `Template` read the compiled catalogue | M |
| CA6 | the user pool's `locale` attribute readable and writable for the app client; the claim in the id token | S |
| CA7 | the seam for a glossary: the key records its element, the lock file has room for term hashes | S |

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
  keeps its *"if either side changes, change both"* comment. A consumer that reads the published
  value no longer needs a copy of its own.
- **Checks.** A `@plural` that equals the derived plural fails `check:fresh-outputs`'s neighbour
  the way a redundant `@noDcbTag` does: reported, since it says nothing.

## Step CA2 — `generate-catalogue`

- **Keys**, one scheme for every reader: `<Plugin>.<Element>.<kind>`, with `Element` the
  identifier. The source text is the humanized identifier, so a fresh `en.json` reads exactly as
  the screens read today.
- **Idempotent.** A rerun adds new keys, updates a source text only if it is still the text it
  generated last time (the lock file's hash), and reports an orphan rather than deleting it,
  because a rename needs the old key's translations.
- **The lock file** `i18n/<lang>.lock.json`: per key the hash of the source text it was
  translated from. The generator never writes a translation.

**Built (2026-11-09).** `Reventless.Catalogue` (`reventless/spec/src/i18n/`) turns a
`pluginStructure` into keys and English text and merges a rerun with what is on disk;
`generate-catalogue` (`reventless/local`, beside `emit-capabilities`) applies a composition root
to the local platform, as `emit-capabilities` does, and writes `<plugin>/i18n/en.json` and
`en.lock.json`. On the online shop's ordering plugin: 182 keys, and a rerun reports *current*.

- **Per plugin, in `reventless/local`.** Reading a structure means applying the composition root
  to a platform, which only the local package has. Keys carry the plugin, so merging plugins
  belongs to [CA3](#step-ca3--the-catalogue-served), and orphans are a plugin's own. `--check`
  writes nothing and exits 1 when the files would change.
- **The kinds:** a view's `name` (its singular, from `singleQueryField`, so no second inflection
  rule), `plural`, `count` (an ICU plural), `field.<name>`, `state.<Value>` (the lifecycle
  field's enum); a command's `name` and `field.<name>`; `error.<Variant>` under the write side
  that declares it; and `<Plugin>.role.<Role>` from the admission table and the commands'
  required roles.
- **Not yet:** per-element sentences (*new*, *empty*, *confirm*, *done*, *activity*). German
  needs them where a noun's gender changes the sentence (*Neue Bestellung*, *Neuer Kunde*);
  they are generated once a reader asks for them, not before.
- **The humanizing rule** splits camelCase and separators, keeps a run of capitals together and
  writes known acronyms in capitals (`customerId` → *Customer ID*).
- **The lock file carries [CA7](#step-ca7--the-seam-for-a-glossary)'s seam:** `element` per key
  and an empty `terms`.
- The plugin's name is read off its GraphQL fields (`Ordering_Customers` → `Ordering`); `--plugin`
  names it where none says it.

## Step CA3 — the catalogue served

- **Local.** `reventless/local/src/UiHints.res` writes `ui-hints.json` into the directory the
  platform serves and points `config.json` at it. An `I18n.res` beside it does the same for
  `i18n/<lang>.json`, merged from each plugin's `i18n/` and the app's overrides, in that
  precedence, and `config.json` gains `languages: {default, offered, register?}` from the
  platform's declaration (the local `Platform` options; on AWS the stack's inputs).
- **AWS.** `Util_ShellConfig.res` writes `languages` the way it writes `manifestUrl` and
  `mapStyle`, and the deploy uploads the merged files with the shell. Nothing here is a Lambda's
  concern; the Lambdas get the compiled catalogue in [CA5](#step-ca5--the-servers-messages).
- **Watch.** The local platform's `UiHints.watch` re-emits on a change; `I18n` watches the
  app's `i18n/` the same way, so a confirmed German key shows without a restart.

**Built (2026-11-09).** `hostUiBundleConfig` gains `i18n?: {default, offered, register?,
sources}` (`ReventlessInfra.Platform.i18n`). `ReventlessCore.Platform_I18n` holds the rules
both platforms follow: the default joins the offered languages, a tag that is not one or a
register other than *Sie* or *du* is refused, each offered language's catalogue is the sources'
`<lang>.json` merged in order (a later source winning a key, a missing file skipped), and
`config.json`'s `languages` is `{default, offered, register?}`.

- **Local:** `I18n.emit` writes `i18n/<lang>.json` where the shell is served and removes the
  directory when nothing is declared; `I18n.watch` re-merges when a source file changes;
  `ShellConfig` writes `languages`.
- **AWS:** one `BucketObject` per language beside `config.json`, and `Util_ShellConfig.fields`
  writes `languages`.
- On both, a `shellConfig` that names `languages` while `i18n` is declared is refused, and a
  source that is not JSON stops the boot or the deploy. Without `i18n`, `shellConfig` may still
  name the languages for the shell's own words.
- **Not yet:** an example declaring `i18n`; the examples have no translations, and writing one
  is not this repository's to do.

## Step CA4 — `i18n status` and `i18n check`

- Two subcommands of the same bin (`generate-catalogue status`, `… check`), per language and
  per layer (each plugin, the app): total, confirmed, proposed, missing, stale, ready.
- `i18n/languages.json` names each offered language *draft* or *released*. `check` fails only
  for a released language with a missing or stale key, for an ICU syntax error
  (`@formatjs/icu-messageformat-parser`) or for placeholders that differ from the source's.
- The platform's deploy runs `check` before it uploads; CI runs it on the examples once the
  online shop has a German catalogue.

**Built (2026-11-10).** `Reventless.CatalogueStatus` (`reventless/spec/src/i18n/`) holds the
rules; `generate-catalogue status`, `check` and `mark` apply them to the `<i18nDir>`s given, in
the order the platform merges them.

- **A key's state** in a language: *confirmed* once a reviewer marked it against the English a
  reader sees now, *proposed* while it is translated but not reviewed, *stale* once the English
  changed after the mark, *missing* when no layer has it. A key belongs to the first layer whose
  English has it; its text is the last layer's that has one, as on screen.
- **The marks** are `<lang>.lock.json` beside a translation: per key the hash of the English it
  answers to and whether it was reviewed. `mark <lang>` writes them, `--key` (a key or a prefix
  ending in `*`) and `--confirmed` say which and how. A text with no mark counts as proposed,
  and `status` says how many carry none, since a change of the English cannot show on them.
- **A register variant** (`de-x-du`) holds only the texts that address the reader and falls
  back to its base, so a key the base has is not missing in the variant.
- **`languages.json`** in the last `<i18nDir>` (or `--languages <file>`) names each language
  *draft* or *released*; one it does not name is a draft. A file whose name has a second dot
  (`de.lock.json`, `de.proposed.json`) is not a catalogue.
- **ICU** is checked by a parser of its own for MessageFormat 1, so no package is added: every
  text must parse, and a translation must name the English's placeholders.
- **The gate.** `Platform_I18n.gate` runs the same check over a deployment's declared sources:
  the AWS deploy fails on it before uploading, the local platform logs it and serves anyway, so
  a language that falls behind while the app is worked on does not stop a start.
- **Not yet:** CI on the examples, which have no translations.

## Step CA5 — the server's messages

- `Messaging.message` becomes `{subject?: string, body: string, language?: string}`
  (`reventless/spec/src/semantic/Messaging.res`); a channel that carries a language header
  (e-mail) sets it, the others ignore it, as `subject` is today.
- **The recipient's language** is resolved once, in `reventless/core`: the identity's `locale`
  ([CA6](#step-ca6--the-identitys-locale)), else the platform's default from the same `languages`
  declaration. A slice that sends gets it through its capabilities
  (`capabilities.messaging.languageFor(recipient)`), so no slice reads Cognito.
- **The catalogue in the Lambda.** The compiled `i18n/<lang>.json` of the platform is bundled
  with every Lambda that sends (the registration package's outbound translation, the
  notification trait's sender), and one `Text` module in core formats ICU with FormatJS, so a
  subject and a body are keys: `registration.challenge.subject`, `registration.invited.body`,
  with the duration and the link as placeholders. `Reventless.Duration.format` gains a locale,
  read from the message's language.
- **`Template.res`** (`reventless/spec/src/semantic/Template.res`) formatters take a locale for
  `money`, `percent`, `bytes`, `duration`, `dateRange`; `raw` stays raw. Its formatter list is
  the semantic vocabulary and does not grow.
- **No display text in events** holds: the catalogue is read at send time; an event records the
  message's key and language, never its text.

## Step CA6 — the identity's `locale`

- `Platform_Stack.res` (`PulumiAws.Cognito.UserPool.make`, line 277 today) declares the standard
  `locale` attribute as mutable and readable and writable for the app client. Standard
  attributes exist on every pool; this changes the client's read and write lists, which is an
  in-place update, not a pool replacement. To be measured first, because a replaced pool is
  emptied.
- The id token then carries `locale`, and the shell reads it. The local platform's accounts
  carry a `locale` in the same place they carry an e-mail.

## Step CA7 — the seam for a glossary

- A key's entry in the lock file records `element` (plugin, identifier, kind) and leaves a
  `terms: {<term>: hash}` map empty. Once a model carries terms, a proposal can record which
  terms it used and `status` can count *stale by term*. Nothing else is built here.

**Built (2026-11-10).** The generator's `en.lock.json` has carried `element` and an empty
`terms` since [CA2](#step-ca2--generate-catalogue), and a rerun keeps both. A translation's
`<lang>.lock.json` ([CA4](#step-ca4--i18n-status-and-i18n-check)) may carry `terms` per key as
well, and `mark` keeps them when it marks the key again. Counting *stale by term* waits for a
glossary that writes them.

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

The screens' own words and their language switch, translations of any kind (every German text
is a proposal in the app's repository, confirmed by a person), and where a glossary's terms come
from.
