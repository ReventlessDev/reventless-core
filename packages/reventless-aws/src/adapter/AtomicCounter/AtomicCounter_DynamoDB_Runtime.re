open AwsSdk.DynamoDb.DocumentClient;
open Js.Promise;
open Belt.Result;

let get = table =>
  (. name, id) => {
    let counterId = id ++ "-" ++ name;
    query(
      ~params=
        QueryInput.make(
          ~_TableName=table##name->Pulumi.Output.get,
          ~_ConsistentRead=true,
          ~_KeyConditionExpression="id=:id AND #reference=:count",
          ~_ExpressionAttributeNames=
            [("#reference", "reference")]->Js.Dict.fromList,
          ~_ExpressionAttributeValues={":id": counterId, ":count": "count"},
          (),
        ),
    )
    |> then_(
         (
           queryOutput:
             QueryOutput.t({
               .
               "id": string,
               "reference": string,
               "count": int,
             }),
         ) =>
         switch (queryOutput##_Items) {
         | [|item|] => Ok(item##count)->resolve
         | _ => Ok(0)->resolve
         }
       )
    |> catch(err => {
         let error = err->AwsSdk.Error.ofPromise##code;
         Js.log({j|AtomicCounter.get: error:$error for $counterId|j});
         Error(error)->resolve;
       });
  };

let referenceItem = (~counterId, ~reference) =>
  Js.Json.(
    [("id", string(counterId)), ("reference", string(reference))]
    ->Js.Dict.fromList
    ->object_
  );

let putReference = (~tableName, ~counterId, ~reference) => {
  put(
    PutItemInput.make(
      ~_TableName=tableName,
      ~_Item=referenceItem(~counterId, ~reference),
      ~_ConditionExpression=
        "attribute_not_exists(id) and attribute_not_exists(#reference)",
      ~_ExpressionAttributeNames=
        [("#reference", "reference")]->Js.Dict.fromList,
      (),
    ),
  )
  |> then_(_ => resolve(Ok()))
  |> catch(err => Error(err->AwsSdk.Error.ofPromise##code)->resolve);
};

let updateCount = (~tableName, ~counterId) =>
  update(
    UpdateInput.make(
      ~_TableName=tableName,
      ~_Key={"id": counterId, "reference": "count"},
      ~_UpdateExpression="ADD #count :inc",
      ~_ExpressionAttributeNames=[("#count", "count")]->Js.Dict.fromList,
      ~_ExpressionAttributeValues={":inc": 1},
      ~_ReturnValues=`UPDATED_NEW,
      (),
    ),
  )
  |> then_((updateOutput: UpdateOutput.t({. count: int})) =>
       Ok(updateOutput##_Attributes##count) |> resolve
     )
  |> catch(err => Error(err->AwsSdk.Error.ofPromise##code)->resolve);

let deleteReference = (~tableName, ~counterId, ~reference) =>
  delete(~tableName, ~key={"id": counterId, "reference": reference})
  |> then_(_ => resolve(Ok()))
  |> catch(err => Error(err->AwsSdk.Error.ofPromise##code)->resolve);

let increment = table =>
  (. name, id, reference: string) => {
    let tableName = table##name->Pulumi.Output.get;
    let counterId = id ++ "-" ++ name;

    let msg = (message, kind) => {j|AtomicCounter.increment: $kind $message for $counterId reference: $reference|j};
    let errMsg = (err, kind) => ("error:" ++ err)->msg(kind);

    putReference(~tableName, ~counterId, ~reference)
    |> then_(
         fun
         | Ok () => {
             updateCount(~tableName, ~counterId)
             |> then_(
                  fun
                  | Ok(_) as result => result->resolve
                  | Error(err) => {
                      Js.log(err->errMsg("updateCount"));
                      deleteReference(~tableName, ~counterId, ~reference)
                      |> then_(
                           fun
                           | Ok () =>
                             Error(
                               "successfull after failed updateCount"
                               ->msg("deleteReference"),
                             )
                             ->resolve
                           | Error(err) => {
                               Js.log(err->errMsg("deleteReference"));
                               Error(
                                 "failed after failed updateCount -> SEVERE ERROR !!!"
                                 ->msg("deleteReference"),
                               )
                               ->resolve;
                             },
                         );
                    },
                );
           }
         | Error("ConditionalCheckFailedException") => {
             Js.log("ConditionalCheckFailedException"->msg("putReference"));
             table->get(. name, id)
             |> then_(
                  fun
                  | Ok(_) as result => result->resolve
                  | Error(err) => {
                      Js.log(err->errMsg("getCount"));
                      Error(
                        "failed after failed putReference"->msg("getCount"),
                      )
                      ->resolve;
                    },
                );
           }
         | Error(err) => {
             Js.log(err->errMsg("putReference"));
             Error("failed"->msg("putReference"))->resolve;
           },
       );
  };
