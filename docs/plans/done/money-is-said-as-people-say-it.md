# Plan: money is said as people say it, and counted in minor units inside

**Date:** 2026-11-22<br/>
**Status:** ✅ **Done 2026-11-22.** [MM1 to MM3](#steps) built; core's suites pass (6,493
tests). Where the build differs from the steps below:
- an amount has no more decimals than its currency when it is rounded to minor units and
  saying that count again gives back the same amount; a snap to a millionth of a minor unit
  went wrong past a few billion euros, where the factor overflows a float's exact range;
- `Money.amountDescription` and `Money.isMoney` hold the description and which semantics are
  money, for the API's two writers;
- not yet seen on a running platform: that waits for the release, since an app builds against
  the published packages.<br/>
**Facts from:** this repo at `e44053255`, surveyed 2026-11-22.

> **Questions and short answers**
> - *What is money now?* **What people say: €0.45 is `{amount: 0.45, currency: EUR}`**, in an
>   event, a view's row, a GraphQL argument and result, a webhook body and an MCP tool's input
>   ([MM1](#mm1-money-is-said-as-people-say-it)).
> - *And the whole number of cents?* **It is the count inside, named `minorUnits`**: what a
>   `Money.t` holds in ReScript, so sums stay exact
>   ([MMD1](#decisions)).
> - *What does a caller with too many decimals get?* **A refusal naming the currency's
>   decimals**: €0.455 is no amount ([MMD3](#decisions)).
> - *What has to happen to stored data?* **Stores are wiped**: every stored amount changes its
>   wire form, which an alpha release does ([MMD4](#decisions)).
> - *Who changes with it?* **This repo's examples and tests**
>   ([MM3](#mm3-the-examples-and-tests)), and any client that converted amounts at its own edge:
>   it now sends and shows them as written.

## In plain words

`Money` keeps an amount as a whole number of the currency's smallest unit, and says so on the
wire: `{amount: 45, currency: EUR}` is €0.45. Whole numbers are right for the arithmetic, since
amounts are summed and decimals in floating point do not add up exactly. But the wire form is
what everyone outside reads and writes: a GraphQL mutation that sends `amount: 0.45` is refused,
a webhook door expects cents, a query returns `45`, and the API calls the field a `Float` with no
word about cents. Anyone calling the app has to know the framework's inner unit to say €0.45,
and the word *amount* means two different things inside and out.

This plan makes **money what people say**: `{amount: 0.45, currency: EUR}`, everywhere it is
written down. The whole number becomes the count inside a `Money.t`, named for what it is,
`minorUnits`. `Money`'s schema converts between the two, so every decode counts a said amount in
minor units and every encode says it again: no edge needs a converter of its own, the AWS views
that return rows straight from DynamoDB included.

The steps are **MM1 to MM3**. **MM** stands for *money as meant*. **MMD** are the decisions,
**MMQ** the open questions.

| Step | What | Size |
|---|---|---|
| MM1 | `Money`: said as `{amount, currency}`, counted as `{minorUnits, currency}`; its functions named for which they take | M |
| MM2 | The readers inside this repo: `PricePer`, `Template`, the value-type samples, the API's description of `amount` | S |
| MM3 | The examples and tests say amounts as people do | S–M |

## Steps

### MM1. Money is said as people say it

- **The type.** `Money.t = {minorUnits: float, currency: Currency.t}`. `minorUnits` is a whole
  number (checked, as `amount` is today), a `float` for the same reason as today (an `int` stops
  at €21M).
- **The schema.** The wire shape is `{amount: number, currency}`; `Money.schema` declares it and
  converts to and from the record with sury's `S.to` and a codec, both shapes declared, so sury
  sees what each side holds (no opaque transform: an absent optional value never reaches the
  codec). Decoding counts `amount` in minor units with the currency's exponent, a hair's float
  error snapped first (0.29 × 100); an amount with more decimals than its currency has is
  refused, naming them. Encoding says `minorUnits` divided by the currency's factor. Every reader
  of the schema's shape, the GraphQL SDL, the JSON Schema of the UI's manifest and of MCP tools,
  sees `{amount, currency}`, as people say it, with no change.
- **The functions**, each named for what it takes:
  - `Money.make(~amount, ~currency)`: money as people say it (`10.5` is €10.50), rounded to the
    currency's decimals, half away from zero (today's `ofMajor`);
  - `Money.ofMinorUnits(~minorUnits, ~currency)`: money already counted (today's `make`);
  - `Money.amount(m)`: the amount as people say it (today's `toMajor`);
  - `zero`, `add`, `sum`, `times`, `allocate`, `format`, `compare` keep their names and count in
    `minorUnits`.
  `ofMajor` and `toMajor` go, with no alias.
- **`PricePer`** is `Money.schema` marked, so it follows; `charge` and `rescale` read
  `minorUnits`.

### MM2. The readers inside this repo

- `Template.formatBySemantic` / `localized` read a decoded `Money.t` and say
  `Money.amount(m)`.
- `Semantic.valueTypes`' samples and writers say money as people do:
  `Reventless.Money.make(~amount=10.0, ~currency=Reventless.Currency.EUR)`.
- A price per unit is the shared GraphQL type `Money` too (`SchemaType.semanticCompositeNames`):
  it is money in shape, and its unit stays in the JSON Schema's semantic, where readers find it.
- `GraphQL_FragmentGenerator` writes a description on the `amount` of the `Money` type and its
  input, and `SuryToJsonSchema` the same as the `amount`'s `description` in a money node: *The
  amount of money as people say it: 0.45 EUR is forty-five cents. At most as many decimals as the
  currency has.*

### MM3. The examples and tests

- The online shop: its seed plays (`traffic.yaml`, `order-placed-once.yaml`) write `19.99`;
  `DemoCommands.money` sends `Money.amount`; `ShopSnapshot.moneyOf` reads a row's amount with
  `Money.make`; `DemoData` reprices in `minorUnits`; its GWT scenarios and examples write
  amounts as people say them in their JSON, and `Money.make` / `Money.ofMinorUnits` in code.
- Core's own tests (`MoneyTest`, `PricePerTest`, `TemplateTest`, the outbound translation and
  event mapper fixtures, the seed's) the same.
- A frozen corpus of stored events that holds money is written again: its wire form changed.

## Decisions

| # | Decision | Why |
|---|---|---|
| **MMD1** | Money is `{amount, currency}` as people say it wherever it is written down; the whole number is `minorUnits`, inside a `Money.t` only | The word *amount* means what people mean everywhere; sums still run on whole numbers, which is why minor units were chosen |
| **MMD2** | The schema converts, not each edge | Every decode and encode goes through the schema, so GraphQL, doors, MCP, projections and the AWS views that return rows straight from DynamoDB all speak one way with no code of their own |
| **MMD3** | An amount with more decimals than its currency has is refused when decoded; `Money.make` in code rounds | A caller's amount is never changed without telling them; code that computes a price rounds once, as `ofMajor` did |
| **MMD4** | No upcaster: stored amounts change their wire form, and stores are wiped | The framework is in alpha and its deployed stores are wiped for this release |
| **MMD5** | The amount on the wire is a JSON number | It is what a caller of a JSON API writes; decoding snaps and checks it against the currency, so a float's error never reaches a sum, and a JSON number round-trips every amount below 2^53 minor units |

## Open questions

Numbered **MMQ1** only, with a recommendation.

**MMQ1. Does a stored amount read back exactly?** An event holds `0.45`, a `float` printed as
JSON. **Recommendation: yes, and a test says so:** an amount is encoded from whole minor units by
one division, JSON prints the shortest decimal that reads back as the same `float`, and decoding
multiplies, snaps and rounds; every whole number of minor units up to 2^53 comes back as itself.

## Acceptance

- On a local platform, `Charging_AddSite(price: {amount: 0.45, currency: EUR})` is accepted,
  the sites view returns `0.45`, the stored event holds `0.45`, the decision counts 45, and
  `0.455` is refused naming EUR's 2 decimals.
- A webhook door and an MCP tool take `0.45` the same way.
- The online shop's plays and tests pass.
- The suites stay green.
