open Reventless.Cloner;
open AwsSdk;

let decodeSecret = secret =>
  secret##_SecretString
  ->Belt.Option.getWithDefault("")
  ->Js.Json.parseExn
  ->Js.Json.decodeObject
  ->Belt.Option.getWithDefault(Js.Dict.empty())
  ->Js.Dict.map(
      (. json) => json->Js.Json.decodeString->Belt.Option.getWithDefault(""),
      _,
    );

let secretsManager = AwsSdk.SecretsManager.make();

let getSecretByUrn = urn =>
  secretsManager
  ->SecretsManager.(
      getSecretValue(~params=GetSecretValueRequest.make(~_SecretId=urn, ()))
    )
  ->Request.promise
  ->Js.Promise.then_(secret => secret->decodeSecret->Js.Promise.resolve, _);

let clone =
    (
      ~taskDefinition,
      ~cluster,
      ~fullQualifiedStackName,
      ~secretUrns,
      payload,
      _,
    ) => {
  Js.log(
    "clone: requested by user "
    ++
    payload##meta##user
    ++ " from ip "
    ++
    payload##meta##ip,
  );

  let {organization, project, stack} = fullQualifiedStackName;

  secretUrns->Belt.Array.map(getSecretByUrn)->Js.Promise.all
  |> Js.Promise.then_(secrets => {
       let environment =
         AwsSdk.ECS.KeyValuePair.(
           secrets
           ->Belt.Array.map(secret =>
               secret
               ->Js.Dict.entries
               ->Belt.Array.map(((name, value)) => make(~name, ~value))
             )
           ->Belt.Array.concatMany
           ->Belt.Array.concat([|
               make(
                 ~name="REVENTLESS_CORE_STACK",
                 ~value={j|$organization/$project/$stack|j},
               ),
               make(~name="POINT_IN_TIME", ~value=payload##pointInTime),
             |])
         );

       AwsSdk.ECS.(
         make()
         ->runTask(
             ~params=
               RunTaskRequest.make(
                 ~taskDefinition,
                 ~cluster,
                 ~launchType=`FARGATE,
                 ~overrides=
                   TaskOverride.make(
                     ~containerOverrides=[|
                       ContainerOverride.make(
                         ~name="reventless-ci",
                         ~environment,
                         ~command=[|"env"|],
                         (),
                       ),
                     |],
                     (),
                   ),
                 (),
               ),
           )
       )
       ->AwsSdk.Request.promise;
     });
};
