# Plan: a field holds a quantity in its unit, and a price per unit is money

**Date:** 2026-11-19<br/>
**Status:** 📝 Planned. Built so far: the catalogue keeps a unit whole in an identifier's English
(`deliveredKWh` reads *Delivered kWh*), `f3da9ed2f`, 2026-11-19.<br/>
**Part of:** a wider plan that orders this work with the readers of a plugin's schema; this plan
holds core's part, and nothing in it waits on another repo.<br/>
**Facts from:** this repo at `f3da9ed2f`, surveyed 2026-11-19.

## In plain words

A number field often has a unit that only its name says: `deliveredKWh` is energy in
kilowatt-hours, `maxPowerKW` is power in kilowatts. Nothing in its schema says so, so a reader
can neither show the unit, nor convert *1240 kWh* to *1.24 MWh*, nor add up two fields in
different units. A price per unit is worse: `price: float` stands for euro cents per kWh, and the
rule that multiplies it by a session's energy cannot be checked by anyone.

This plan gives such a field a **quantity** and a **unit**: `delivered` holds *energy in kWh*.
The value stays a plain number, so nothing stored changes; the field's schema carries which
quantity and unit it is, the way it already carries money or a duration. A quantity is defined
once, with its units, the factor of each, and its name in words (*kilowatt-hour*).

A **price per unit** is money per a quantity's unit: the value is `Money`, with its currency,
and the field's schema adds *per kWh*. Charging a quantity at a price gives money, with one
rounding to the currency's minor unit, whatever units the two are in.

The steps are **QC1 to QC6**. **QC** stands for *quantities, core*. **QCD** are the decisions,
**QCQ** the open questions.

| Step | What | Size |
|---|---|---|
| QC1 | `Quantity`: a float in a declared quantity and unit, the semantic `quantity` with the unit as its detail, emitted beside `x-reventless-semantic` | M |
| QC2 | The standard set: energy (Wh, kWh, MWh, GWh) and power (W, kW, MW), each unit with its factor and words, listed in `Quantity.standard` | S |
| QC3 | A quantity a plugin declares, built the same way; a standard quantity's name refused | S |
| QC4 | `PricePer`: money per a quantity's unit, the semantic `pricePerUnit`, and `charge` | S–M |
| QC5 | The catalogue: a unit's spelling from the field's schema; keys for a declared quantity's name and units' words | S |
| QC6 | `valueTypes` entries so a tool can write a scenario's value; the semantic types page of the docs | S |

## Steps

### QC1. `Quantity`: a number in its unit

- **The type.** `Reventless.Quantity` declares a quantity as a value:
  `{name: "energy", adds: true, units: [{code: "Wh", factor: 1.0, words: "watt-hour", plural: "watt-hours"}, …]}`,
  the first unit the one factors count from. `adds` says whether two values may be summed:
  energy delivered adds up, a temperature does not. A field's schema is built from a quantity and one
  of its units: `delivered: @s.matches(Reventless.Energy.kWh) float`. The value is a transparent
  `float`, like `Bytes` and `Percent`, so typing an existing field changes nothing stored.
- **The marker.** `Semantic.Id.quantity` (`"quantity"`) with a new payload arm
  `InUnit({quantity: string, unit: string})`. `SuryToJsonSchema` writes it as it writes
  `ReferenceTo` and `IdentityOf`: `x-reventless-semantic: "quantity"`, and the detail in a sibling
  key, `x-reventless-semantic-unit: {quantity, unit}`. The quantity's units and factors are
  published once per plugin in its structure (`pluginStructure.quantities`), not repeated on
  every field.
- **Conversion.** `Quantity.convert(value, ~from, ~to)` by the factors; a unit of another
  quantity is refused.
- **Validation.** Finite; a quantity may be negative (energy fed back into the grid), so the
  sign is the field's own rule, not the type's.

**Tests:** `QuantityTest`: the marker and its sibling key in a view's JSON schema, conversion
both ways, a unit of another quantity refused, `pluginStructure.quantities` listing each quantity
a plugin's fields use once.

### QC2. The standard set

`Reventless.Energy` (Wh, kWh, MWh, GWh) and `Reventless.Power` (W, kW, MW), each unit with its
factor, its words and their plural. `Quantity.standard` lists them, so a tool that reads a
definition knows which quantities need no declaration. These are the quantities a demo needs first; others (length,
mass, volume, temperature) are added the same way when an app needs one
([QCQ2](#open-questions)).

**Tests:** `QuantityTest`: each standard unit converts to the first and back without loss for
whole numbers.

### QC3. A quantity a plugin declares

`Quantity.Make({let name = "volume"; let units = [...]})` gives the same module shape as the
standard ones, so a plugin's own quantity is written and read like energy. Its name must not be
a standard quantity's, and reading the plugin's structure refuses it if it is: a plugin adds
units to the world, it never changes the factor of one that exists.

**Tests:** a plugin declaring `energy` is refused with the reason; a plugin's `volume` appears in
`pluginStructure.quantities`.

### QC4. `PricePer`: money per a quantity's unit

- **The type.** A field holding a price per unit is `Money.t`, built with
  `Reventless.PricePer.unit(Reventless.Energy.kWh)`: the money schema, marked with
  `Semantic.Id.pricePerUnit` and the payload arm `PerUnit({quantity, unit})`, written as
  `x-reventless-semantic-unit` too. The stored value is money's `{amount, currency}`; only the
  schema says *per kWh*.
- **Charging.** `PricePer.charge(price, ~per, quantity, ~in_): result<Money.t, string>`: converts
  the quantity into the price's unit, multiplies, and rounds once to the currency's minor unit
  ([QCQ1](#open-questions)). A quantity of another kind than the price's is refused. `Money.times`
  keeps taking an `int`; the decimal multiplication lives here, where its rounding is said.
- **Converting a price.** `PricePer.convert(price, ~from, ~to)`: 39 ct per kWh is 39,000 ct per
  MWh; the currency never changes.

**Tests:** `PricePerTest`: 12.4 kWh at 39 ct/kWh is 4.84 €; the same energy at a price per MWh
gives the same amount; a price per kW (power) charged with energy is refused; the rounding rule
at a half cent.

### QC5. The catalogue reads the unit from the schema

`generate-catalogue` reads `x-reventless-semantic-unit` on a field. Where the field's words name
one of its quantity's units, that unit is written as spelled from the quantity, not from the
spelling table (which stays for fields with no quantity). For a quantity the plugin declares
([QC3](#qc3-a-quantity-a-plugin-declares)), the catalogue gains a key for its name
(`<Plugin>.quantity.<name>`) and one per unit's words (`<Plugin>.quantity.<name>.unit.<code>`),
so they can be translated. A standard quantity's words are not the plugin's to translate and get
no key.

**Tests:** `CatalogueTest`: a field typed energy in kWh reads its unit from the schema; a
declared quantity's keys are written once per plugin.

### QC6. Value types and the docs

- `Semantic.valueTypes` gains the quantity (`Number`, writer `$value`) and the price per unit
  (money's parts), so a tool that writes a scenario's value knows how; `SemanticValueTypesTest`
  covers both.
- The docs' semantic types page (`packages/doc`) gains *Quantities and their units* and *A price
  per unit*, with the Amperia-like example of energy and a price per kWh.

## Decisions

| # | Decision | Why |
|---|---|---|
| **QCD1** | A quantity value is a plain `float` in the field's declared unit; the unit is in the schema | Units convert by fixed factors, so nothing stored needs the unit, and typing a field changes nothing stored |
| **QCD2** | A price per unit is `Money` with *per unit* in the schema, not a quantity | Its currency does not convert by a factor and its unit does; money's rules (whole minor units, one currency per sum) keep holding |
| **QCD3** | The detail rides in `x-reventless-semantic-unit`, beside the existing marker | One wire format for every semantic, as `ReferenceTo` and `IdentityOf` already do |
| **QCD4** | A plugin adds quantities and never redefines a standard one | A changed factor would change what stored numbers mean |
| **QCD5** | Charging rounds once, at the charge | Rounding a price and then a product drifts by a cent; one rounding is checkable |

## Open questions

Numbered **QCQ1 to QCQ3**, each with a recommendation.

**QCQ1. Which rounding does `charge` use at a half cent?** Banks often round half to even;
invoices in the euro area usually round half away from zero. **Recommendation: half away from
zero**, which is what a person checking an invoice expects, with the rule named in `charge`'s
comment and pinned by a test. Revisit if an app bills in a market whose law says otherwise, and
then take the rule as an argument.

**QCQ2. Which quantities after energy and power?** **Recommendation: none until an app needs
one.** Each is a few lines, and the words of each must be translated by every reader. Length,
mass, volume and temperature are the likely next ones. Revisit when a plugin declares one of them
itself ([QC3](#qc3-a-quantity-a-plugin-declares)), and move it into the standard set.

**QCQ3. Should a quantity field have a sign rule (never negative) in its type?** Energy delivered
is never negative; energy fed back is. **Recommendation: no.** The sign belongs to the field's
decision, which knows the business; the type only says what is measured. Revisit if every app
writes the same rule for the same quantity.

## Verification

- `QuantityTest`, `PricePerTest`, `CatalogueTest` and `SemanticValueTypesTest` pass.
- A view with a field typed energy in kWh emits the marker and its detail in its JSON schema; the
  plugin's structure lists the quantity once.
- The spec suite and `pnpm run build` stay green; a plugin with no quantity emits the same schema
  as before.

## Out of scope

- A value that carries its own unit, until a reader of varying units needs one.
- Quantities built from two others (*km/h*); each is its own quantity for now.
- Exchange rates: a price per unit converts its unit, never its currency.
- How a reader draws a quantity or asks for one: that is the reader's.
