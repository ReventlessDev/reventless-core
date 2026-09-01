/**
A trait's listing metadata, derived rather than written.

The old design had a hand-written `trait.yaml`. Everything in it is already a
fact somewhere typed — the package declares the identity, the trait exports what
it needs, and the emitter's config schema declares what a graft must be told — so
a second copy could only be a place for those to disagree.

## What is here, and what a run has to supply

This is the **static** half: identity, needs, and the config surface. All of it is
readable without running anything, which is what a listing wants before anybody
installs.

The **dynamic** half is `TraitCertificate` — what the suite proved, against a
host. The two are deliberately separate artifacts: a listing carries the manifest
always, and a certificate only once somebody has run the suite, so folding them
together would force a listing to claim a proof it does not have.

## What is deliberately absent

The assertion list. What a trait certifies cannot be enumerated without running
the suite — the assertions are registered by a functor, not declared as data —
so a manifest that listed them would be restating the certificate from memory.
A reader who wants to know what was proved reads a certificate.
*/

/** One field the emitter's config declares. `required` is read off the schema,
    so an optional field cannot be listed as mandatory by a stale hand. */
@schema
type configField = {name: string, required: bool}

@schema
type t = {
  /** The package name — this trait's identity everywhere else too. */
  trait: string,
  version: string,
  description: string,
  license: string,
  /** Platform capabilities a host of this trait must have provisioned, as
      `CapabilityNeed.toString` spells them. **Empty is a statement**, not a
      silence: the attachments trait needs an object *store*, which is declared
      by the field carrying it rather than as a capability, so its empty list is
      the true answer. */
  capabilities: array<string>,
  /** What a graft must be told, from the emitter's own sury-validated config.
      Sorted by name so the file does not churn on a field reordering. */
  config: array<configField>,
  /** Whether the trait ships an emitter at all. A trait whose graft is all
      patches has nothing to write, and a consumer should know that before
      reaching for `graft-trait` and being told. */
  scaffolded: bool,
}

/** Deterministic rendering: 2-space indent, trailing newline. */
let render = (manifest: t): string =>
  JSON.stringify(manifest->Util_Sury.toJson(schema), ~space=2) ++ "\n"

/**
The emitter's config surface, read off its schema.

Introspecting the schema rather than being handed a list is the whole point: a
field added to the config appears here without anyone remembering to say so, and
one renamed cannot linger under its old name.
*/
let configFieldsOf = (schema: S.t<unknown>): array<configField> =>
  switch schema {
  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.map(((name, field)) => {
      name,
      // sury models an optional field as a union with `undefined`, which is how
      // `?` reaches this side. Anything else is required.
      required: switch field {
      | AnyOf({anyOf}) =>
        !(
          anyOf->Array.some(m =>
            switch m {
            | Undefined(_) => true
            | _ => false
            }
          )
        )
      | _ => true
      },
    })
    ->Array.toSorted((a, b) => String.compare(a.name, b.name))
  | _ => []
  }
