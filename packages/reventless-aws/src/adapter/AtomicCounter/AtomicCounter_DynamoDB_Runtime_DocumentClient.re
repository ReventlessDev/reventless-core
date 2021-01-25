open AwsSdk;

let documentClient =
  DynamoDb.DocumentClient.(
    makeCustom(
      ~options=
        Options.make(
          ~service=
            DynamoDb_DynamoDb.make(
              ~options=
                DynamoDb_DynamoDb.Options.make(
                  ~maxRetries=0,
                  ~httpOptions=
                    Request.HttpOptions.make(
                      ~connectTimeout=1000,
                      ~timeout=5000,
                    ),
                  (),
                ),
              (),
            ),
          ~convertEmptyValues=true,
        ),
      (),
    )
  );

let put = params => {
  documentClient->DynamoDb.DocumentClient.putCustom(~params)->Request.promise
  |> Js.Promise.then_(_ => Js.Promise.resolve());
};
