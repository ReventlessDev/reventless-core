/**
The per-plugin capability manifest — `capabilities.json`, written beside the
generated `Plugin.res` by the plugin package's build.

Each entry states one capability the plugin's fields declare they need, keyed
by the store's qualified `{plugin}.{store}` identity, with the declaring
`(component, field)` sites as provenance. The keys are taken verbatim from
`pluginStructure.requiredStores` — the manifest is a rendering of the
structure, never a second scan of the sources, so the two cannot spell one
fact differently.

The platform generator unions these files across a deployment's plugins and
emits the platform's capability list from them.
*/

@schema
type kind = ObjectStore

/** The declaration site: the component's spec name and the field carrying the
    `@storageRef` annotation. */
@schema
type provenance = {component: string, field: string}

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

Keys iterate `requiredStores` itself, so a manifest's key set is byte-identical
to what the deployed plugin reports at runtime — the contract the deploy-time
coverage assertion checks against. A structure with no declarations yields an
empty `capabilities` list, not an absent file: "declares nothing" is a
statement, and the generator reading the manifests must be able to tell it
apart from "was never built".
*/
let fromStructure = (structure: Plugin.pluginStructure): t => {
  let declarations = structure.requiredStoreDeclarations->Option.getOr([])
  {
    capabilities: structure.requiredStores
    ->Option.getOr([])
    ->Array.map(key => {
      kind: ObjectStore,
      key,
      declaredBy: declarations->Array.filterMap(d =>
        d.store == key ? Some({component: d.component, field: d.field}) : None
      ),
    }),
  }
}

/** Deterministic rendering: 2-space indent, trailing newline. Rebuilding with
    no source change must produce a byte-identical file, so the committed
    manifest never churns. */
let render = (manifest: t): string =>
  JSON.stringify(manifest->S.reverseConvertToJsonOrThrow(schema), ~space=2) ++ "\n"

/** One call for the emit CLI: structure in, `capabilities.json` content out. */
let renderForStructure = (structure: Plugin.pluginStructure): string =>
  structure->fromStructure->render
