open AwsSdk.S3;

let getObjectPromise = (bucket, ~key) =>
  getObjectPromise(s3(), ~bucketName=bucket##bucket->Pulumi.Output.get, ~key);

let getObjectReadable = (bucket, ~key) =>
  getObjectReadableByBucketName(
    s3(),
    ~bucketName=bucket##bucket->Pulumi.Output.get,
    ~key,
  );

let putObjectPromise = (bucket, ~key, ~body) =>
  putObjectPromise(
    s3(),
    ~bucketName=bucket##bucket->Pulumi.Output.get,
    ~key,
    ~body,
  );
