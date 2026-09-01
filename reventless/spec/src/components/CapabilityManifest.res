/**
The per-plugin capability manifest — `capabilities.json`, written beside the
generated `Plugin.res` by the plugin package's build.

Each entry states one capability the plugin declares it needs, keyed by that
capability's identity — the qualified `{plugin}.{store}` for an object store, the
capability's own name for everything else — with the declaring sites as
provenance. The keys are taken verbatim from `pluginStructure`: the manifest is a
rendering of the structure, never a second scan of the sources, so the two cannot
spell one fact differently.

The platform generator unions these files across a deployment's plugins and
emits the platform's capability list from them.
*/

@schema
type kind =
  | ObjectStore
  /** Address geocoding, reached through `Capabilities.geocode`. Declared by a
      slice rather than by a field, so its entry carries no `field`. */
  | Geocoding

/** The declaration site: the component's spec name, and — for a store — the field
    carrying the `@storageRef` annotation plus the store exactly as that field
    spells it.

    `field` and `annotation` are optional. `annotation` because a manifest emitted
    before it existed must still parse, and a reader that cannot say what the
    source says omits the claim rather than inventing one; `field` because a
    capability a slice declares has no declaring field, and naming one would be a
    fiction. Every store entry emitted now carries both. */
@schema
type provenance = {component: string, field?: string, annotation?: string}

@schema
type entry = {
  kind: kind,
  key: string,
  declaredBy: array<provenance>,
}

@schema
type t = {capabilities: array<entry>}

/**
Build the manifest from a plugin's structure.

Store keys iterate `requiredStores` itself, so a manifest's key set is
byte-identical to what the deployed plugin reports at runtime — the contract the
deploy-time coverage assertion checks against. Capability entries follow, one per
distinct capability, ordered by name so the file does not churn. A structure with
no declarations yields an empty `capabilities` list, not an absent file:
"declares nothing" is a statement, and the generator reading the manifests must
be able to tell it apart from "was never built".
*/
let fromStructure = (structure: Plugin.pluginStructure): t => {
  let declarations = structure.requiredStoreDeclarations->Option.getOr([])
  let stores =
    structure.requiredStores
    ->Option.getOr([])
    ->Array.map(key => {
      kind: ObjectStore,
      key,
      declaredBy: declarations->Array.filterMap(d =>
        d.store == key
          ? Some({component: d.component, field: d.field, annotation: ?d.annotation})
          : None
      ),
    })
  let needs = structure.requiredCapabilities->Option.getOr([])
  let capabilityKeys =
    needs->Array.map(d => d.capability)->Belt.Set.String.fromArray->Belt.Set.String.toArray
  let capabilities = capabilityKeys->Array.filterMap(key =>
    // An unrecognised capability is dropped rather than passed through: the
    // generator downstream renders a real `Platform.capability` arm, and a name
    // this build cannot map has no arm to render.
    CapabilityNeed.fromString(key)->Option.map(need => {
      kind: switch need {
      | Geocoding => Geocoding
      },
      key,
      declaredBy: needs->Array.filterMap(d =>
        d.capability == key ? Some({component: d.component}) : None
      ),
    })
  )
  {capabilities: Array.concat(stores, capabilities)}
}

/** Deterministic rendering: 2-space indent, trailing newline. Rebuilding with
    no source change must produce a byte-identical file, so the committed
    manifest never churns. */
let render = (manifest: t): string =>
  JSON.stringify(manifest->Util_Sury.toJson(schema), ~space=2) ++ "\n"

/** One call for the emit CLI: structure in, `capabilities.json` content out. */
let renderForStructure = (structure: Plugin.pluginStructure): string =>
  structure->fromStructure->render
