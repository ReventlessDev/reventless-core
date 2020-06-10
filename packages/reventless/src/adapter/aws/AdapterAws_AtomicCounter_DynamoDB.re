let make = (~name, ~opts) => {
  let table =
    PulumiAws.DynamoDb.Table.(
      make(
        ~name,
        ~args=
          Args.make(
            ~attributes=[|
              {"name": "reference", "type": "S"},
              {"name": "id", "type": "S"},
            |],
            ~hashKey="id",
            ~rangeKey="reference",
            ~billingMode=`PAY_PER_REQUEST,
            (),
          ),
        ~opts,
        (),
      )
    );

  AtomicCounter.{
    resource: table->AdapterAws_Util_DynamoDb.toResource,
    increment: table->AdapterAws_AtomicCounter_DynamoDB_Runtime.increment,
    get: table->AdapterAws_AtomicCounter_DynamoDB_Runtime.get,
  };
};