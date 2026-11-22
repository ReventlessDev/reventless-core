// What a function whose slice declares a stash may do on the stash's table: the
// two calls the backend makes, on the one table, and nothing else.

/** `put`, and the delete that `take` is. */
let actions = ["dynamodb:PutItem", "dynamodb:DeleteItem"]

/** The policy for the table `arn`, as JSON. */
let policy = (~id: string, arn: string): string => {
  open PulumiAws.PolicyDocument
  PulumiAws.PolicyDocument.make(
    ~id,
    ~statements=[
      {
        sid: "AllowPuttingAndTakingStashedValues",
        effect: Allow,
        actions: Actions(actions),
        resources: Resource(arn),
      },
    ],
  )->PulumiAws.PolicyDocument.toJsonString
}
