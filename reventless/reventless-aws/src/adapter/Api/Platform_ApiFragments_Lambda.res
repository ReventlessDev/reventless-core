// AWS resolver for the `Platform_ApiFragments` admin GraphQL query — the deploy-facing
// push-status surface of the API-schema fragment registry.
//
// Backed by a Lambda DataSource that scans the ApiFragments StateViewSlice table (one item per
// plugin name that has registered an API-schema fragment). The persisted state carries the same
// status fields the in-memory adapter's `Platform_ApiFragmentsApi.encodeApiFragmentEntry`
// projects (pluginId, apiTarget, pushStatus, pushMessage, pushedAt, registeredAt, updatedAt) —
// all plain/bare-string primitives in DynamoDB — so the handler projects them as-is. The encoded
// SDL is deliberately NOT exposed (the deploy waiter needs status only). The registry is keyed by
// bare plugin name, so no name@version collapse is required (mirrors the ApiFragments slice).

open PulumiAws

let makeHandlerCode = (~tableName as _: string): string =>
  `
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand } from "@aws-sdk/lib-dynamodb";

const client = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.API_FRAGMENT_RM_TABLE;

export async function handler() {
  if (!TABLE) {
    console.error("Platform_ApiFragments: API_FRAGMENT_RM_TABLE env var not set");
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

  // Status-only projection, byte-identical to Platform_ApiFragmentsApi.encodeApiFragmentEntry.
  // The registry is keyed by bare plugin name; split("@")[0] is a defensive no-op against any
  // legacy name@version row.
  return items
    .filter((item) => item && item.pluginId)
    .map((item) => ({
      pluginId: String(item.pluginId).split("@")[0],
      apiTarget: item.apiTarget || "Domain",
      pushStatus: item.pushStatus || "pending",
      pushMessage: item.pushMessage || "",
      pushedAt: item.pushedAt || "",
      registeredAt: item.registeredAt || "",
      updatedAt: item.updatedAt || "",
    }));
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
  ~apiFragmentRegistryTableName: Pulumi.Output.t<string>,
  // Resolves when the admin-base schema push has completed and the API is ACTIVE
  // (Platform_Admin.adminSchemaPushed). CreateResolver is gated on it so it never
  // races StartSchemaCreation on this first-ever-deployed field.
  ~schemaReady: Pulumi.Output.t<unit>,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let name = "PlatformApiFragments"

  let lambdaRole = IAM.Role.makeWithDefaultPolicy(
    ~name=name ++ "Lambda",
    ~servicePrincipal=AWS.Lambda.principal->Pulumi.Output.make,
    ~opts,
  )

  let _ =
    apiFragmentRegistryTableName->Pulumi.Output.apply(tableName => {
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
                sid: "AllowScanApiFragmentsTable",
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
      tags: AWS.Tags.make(~name=name ++ "Lambda", ReventlessCore.ReadModel.componentType),
      environment: (
        {
          Lambda.Function.variables: Dict.fromArray([
            ("Environment", Pulumi.Pulumi.getStackName()->Pulumi.Input.make),
            ("API_FRAGMENT_RM_TABLE", apiFragmentRegistryTableName->Pulumi.Output.asInput),
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

  // Create the resolver only after the admin schema push is ACTIVE — otherwise
  // CreateResolver races StartSchemaCreation and fails with "No field named
  // Platform_ApiFragments found on type Query" the first time this field ships.
  let _resolver =
    schemaReady->Pulumi.Output.apply(() =>
      AppSync_Resolver_Native.makeUnitJsResolver(
        ~name=name ++ "Resolver",
        ~api,
        ~dataSourceName=dataSource.name->Pulumi.Output.asInput,
        ~type_="Query"->Pulumi.Input.make,
        ~field="Platform_ApiFragments"->Pulumi.Input.make,
        ~code=resolverCode,
        ~opts,
      )
    )
}
