let make = (~name, ~opts) => {
  let table =
    PulumiAws.DynamoDb.Table.(
      make(
        ~name,
        ~args=
          Args.make(
            ~attributes=[|{"name": "id", "type": "S"}|]->Pulumi.Input.wrap,
            ~hashKey="id"->Pulumi.Input.wrap,
            ~billingMode=`PAY_PER_REQUEST,
            ~ttl=
              Args.TableTtl.make(
                ~attributeName="ttl"->Pulumi.Input.wrap,
                ~enabled=true->Pulumi.Input.wrap,
                (),
              )
              ->Pulumi.Input.wrap,
            (),
          ),
        ~opts,
        (),
      )
    );

  Reventless.AtomicCounter.Adapter.{
    resource: table->Util_DynamoDb.toResource,
    increment: table->AtomicCounter_DynamoDB_Runtime.increment,
    get: table->AtomicCounter_DynamoDB_Runtime.get,
  };
};
