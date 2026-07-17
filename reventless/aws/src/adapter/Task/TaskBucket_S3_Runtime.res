let handleBucketEvent = (handleEvent: ReventlessCore.Task.bucketCallback) =>
  (event: PulumiAws.S3.Bucket.event, _) => {
    event.records
    ->Array.map(record => {
      let eventName = record.eventName
      let key = decodeURIComponent(record.s3.object.key)
      handleEvent(~eventName, ~key)
    })
    ->Promise.all
    ->Promise.thenResolve(actions => actions->Array.flat)
  }
