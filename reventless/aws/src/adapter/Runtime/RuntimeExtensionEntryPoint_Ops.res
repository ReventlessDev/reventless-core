// Typed cold-start core for the runtime extension seam.
//
// The `.mjs` entry shells own one untyped seam — dynamically `import()`-ing the
// extension modules named in `RUNTIME_EXTENSIONS`, whose types are unknowable
// there. Everything either side of that lives here: parsing the env var, and
// invoking each module's `onColdStart` with the right arity.
//
// The invocation in particular must not sit in a shell. ReScript labelled
// arguments compile to positional ones, so a hand-written `.mjs` call is pinned
// to a signature the compiler never checks — the arity drift that cost this repo
// a production incident on the DCB command path (see the header of
// DcbCommandTopicEntryPoint_Ops.res). Typing the hooks as
// `ReventlessCore.RuntimeExtension.coldStartHook` makes the call site and the
// `Extension` module type move together.

let log = ReventlessCore.Logger.fromEnv()

/**
`RUNTIME_EXTENSIONS` as the deployed runtime receives it, written by
`RuntimeEnvironment_Lambda.makeFromCodeAsset`. The env var is absent whenever no
extension is registered, which is the only reason a runtime skips the seam.

`modules` are npm specifiers resolvable under `/var/task/node_modules` — the
extension packages ride in the code archive alongside the spec and behavior
packages. The remaining fields are this runtime's identity, resolved at
provisioning time from the ambient `ResourceAttribution` context.
*/
type config = {
  modules: array<string>,
  runtimeKind: string,
  component: string,
  plugin: option<string>,
  platform: option<string>,
}

let decodeString = (obj: dict<JSON.t>, key: string): option<string> =>
  obj->Dict.get(key)->Option.flatMap(JSON.Decode.string)

/**
Parse the `RUNTIME_EXTENSIONS` env var. `None` for an absent, empty, malformed or
module-less value — all of which mean "no seam to fire", the default state.
Deliberately total: a config the runtime cannot read must not stop it from
serving requests.
*/
let parseConfig = (raw: option<string>): option<config> =>
  switch raw {
  | None | Some("") => None
  | Some(raw) =>
    switch try raw->JSON.parseOrThrow->JSON.Decode.object catch {
    | _ => None
    } {
    | None =>
      log.error(~comp="RuntimeExtension", "RUNTIME_EXTENSIONS is not a JSON object; ignored")
      None
    | Some(obj) =>
      let modules =
        obj
        ->Dict.get("modules")
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(JSON.Decode.string)
      switch (modules->Array.length, obj->decodeString("runtimeKind"), obj->decodeString("component")) {
      | (0, _, _) => None
      | (_, Some(runtimeKind), Some(component)) =>
        Some({
          modules,
          runtimeKind,
          component,
          plugin: obj->decodeString("plugin"),
          platform: obj->decodeString("platform"),
        })
      | _ =>
        log.error(
          ~comp="RuntimeExtension",
          "RUNTIME_EXTENSIONS is missing runtimeKind or component; ignored",
        )
        None
      }
    }
  }

/**
Fire every loaded extension's `onColdStart`, in the order the deploy program
registered them, each isolated from the others (see
`ReventlessCore.RuntimeExtension`).

An unrecognised `runtimeKind` means the layer's `ComponentType` and the
deploy-time one disagree — a framework version skew, not anything an extension
can fix. Logged at ERROR and skipped rather than fired under a guessed kind: an
extension that routes on kind would otherwise attach to the wrong runtime
silently.
*/
let fire = (config: config, hooks: array<ReventlessCore.RuntimeExtension.coldStartHook>) =>
  switch config.runtimeKind->ReventlessCore.ComponentType.ofString {
  | None =>
    log.error(
      ~comp="RuntimeExtension",
      `unknown runtimeKind "${config.runtimeKind}" in RUNTIME_EXTENSIONS; cold-start extensions skipped`,
    )
  | Some(runtimeKind) =>
    log.debug(
      ~comp="RuntimeExtension",
      `firing ${hooks->Array.length->Int.toString} cold-start extension(s) for ${config.runtimeKind}(${config.component})`,
    )
    ReventlessCore.RuntimeExtension.notifyColdStartHooks(
      ~hooks,
      ~runtimeKind,
      ~component=config.component,
      ~plugin=config.plugin,
      ~platform=config.platform,
    )
  }

/**
Report an extension module that could not be loaded, or that exports no
`onColdStart`. The shell owns the `import()`, so it owns the failure; this keeps
the message and level in one place with the rest of the seam's diagnostics.
*/
let reportLoadFailure = (~specifier: string, ~reason: string) =>
  log.error(
    ~comp="RuntimeExtension",
    `cold-start extension "${specifier}" could not be loaded; skipped: ${reason}`,
  )
