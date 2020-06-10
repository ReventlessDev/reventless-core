open AwsSdk.DynamoDb.DocumentClient;
open Js.Promise;
open Belt.Result;

let get = table =>
  (. name, id) => {
    query(
      ~params=
        QueryInput.make(
          ~_TableName=table##name->Pulumi.Output.get,
          ~_ConsistentRead=true,
          ~_KeyConditionExpression="id=:id AND #reference=:count",
          ~_ExpressionAttributeNames=
            [("#reference", "reference")] |> Js.Dict.fromList,
          ~_ExpressionAttributeValues={
            ":id": id ++ "-" ++ name,
            ":count": "count",
          },
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
         | [|item|] => item##count |> resolve
         | _ => 0 |> resolve
         }
       );
  };

let getCount = table =>
  (. name, id) =>
    (get(table))(. name, id)
    |> then_(count => Ok(count) |> resolve)
    |> catch(err => Error(err->AwsSdk.Error.ofPromise##code) |> resolve);

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
        [("#reference", "reference")] |> Js.Dict.fromList,
      (),
    ),
  )
  |> then_(_ => resolve(Ok()))
  |> catch(err => Error(err->AwsSdk.Error.ofPromise##code) |> resolve);
};

let updateCount = (~tableName, ~counterId) =>
  update(
    UpdateInput.make(
      ~_TableName=tableName,
      ~_Key={"id": counterId, "reference": "count"},
      ~_UpdateExpression="ADD #count :inc",
      ~_ExpressionAttributeNames=[("#count", "count")] |> Js.Dict.fromList,
      ~_ExpressionAttributeValues={":inc": 1},
      ~_ReturnValues=`UPDATED_NEW,
      (),
    ),
  )
  |> then_((updateOutput: UpdateOutput.t({. count: int})) =>
       Ok(updateOutput##_Attributes##count) |> resolve
     )
  |> catch(err => Error(err->AwsSdk.Error.ofPromise##code) |> resolve);

let deleteReference = (~tableName, ~counterId, ~reference) =>
  delete(~tableName, ~key={"id": counterId, "reference": reference})
  |> then_(_ => resolve(Ok()))
  |> catch(err => Error(err->AwsSdk.Error.ofPromise##code) |> resolve);

let increment = table =>
  (. name, id, reference: string) => {
    let tableName = table##name->Pulumi.Output.get;
    let counterId = id ++ "-" ++ name;

    let msg = (code, kind) => {j|AtomicCounter.increment: $kind error:$code for $id-$name reference: $reference|j};
    let errMsg = (err, kind) => err->msg(kind);

    putReference(~tableName, ~counterId, ~reference)
    |> then_(
         fun
         | Ok () => {
             updateCount(~tableName, ~counterId)
             |> then_(
                  fun
                  | Ok(count) => count |> resolve
                  | Error(err) => {
                      Js.log(err->errMsg("updateCount"));
                      deleteReference(~tableName, ~counterId, ~reference)
                      |> then_(
                           fun
                           | Ok () =>
                             Js.Exn.raiseError(
                               "delete after update error successfull"
                               ->msg("compensation"),
                             )

                           | Error(err) =>
                             Js.Exn.raiseError(
                               err->errMsg("deleteReference"),
                             ),
                         );
                    },
                );
           }
         | Error("ConditionalCheckFailedException") => {
             Js.log("ConditionalCheckFailedException"->msg("putReference"));
             table->getCount(. name, id)
             |> then_(
                  fun
                  | Ok(count) => count |> resolve
                  | Error(err) => Js.Exn.raiseError(err->errMsg("getCount")),
                );
           }
         | Error(err) => Js.Exn.raiseError(err->errMsg("putReference")),
       );
  };