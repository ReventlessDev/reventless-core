/**
A platform capability a component declares it needs, in the plugin's own
vocabulary.

`Capabilities.t` is what a slice is *handed*; this is what it says it will
reach for. The two are separate because they are read at different times: the
record is injected at run time, the declaration is read at build time by
`emit-capabilities` and at deploy time by the coverage gate, neither of which
can run a `translate`.

**Object stores are not here.** A store need is already declared by the field
that carries `@storageRef`, travels as `pluginStructure.requiredStores`, and is
identified by `(plugin, store)` rather than by a capability alone. This type
carries the needs that no field can express.

A real variant, so a trait exports its need as a value the compiler checks
rather than a string a README repeats.
*/
type t =
  | Geocoding
  | /** Sending a message to a person, reached through `Capabilities.messaging`.
        One need however many channels the platform provisions — which channels
        those are is a runtime answer the provider publishes, not a second
        declaration, because a plugin that named `Sms` would fail a deploy it
        could have run on email. */
  Messaging

/** The spelling carried in `pluginStructure` and in `capabilities.json`.
    Persisted structures hold strings, not enum members, so a plugin built
    against a newer framework still decodes in an older reader. */
let toString = (need: t): string =>
  switch need {
  | Geocoding => "Geocoding"
  | Messaging => "Messaging"
  }

/** The inverse, for readers of a persisted structure or a committed manifest.
    `None` for a capability this build does not know — a newer plugin's need is
    reported as unrecognised, never silently dropped into a known arm. */
let fromString = (name: string): option<t> =>
  switch name {
  | "Geocoding" => Some(Geocoding)
  | "Messaging" => Some(Messaging)
  | _ => None
  }

/** One declared need the deployment does not provision, with the component that
    declared it — a deploy refusal has to name what to go and look at. */
type unmet = {need: t, component: string}

/**
Declared capability needs a platform does not provision.

`declared` is `pluginStructure.requiredCapabilities` as persisted: `(capability,
component)` pairs whose capability is a string, because a structure is replayed
from an event log. A name this build does not recognise is **skipped** — it
belongs to a newer framework, and refusing a deploy over a capability this code
cannot evaluate would be a guess dressed as a check.

Only what was declared. A plugin that declares nothing is unaffected: an
unprovisioned capability it never named degrades exactly as it always has, which
is the modelled outcome for a deployment that simply does not have one.
*/
let unmet = (~declared: array<(string, string)>, ~provisioned: array<t>): array<unmet> =>
  declared->Array.filterMap((((capability, component))) =>
    switch fromString(capability) {
    | Some(need) if !(provisioned->Array.includes(need)) => Some({need, component})
    | _ => None
    }
  )

/** The refusal text: what is missing, who asked for it, and what silently happens
    if it is not provisioned — the symptom is a wrong verdict, never an error. */
let unmetMessage = (unmet: array<unmet>): string =>
  `Plugin declares capabilit(ies) the platform does not provision: ` ++
  `${unmet
    ->Array.map(u => `${toString(u.need)} (${u.component})`)
    ->Array.join(", ")}.\n` ++
  `  Provision them in the platform stack and redeploy the platform first.\n` ++
  `  Without it every call answers Unavailable, the slice exhausts its retries, and a ` ++
  `permanent verdict is recorded against data that is fine — no error anywhere.`
