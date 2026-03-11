type uploadOptions = {
  leavePartsOnError?: bool,
  partSize?: int,
  queueSize?: int,
  tags?: array<dict<string>>,
  client?: S3.client,
  params: S3.PutObjectCommand.input,
}

let uploadMake = (options: uploadOptions): S3.Upload.t =>
  S3.Upload.Raw.make({
    leavePartsOnError: ?options.leavePartsOnError,
    partSize: ?options.partSize,
    queueSize: ?options.queueSize,
    tags: ?options.tags,
    client: options.client->Option.getOr(S3.client()),
    params: options.params,
  })

let upload = (options: uploadOptions): S3.Upload.done => uploadMake(options)->S3.Upload.done
