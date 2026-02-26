let make: ReventlessCore.StateTopic.Adapter.publisherMaker = (~name, ~opts as _, ~allQueryDbs) => {
  let queryDbResource =
    allQueryDbs
    ->ReventlessCore.Util.ReadModel.queryDbStorageResources(
      name->String.substring(
        ~start=0,
        ~end=name->String.indexOf(ReadModel->ReventlessCore.ComponentType.toName),
      ),
    )
    ->Util.DynamoDbStream.findResource

  {
    resource: queryDbResource.service
    ->Pulumi.Output.apply(service =>
      if service == AWS.DynamoDbStream.service {
        queryDbResource->Util_DynamoDbStream.toStreamResource
      } else {
        JsError.throwWithMessage(
          "StateTopicPublisher_DynamoDbStream cannot connect to QueryDbStorage_" ++ service,
        )
      }
    )
    ->ReventlessCore.Adapter.outputToResource,
  }
}
