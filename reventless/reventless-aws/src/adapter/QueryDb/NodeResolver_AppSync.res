// AppSync Relay Node resolver.
// Creates a pipeline resolver for node(id: ID!) that decodes the global ID
// and routes to the correct DynamoDB table based on entity type.
//
// Usage: call `make` at platform deploy time after all QueryDb components are built,
// passing the collected (typeName, dataSourceName) pairs.

open PulumiAws.AppSync

type nodeTypeEntry = {
  typeName: string,
  dataSourceName: Pulumi.Input.t<string>,
}

// Tracks registered entity types for the node resolver pipeline.
let nodeTypeEntries: ref<array<nodeTypeEntry>> = ref([])

let registerNodeType = (~typeName: string, ~dataSourceName: Pulumi.Input.t<string>) =>
  nodeTypeEntries.contents->Array.push({typeName, dataSourceName})

let make = (
  ~api: Types.AppSync.api,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let entries = nodeTypeEntries.contents
  if entries->Array.length == 0 {
    []
  } else {
    let noneDataSource = DataSource.makeNoneDataSource(
      ~name="NodeResolverNone",
      ~api,
      ~opts=ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions(opts),
    )

    // First pipeline function: decode global ID (NONE datasource)
    let decodeFn = Function.makeJs(
      ~name="NodeDecodeGlobalId",
      ~api,
      ~dataSource=noneDataSource.name->Pulumi.Output.asInput,
      ~code=Resolver.Functions.nodeDecodeGlobalId,
      ~opts=ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions(opts),
    )

    // Per-type pipeline functions: each checks ctx.stash.typeName and fetches if matching
    let typeFunctions = entries->Array.map(entry => {
      Function.makeJs(
        ~name="NodeGet" ++ entry.typeName,
        ~api,
        ~dataSource=entry.dataSourceName,
        ~code=Resolver.Functions.nodeGetItemForType(~typeName=entry.typeName),
        ~opts=ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions(opts),
      )
    })

    let allFunctions = Array.concat([decodeFn], typeFunctions)

    let resolver = Resolver.makePipelineJsResolver(
      ~name="NodeResolver",
      ~api,
      ~type_="Query"->Pulumi.Input.make,
      ~field="node"->Pulumi.Input.make,
      ~code=Resolver.Functions.pipelinePassThrough,
      ~functions=allFunctions,
      ~opts=ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions(opts),
    )

    [resolver]->Array.map(Util_AppSync.toResource)
  }
}

let reset = () => nodeTypeEntries.contents = []
