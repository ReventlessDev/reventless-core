// AWS resolver for the `Platform_UIFragments` admin GraphQL query.
//
// Backed by a Lambda DataSource that scans the UiFragments StateViewSlice table
// (one item per plugin with a registered UI-fragment manifest).
// The persisted state is sury-encoded with the same shape the in-memory adapter's
// `Platform_UIFragmentsApi.encodeUIFragmentEntry` produces (null-encoded options,
// nested panel/page objects), so the handler simply returns the rows as-is.

open PulumiAws

let makeHandlerCode = (~tableName as _: string): string =>
  `
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";

const client = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.UI_FRAGMENT_RM_TABLE;

export async function handler() {
  if (!TABLE) {
    console.error("Platform_UIFragments: UI_FRAGMENT_RM_TABLE env var not set");
    return [];
  }
  const items = [];
  let exclusiveStartKey;
  do {
    const out = await client.send(new ScanCommand({
      TableName: TABLE,
      Limit: 1000,
      ExclusiveStartKey: exclusiveStartKey,
    }));
    if (out.Items) items.push(...out.Items);
    exclusiveStartKey = out.LastEvaluatedKey;
  } while (exclusiveStartKey);

  // Platform invariant: one version per plugin at a time, so the UI sees just
  // the bare plugin name (mirrors ReventlessCore.Plugin.name). The registry is
  // keyed by bare plugin name (a no-op for the split below), but rows persisted
  // by the pre-slice registry were keyed name@version — keep the collapse to the
  // highest version per plugin name (mirrors ReventlessCore.Plugin.compareVersions)
  // so a mixed table never surfaces duplicate fragments.
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
    if (!item || !item.pluginId || !item.remoteEntryUrl) continue;
    const name = String(item.pluginId).split("@")[0];
    const version = String(item.pluginId).split("@")[1] ?? "";
    const prev = latestByName.get(name);
    if (!prev || cmpVer(version, prev.version) > 0) {
      latestByName.set(name, {
        version,
        entry: {
          pluginId: name,
          remoteEntryUrl: item.remoteEntryUrl,
          panels: item.panels || [],
          pages: item.pages || [],
          registeredAt: item.registeredAt || "",
          updatedAt: item.updatedAt || "",
        },
      });
    }
  }
  return [...latestByName.values()].map(v => v.entry);
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
  ~uiFragmentRegistryTableName: Pulumi.Output.t<string>,
  // Resolves when the admin-base schema push has completed and the API is ACTIVE
  // (Platform_Admin.adminSchemaPushed). CreateResolver is gated on it so it never
  // races StartSchemaCreation — the same first-deploy race that clobbered
  // Platform_ApiFragments; harmless here today only because the field predates it.
  ~schemaReady: Pulumi.Output.t<unit>,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let name = "PlatformUIFragments"

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "Lambda",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~tags=AWS.Tags.make(
      ~name=name ++ "Lambda",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
    ~opts,
  )

  let _ =
    uiFragmentRegistryTableName->Pulumi.Output.apply(tableName => {
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
                sid: "AllowScanUiFragmentsTable",
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

  let archiveContents: dict<Pulumi.Archive.assetOrArchive> = Dict.make()
  let handlerCodeStub = makeHandlerCode(~tableName="")
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
      tags: AWS.Tags.make(~name=name ++ "Lambda", ~kind=ReventlessCore.ComponentType.Platform, ~role=Runtime, ~scope=Platform),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("UI_FRAGMENT_RM_TABLE", uiFragmentRegistryTableName->Pulumi.Output.asInput),
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
    ~tags=AWS.Tags.make(
      ~name=name ++ "DataSource",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Identity,
      ~scope=Platform,
    ),
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

  // Create the resolver only after the admin schema push is ACTIVE — otherwise
  // CreateResolver races StartSchemaCreation the first time this field ships.
  let _resolver =
    schemaReady->Pulumi.Output.apply(() =>
      AppSync_Resolver_Native.makeUnitJsResolver(
        ~name=name ++ "Resolver",
        ~api,
        ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
        ~type_="Query"->Pulumi.Input.make,
        ~field="Platform_UIFragments"->Pulumi.Input.make,
        ~code=resolverCode,
        ~opts,
      )
    )
}
