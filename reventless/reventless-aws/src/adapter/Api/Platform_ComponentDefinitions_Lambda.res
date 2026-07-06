// AWS resolver for the `Platform_ComponentDefinitions` admin GraphQL query.
//
// Backed by a Lambda DataSource that scans the Plugin read model and emits
// one entry per Connected plugin whose persisted state carries a `structure`
// field. The persisted structure is sury-encoded with the exact same shape
// the in-memory adapter's `Platform_ComponentDefinitionsApi.encodePluginStructureEntry`
// produces (literal-string `commandLevel`, `null`-encoded options), so the
// handler simply wraps each persisted structure with `pluginId` — no decoding
// or re-encoding needed.

open PulumiAws

// `adminEntryJson` is the JSON-stringified entry for the built-in Platform_Admin
// plugin (Plugin aggregate with Activate/Deactivate, Plugin read model).
// The admin never `Connect`s to itself, so its structure never
// enters the Plugin read model — we inject it at deploy time so the host shell
// renders Auto UI for it alongside user plugins.
let makeHandlerCode = (~tableName as _: string, ~adminEntryJson: string): string =>
  `
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";

const client = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.PLUGIN_RM_TABLE;
const ADMIN_ENTRY = ${adminEntryJson};

export async function handler() {
  if (!TABLE) {
    console.error("Platform_ComponentDefinitions: PLUGIN_RM_TABLE env var not set");
    return [ADMIN_ENTRY];
  }
  const items = [];
  let exclusiveStartKey;
  do {
    const out = await client.send(new ScanCommand({
      TableName: TABLE,
      FilterExpression: "contains(#status, :connected)",
      ExpressionAttributeNames: { "#status": "status" },
      ExpressionAttributeValues: { ":connected": "Connected" },
      Limit: 1000,
      ExclusiveStartKey: exclusiveStartKey,
    }));
    if (out.Items) items.push(...out.Items);
    exclusiveStartKey = out.LastEvaluatedKey;
  } while (exclusiveStartKey);

  // Platform invariant: one version per plugin at a time, so the UI sees just
  // the bare plugin name (mirrors ReventlessCore.Plugin.name). The Connected
  // filter above does not enforce single-version: during a rolling deploy or a
  // missed retire, several versions of the same plugin sit in Connected at once
  // and each would otherwise emit a full duplicate set of AutoUI menu entries.
  // Collapse to the highest version per plugin name (mirrors
  // ReventlessCore.Plugin.compareVersions).
  const cmpVer = (a, b) => {
    const pa = String(a).replace(/[-+]/g, ".").split(".");
    const pb = String(b).replace(/[-+]/g, ".").split(".");
    const len = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const sa = pa[i] ?? "", sb = pb[i] ?? "";
      const na = Number(sa), nb = Number(sb);
      const bothNum = sa !== "" && sb !== "" && !Number.isNaN(na) && !Number.isNaN(nb);
      if (bothNum) { if (na !== nb) return na > nb ? 1 : -1; }
      else if (sa !== sb) return sa > sb ? 1 : -1;
    }
    return 0;
  };
  const latestByName = new Map();
  for (const item of items) {
    if (!item || !item.structure) continue;
    const name = String(item.name).split("@")[0];
    const version = String(item.name).split("@")[1] ?? "";
    const prev = latestByName.get(name);
    if (!prev || cmpVer(version, prev.version) > 0) {
      latestByName.set(name, { version, entry: { pluginId: name, ...item.structure } });
    }
  }
  const userEntries = [...latestByName.values()].map(v => v.entry);
  return [ADMIN_ENTRY, ...userEntries];
}
`

let resolverCode = `
import { util } from '@aws-appsync/utils';
export function request(ctx) {
  return { operation: 'Invoke', payload: {} };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message, ctx.error.type);
  return ctx.result;
}
`->Pulumi.Input.make

let make = (
  ~api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~pluginReadModelTableName: Pulumi.Output.t<string>,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let name = "PlatformUIDefinitions"

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "Lambda",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts,
  )

  let _ =
    pluginReadModelTableName->Pulumi.Output.apply(tableName => {
      open PolicyDocument
      let _rolePolicy = IAM.RolePolicy.make(
        ~name=name ++ "LambdaPolicy",
        ~args={
          IAM.RolePolicy.policy: PolicyDocument.make(
            ~id=name ++ "LambdaPolicy",
            ~statements=[
              {
                sid: "AllowLambdaLogging",
                effect: Allow,
                actions: Action("logs:*"),
                resources: Resource("arn:aws:logs:*:*:*"),
              },
              {
                sid: "AllowScanPluginRm",
                effect: Allow,
                actions: Actions(["dynamodb:Scan"]),
                resources: Resource("arn:aws:dynamodb:*:*:table/" ++ tableName),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: lambdaRole.id->Pulumi.Output.asInput,
        },
        ~opts,
      )
    })

  let adminEntryJson =
    ReventlessCore.Platform_ComponentDefinitionsApi.encodePluginStructureEntry(
      ~pluginId=ReventlessCore.Platform_Admin_Structure.pluginId,
      ReventlessCore.Platform_Admin_Structure.structure,
    )->JSON.stringify

  let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  let handlerCodeStub = makeHandlerCode(~tableName="", ~adminEntryJson)
  archiveContents->Dict.set(
    "index.mjs",
    Pulumi.Asset.stringAsset(handlerCodeStub)->Pulumi.Archive.assetToAssetOrArchive,
  )
  // ESM self-containment: the handler imports @aws-sdk/* bare specifiers the
  // nodejs22.x runtime provides only under /var/runtime — unreachable from
  // /var/task ESM without the resolver hook. Ship the loader + set its env vars.
  let loaderHash = Util_Bundle.addEsmLoaderAssets(archiveContents)
  let code = Pulumi.Archive.assetArchive(archiveContents)
  let sourceCodeHash = Util_Bundle.hashString(handlerCodeStub ++ "\n---\n" ++ loaderHash)

  let layers =
    Lambda.reventlessLayerArn
    ->Option.map(arn => [arn->Pulumi.Input.make])
    ->Option.getOr([])
    ->Pulumi.Input.make

  let lambda = Lambda.Function.make(
    ~name=name ++ "Lambda",
    ~args={
      handler: "index.handler"->Pulumi.Input.make,
      runtime: "nodejs22.x"->Pulumi.Input.make,
      code: code->Pulumi.Input.make,
      sourceCodeHash: sourceCodeHash->Pulumi.Input.make,
      role: lambdaRole.arn->Pulumi.Output.asInput,
      memorySize: 512->Pulumi.Input.make,
      timeout: 30->Pulumi.Input.make,
      layers,
      tags: AWS.Tags.make(~name=name ++ "Lambda", ReventlessCore.ReadModel.componentType),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("PLUGIN_RM_TABLE", pluginReadModelTableName->Pulumi.Output.asInput),
            ("NODE_OPTIONS", Util_Bundle.esmLoaderNodeOptions->Pulumi.Input.make),
            ("ESM_FALLBACK_DIRS", Util_Bundle.esmFallbackDirs->Pulumi.Input.make),
          ]),
        }: Lambda.Function.functionEnvironment
      )->Pulumi.Input.make,
    },
    ~opts,
  )

  let dataSourceRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "DataSource",
    ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
    ~opts,
  )

  let _ =
    (lambda.arn, dataSourceRole.id)
    ->Pulumi.Output.all2
    ->Pulumi.Output.apply(((lambdaArn, dataSourceRoleId)) => {
      open PolicyDocument
      let _attach = IAM.RolePolicy.make(
        ~name=name ++ "DataSource",
        ~args={
          IAM.RolePolicy.policy: PolicyDocument.make(
            ~id=name ++ "DataSourcePolicy",
            ~statements=[
              {
                sid: "AllowDataSourceInvokeLambda",
                effect: Allow,
                actions: Action("lambda:InvokeFunction"),
                resources: Resource(lambdaArn),
              },
            ],
          )
          ->PolicyDocument.toJsonString
          ->Pulumi.Input.make,
          role: dataSourceRoleId->Pulumi.Input.make,
        },
        ~opts,
      )
    })

  let dataSource = AppSync.DataSource.make(
    ~name=name ++ "DataSource",
    ~args={
      type_: AWS_LAMBDA,
      apiId: api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
      lambdaConfig: {
        AppSync.DataSource.functionArn: lambda.arn->Pulumi.Output.asInput,
      }->Pulumi.Input.make,
      serviceRoleArn: dataSourceRole.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(opts),
  )

  let _resolver = AppSync_Resolver_Native.makeUnitJsResolver(
    ~name=name ++ "Resolver",
    ~api,
    ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
    ~type_="Query"->Pulumi.Input.make,
    ~field="Platform_ComponentDefinitions"->Pulumi.Input.make,
    ~code=resolverCode,
    ~opts,
  )
}
