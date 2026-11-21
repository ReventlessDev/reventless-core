open PulumiAws
open DynamoDb.Table

type api = Types.AppSync.api
type role = Types.AppSync.role

let globalSecondaryIndexes = (indexes: array<Reventless.ReadModel.indexConfig>) =>
  indexes
  ->Array.map((indexConfig: Reventless.ReadModel.indexConfig) => {
    let {index, projectionType} = indexConfig
    let (projectionType, includes) = switch projectionType {
    | Reventless.ReadModel.ALL as _projection => (PulumiAws.DynamoDb.Table.ALL, None)
    | Reventless.ReadModel.KEYS_ONLY as _projection => (PulumiAws.DynamoDb.Table.KEYS_ONLY, None)
    | Reventless.ReadModel.INCLUDE(includes) => (PulumiAws.DynamoDb.Table.INCLUDE, Some(includes))
    }
    {
      name: index,
      hashKey: indexConfig.idField->Option.getOr(index),
      rangeKey: ?indexConfig.subIdField,
      projectionType,
      nonKeyAttributes: ?includes,
    }->Pulumi.Input.make
  })
  ->Pulumi.Input.make

// Pulumi rejects a table that defines the same attribute twice, and an index may
// legitimately key on one the table already declares — the derived `@owner` index
// sorts on `id`, and any index may sort on the table's own sort key. First
// declaration wins; they agree on the type because both name the same column.
let attributes = (sortField, indexes: array<Reventless.ReadModel.indexConfig>) => {
  let all = [
    [{name: "id", type_: "S"}],
    sortField->Option.mapOr([], sortField => [{name: sortField, type_: "S"}]),
    indexes
    ->Array.map((indexConfig: Reventless.ReadModel.indexConfig) => {
      let {index, type_} = indexConfig
      [
        [{name: indexConfig.idField->Option.getOr(index), type_}],
        indexConfig.subIdField->Option.mapOr([], sortField => [{name: sortField, type_: "S"}]),
      ]->Array.flat
    })
    ->Array.flat,
  ]->Array.flat
  let seen = Set.make()
  all->Array.filter(({name}) =>
    if seen->Set.has(name) {
      false
    } else {
      seen->Set.add(name)
      true
    }
  )
}

/**
The DynamoDB grant the AppSync data source assumes.

An index is a SEPARATE IAM resource (`<table>/index/<name>`), so a grant naming
only the table permits `Scan` and `GetItem` and denies every `Query` against a
GSI — silently at deploy time, loudly at the first request. Two doors read one:
the by-index door, and the list door's owner-scoped branch.

Pure and named so the resource list is assertable without a deploy; the failure
it guards has no other artifact to check.
*/
let dataSourcePolicyDocument = (~name: string, ~tableArn: string): string => {
  open PolicyDocument
  PolicyDocument.make(
    ~id=name ++ "DataSourcePolicy",
    ~statements=[
      {
        sid: "AllowDynamoDbActions",
        effect: Allow,
        actions: Action("dynamodb:*"),
        resources: Resources([tableArn, tableArn ++ "/index/*"]),
      },
    ],
  )->toJsonString
}

let dataSource = (name, table, api, apiRole, opts) => {
  let _dataSourceRolePolicy = {
    IAM.RolePolicy.make(
      ~name,
      ~args={
        IAM.RolePolicy.policy: table.arn
        ->Pulumi.Output.apply(tableArn => dataSourcePolicyDocument(~name, ~tableArn))
        ->Pulumi.Output.asInput,
        role: apiRole
        ->Pulumi.Output.flatMap((role: PulumiAws.IAM.Role.t) => role.id)
        ->Pulumi.Output.asInput,
      },
      ~opts,
    )
  }

  AppSync.DataSource.makeDynamoDBDataSource(~name, ~api, ~table, ~serviceRole=apiRole, ~opts)
}

/** DynamoDB's cap on global secondary indexes per table. */
let gsiLimit = 20

// The annotation an index comes from, for the message that refuses too many.
let indexSource = (ic: Reventless.ReadModel.indexConfig) =>
  if !Reventless.ReadModel.isDerivedIndex(ic) {
    "@index"
  } else if (
    ic.index == Reventless.Lifecycle.Trail.lifecycleIndexName ||
      ic.index->String.startsWith(Reventless.Lifecycle.Trail.enteredPrefix)
  ) {
    "@trail"
  } else {
    "@owner"
  }

/** Why a table cannot be provisioned with these indexes, if it cannot. Counted
    here, where the table is declared, so the deploy stops before AWS refuses it. */
let indexCountProblem = (~name: string, indexes: array<Reventless.ReadModel.indexConfig>) => {
  let count = indexes->Array.length
  count > gsiLimit
    ? Some(
        `${name} asks for ${count->Int.toString} global secondary indexes and DynamoDB allows ${gsiLimit->Int.toString} on a table: ` ++
        indexes
        ->Array.map(ic => `${ic.index} (${indexSource(ic)})`)
        ->Array.join(", ") ++ ". Name fewer states in @trail({index: [...]}), or drop an @index.",
      )
    : None
}

let make: ReventlessCore.QueryDb_Adapter.storageMaker<api, role> = (
  ~name,
  ~indexes,
  ~subIdField=?,
  ~ttl=?,
  ~api,
  ~apiRole,
  ~owner,
  ~opts,
) => {
  indexCountProblem(~name, indexes)->Option.forEach(JsError.throwWithMessage)
  let tags = AWS.Tags.make(
    ~name,
    ~kind=ReventlessCore.QueryDb.componentType,
    ~role=QueryDb,
    ~owner?,
  )
  let table = Util_DynamoDb.makeTable(
    name,
    ~attributes=attributes(subIdField, indexes),
    ~rangeKey=?subIdField,
    ~globalSecondaryIndexes=indexes->globalSecondaryIndexes,
    ~ttl?,
    ~tags,
    ~opts,
  )

  open QueryDbStorage_DynamoDb_Runtime
  {
    resources: [table->Util_DynamoDb.toResource(~tags=tags->Pulumi.Output.fromInput)],
    dataSourceName: dataSource(name, table, api, apiRole, opts).name,
    operations: table
    ->Util_DynamoDb.toResolvedTableOutput
    ->Pulumi.Output.apply(resolvedTable => {
      ReventlessCore.QueryDb.load: resolvedTable->load,
      loadStream: resolvedTable->loadStream,
      save: resolvedTable->save,
      saveBatch: resolvedTable->saveBatch,
      count: resolvedTable->count,
      delete: resolvedTable->delete,
      deleteBatch: resolvedTable->deleteBatch,
    }),
  }
}
