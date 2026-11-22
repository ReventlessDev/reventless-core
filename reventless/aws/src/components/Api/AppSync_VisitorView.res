// A view for visitors on the narrow API: a data source of that API over the
// view's table, which the API's role may read and nothing more.

/** What reading a view takes: its rows by key, by index and in pages. */
let readActions = ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan"]

/** The role's policy for the table `tableName`, as JSON. By the table's name, as a
    function's grant on its tables is: the name is what is known here. */
let policy = (~id: string, ~tableName: string): string => {
  open PulumiAws.PolicyDocument
  let arn = `arn:aws:dynamodb:*:*:table/${tableName}`
  PulumiAws.PolicyDocument.make(
    ~id,
    ~statements=[
      {
        sid: "AllowReadingTheView",
        effect: Allow,
        actions: Actions(readActions),
        resources: Resources([arn, arn ++ "/index/*"]),
      },
    ],
  )->PulumiAws.PolicyDocument.toJsonString
}

/** The data source's name, once the role may read the table. */
let dataSource = (
  ~name: string,
  ~visitors: AppSync_VisitorApi.made,
  ~tableName: Pulumi.Output.t<string>,
  ~opts: Pulumi.CustomResourceOptions.t,
): Pulumi.Output.t<string> => {
  let _grant = PulumiAws.IAM.RolePolicy.make(
    ~name=`Visitor${name}`,
    ~args={
      policy: tableName
      ->Pulumi.Output.apply(tableName => policy(~id=`Visitor${name}Policy`, ~tableName))
      ->Pulumi.Output.asInput,
      role: visitors.role
      ->Pulumi.Output.flatMap((role: PulumiAws.IAM.Role.t) => role.id)
      ->Pulumi.Output.asInput,
    },
    ~opts,
  )
  PulumiAws.AppSync.DataSource.makeDynamoDBDataSourceWithTableName(
    ~name=`Visitor${name}`,
    ~api=visitors.api,
    ~tableName,
    ~serviceRole=visitors.role,
    ~opts,
  ).name
}
