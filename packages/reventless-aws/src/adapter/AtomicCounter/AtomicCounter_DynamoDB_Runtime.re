open AwsSdk.DynamoDb.DocumentClient;
open Js.Promise;
open Belt.Result;

let errorMessage = err =>
  err->AwsSdk.Error.ofPromise##code
  ++ ":"
  ++
  err->AwsSdk.Error.ofPromise##message;

let get = table =>
  (. name, id) => {
    let counterId = {j|$name-$id|j};
    query(
      ~params=
        QueryInput.make(
          ~_TableName=table##name->Pulumi.Output.get,
          ~_ConsistentRead=true,
          ~_KeyConditionExpression="id=:id",
          ~_ExpressionAttributeValues={":id": counterId},
          (),
        ),
    )
    |> then_(
         (
           queryOutput:
             QueryOutput.t({
               .
               "id": string,
               "count": int,
             }),
         ) =>
         switch (queryOutput##_Items) {
         | [|item|] => Ok(item##count)->resolve
         | _ => Ok(0)->resolve
         }
       )
    |> catch(err => {
         let error = err->errorMessage;
         Js.log({j|AtomicCounter.get: Error:$error for $counterId|j});
         Error(error)->resolve;
       });
  };

let ttl = {
  let now_ms = Reventless.Message.now();
  let now_s = now_ms /. 1000.0;
  let now_s_rounded = now_s->int_of_float;

  let week_in_s = 60 * 60 * 24 * 7;
  //604800; // = 60*60*24*7

  (now_s_rounded + week_in_s)->float_of_int;
};

let referenceItem = (~referenceId) =>
  Js.Json.(
    [("id", string(referenceId)), ("ttl", number(ttl))]
    ->Js.Dict.fromList
    ->object_
  );

let putReference = (~tableName, ~referenceId) => {
  AtomicCounter_DynamoDB_Runtime_DocumentClient.put(
    PutItemInput.make(
      ~_TableName=tableName,
      ~_Item=referenceItem(~referenceId),
      ~_ConditionExpression="attribute_not_exists(id)",
      (),
    ),
  )
  |> then_(_ => resolve(Ok()))
  |> catch(err => Error(err->errorMessage)->resolve);
};

let updateCount = (~tableName, ~counterId) =>
  update(
    UpdateInput.make(
      ~_TableName=tableName,
      ~_Key={"id": counterId},
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
  |> catch(err => Error(err->errorMessage)->resolve);

let deleteReference = (~tableName, ~referenceId) =>
  delete(~tableName, ~key={"id": referenceId})
  |> then_(_ => resolve(Ok()))
  |> catch(err => Error(err->errorMessage)->resolve);

let increment = table =>
  (. name, id, reference: string) => {
    let tableName = table##name->Pulumi.Output.get;
    let counterId = {j|$name-$id|j};
    let referenceId = {j|$counterId-$reference|j};

    let msg = (message, kind) => {j|AtomicCounter.increment: $kind $message for $id reference: $reference|j};
    let errMsg = (err, kind) => ("Error:" ++ err)->msg(kind);

    putReference(~tableName, ~referenceId)
    |> then_(
         fun
         | Ok () => {
             updateCount(~tableName, ~counterId)
             |> then_(
                  fun
                  | Ok(_) as result => result->resolve
                  | Error(err) => {
                      Js.log(err->errMsg("updateCount"));
                      deleteReference(~tableName, ~referenceId)
                      |> then_(
                           fun
                           | Ok () =>
                             {
                               let message =
                                 "successfull after failed updateCount"
                                 ->msg("deleteReference");
                               Js.log(message);
                               Error(message);
                             }
                             ->resolve
                           | Error(err) => {
                               Js.log(err->errMsg("deleteReference"));
                               Error(
                                 "failed after failed updateCount -> SEVERE Error !!!"
                                 ->msg("deleteReference"),
                               )
                               ->resolve;
                             },
                         );
                    },
                );
           }
         | Error(err) =>
           if (err->Js.String2.includes("ConditionalCheckFailedException")) {
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
           } else {
             Js.log(err->errMsg("putReference"));
             deleteReference(~tableName, ~referenceId)
             |> then_(
                  fun
                  | Ok () =>
                    {
                      let message =
                        "successfull after failed putReference"
                        ->msg("deleteReference");
                      Js.log(message);
                      Error(message);
                    }
                    ->resolve
                  | Error(err) => {
                      Js.log(err->errMsg("deleteReference"));
                      Error(
                        "failed after failed putReference -> SEVERE Error !!!"
                        ->msg("deleteReference"),
                      )
                      ->resolve;
                    },
                );
           },
       );
  };
