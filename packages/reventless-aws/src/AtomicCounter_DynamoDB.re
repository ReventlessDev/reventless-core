let make = (~name, ~opts) => {
  let table =
    PulumiAws.DynamoDb.Table.(
      make(
        ~name,
        ~args=
          Args.make(
            ~attributes=
              [|
                {"name": "reference", "type": "S"},
                {"name": "id", "type": "S"},
              |]
              ->Pulumi.Input.wrap,
            ~hashKey="id"->Pulumi.Input.wrap,
            ~rangeKey="reference"->Pulumi.Input.wrap,
            ~billingMode=`PAY_PER_REQUEST,
            (),
          ),
        ~opts,
        (),
      )
    );

  Reventless.AtomicCounter.{
    resource: table->Util_DynamoDb.toResource,
    increment: table->AtomicCounter_DynamoDB_Runtime.increment,
    get: table->AtomicCounter_DynamoDB_Runtime.get,
  };
};
