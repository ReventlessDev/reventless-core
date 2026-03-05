let putRecord = (stream, ~data) =>
  Effect.tryPromise(
    ~catch=Kinesis_Error.classify,
    () =>
      AwsSdk.Kinesis.PutRecordCommand.make({
        data,
        //FIXME: remove JST after merge of rescript-v11 upgrade
        streamName: stream["name"]->Pulumi.Output.get,
        partitionKey: "",
      })->AwsSdk.Kinesis.PutRecordCommand.send,
  )
  ->Effect.map(_ => ())
  ->Effect.retry(Kinesis_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = Kinesis_Error.message(err)
    Effect.logError(`Util_Kinesis_Runtime.putRecord: ${msg}`)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
  ->Effect.runPromise
/* TODO partitionKey */
