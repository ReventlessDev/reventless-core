// Stack entries: (stackName, StackReference) pairs derived from Pulumi config.
// Pattern mirrors Interstack.stackDependencies in the reventless package.
// - "interstack.dependencies" — explicit cross-stack dependency names
// - "core.stack" — the core plugin stack (if configured)
let stackEntries: array<(string, Pulumi.StackReference.t)> = {
  let coreEntry =
    Pulumi.Config.make(Some("core"))
    ->Pulumi.Config.get("stack")
    ->Option.map(name => (name, Pulumi.StackReference.make(name)))

  Pulumi.Config.make(Some("interstack"))
  ->Pulumi.Config.getObject("dependencies")
  ->Option.getOr([])
  ->Array.map(name => (name, Pulumi.StackReference.make(name)))
  ->Array.concat(coreEntry->Option.mapOr([], e => [e]))
}

// Module type produced by the Make functors below.
module type StackQuery = {
  type t

  // Query all remote stack dependencies for this output type.
  // - Array exports (tasks, eventMappers): all items from all stacks are flattened into
  //   a single array; each element is a result for one item.
  // - Single-value exports (plugin): one result per stack.
  // Stacks that do not export the given output name are silently skipped.
  let queryAll: unit => Pulumi.Output.t<array<result<t, Compat.error>>>

  // Merge a local array of items with the successfully queried remote items.
  // Errors from remote queries are silently dropped — inspect queryAll() directly
  // if you need to act on them.
  let mergeWith: array<t> => Pulumi.Output.t<array<t>>
}

// Internal: parse the raw _interopMeta Pulumi output (untyped 'a) into ExportMeta.t.
// Uses Obj.magic to treat the raw Pulumi value as JSON.t, which is safe because
// Pulumi resolves and deserialises stack outputs to plain JavaScript values before
// making them available via StackReference.
let parseMeta = (raw: 'a): result<ExportMeta.t, string> =>
  try Ok((raw->Obj.magic: JSON.t)->S.parseOrThrow(ExportMeta.schema))
  catch {
  | exn =>
    let msg =
      exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("failed to parse interop meta")
    Error(msg)
  }

// Internal: query stacks for an array-valued export ("tasks" or "eventMappers").
// Each stack may export an array of items; results from all stacks are flattened.
let queryAllArray = (
  ~outputName: string,
  ~requiredFields: array<string>,
  ~fromJson: JSON.t => result<'t, string>,
): Pulumi.Output.t<array<result<'t, Compat.error>>> =>
  stackEntries
  ->Array.map(((stackName, stackRef)) => {
    // Annotate return type so getOutput<'a> unifies with JSON.t
    let metaOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("_interopMeta")
    let dataOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput(outputName)

    metaOutput->Pulumi.Output.flatMap(metaOpt =>
      dataOutput->Pulumi.Output.apply(dataOpt =>
        switch (metaOpt, dataOpt) {
        | (None, _) =>
          // Stack was found but has no _interopMeta — old publisher or not an interop stack
          [Error(Compat.MetaMissing({stackName: stackName}))]
        | (_, None) =>
          // Stack doesn't export this output name — skip silently
          []
        | (Some(rawMeta), Some(rawData)) =>
          switch parseMeta(rawMeta) {
          | Error(_) => [Error(Compat.MetaMissing({stackName: stackName}))]
          | Ok(meta) =>
            switch rawData->JSON.Decode.array {
            | None =>
              [
                Error(
                  Compat.DecodeFailed({
                    stackName: stackName,
                    reason: `"${outputName}" stack export is not an array`,
                  }),
                ),
              ]
            | Some(items) =>
              items->Array.map(item =>
                Compat.validateAndProject(
                  ~stackName,
                  ~meta,
                  ~outputName,
                  ~rawJson=item,
                  ~requiredFields,
                  ~fromJson,
                )
              )
            }
          }
        }
      )
    )
  })
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(results => results->Array.flatMap(x => x))

// Internal: query stacks for a single-valued export ("plugin").
// Each stack contributes at most one result.
let queryAllSingle = (
  ~outputName: string,
  ~requiredFields: array<string>,
  ~fromJson: JSON.t => result<'t, string>,
): Pulumi.Output.t<array<result<'t, Compat.error>>> =>
  stackEntries
  ->Array.map(((stackName, stackRef)) => {
    let metaOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput("_interopMeta")
    let dataOutput: Pulumi.Output.t<option<JSON.t>> =
      stackRef->Pulumi.StackReference.getOutput(outputName)

    metaOutput->Pulumi.Output.flatMap(metaOpt =>
      dataOutput->Pulumi.Output.apply(dataOpt =>
        switch (metaOpt, dataOpt) {
        | (None, _) => Some(Error(Compat.MetaMissing({stackName: stackName})))
        | (_, None) =>
          // Stack doesn't export this output name — skip silently
          None
        | (Some(rawMeta), Some(rawData)) =>
          switch parseMeta(rawMeta) {
          | Error(_) => Some(Error(Compat.MetaMissing({stackName: stackName})))
          | Ok(meta) =>
            Some(
              Compat.validateAndProject(
                ~stackName,
                ~meta,
                ~outputName,
                ~rawJson=rawData,
                ~requiredFields,
                ~fromJson,
              ),
            )
          }
        }
      )
    )
  })
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(results => results->Array.filterMap(x => x))

module Task = {
  module Make = (P: Projection.T): (StackQuery with type t = P.t) => {
    type t = P.t

    let queryAll = () =>
      queryAllArray(~outputName="tasks", ~requiredFields=P.requiredFields, ~fromJson=P.fromJson)

    let mergeWith = locals =>
      queryAll()->Pulumi.Output.apply(results => {
        let remotes = results->Array.filterMap(r => switch r { | Ok(v) => Some(v) | Error(_) => None })
        locals->Array.concat(remotes)
      })
  }
}

module EventMapper = {
  module Make = (P: Projection.T): (StackQuery with type t = P.t) => {
    type t = P.t

    let queryAll = () =>
      queryAllArray(
        ~outputName="eventMappers",
        ~requiredFields=P.requiredFields,
        ~fromJson=P.fromJson,
      )

    let mergeWith = locals =>
      queryAll()->Pulumi.Output.apply(results => {
        let remotes = results->Array.filterMap(r => switch r { | Ok(v) => Some(v) | Error(_) => None })
        locals->Array.concat(remotes)
      })
  }
}

module Plugin = {
  module Make = (P: Projection.T): (StackQuery with type t = P.t) => {
    type t = P.t

    let queryAll = () =>
      queryAllSingle(
        ~outputName="plugin",
        ~requiredFields=P.requiredFields,
        ~fromJson=P.fromJson,
      )

    let mergeWith = locals =>
      queryAll()->Pulumi.Output.apply(results => {
        let remotes = results->Array.filterMap(r => switch r { | Ok(v) => Some(v) | Error(_) => None })
        locals->Array.concat(remotes)
      })
  }
}
