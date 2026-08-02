/***  aws-sdk/s3
  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS/S3.html
*/
type client

let clientInstance = ref(None)

module Raw = {
  type options // TODO: implement
  @module("@aws-sdk/client-s3") @new external client: (~options: options=?, unit) => client = "S3"
}

let client = () =>
  switch clientInstance.contents {
  | None =>
    let client = Raw.client()
    clientInstance := Some(client)
    client
  | Some(client) => client
  }

module GetObjectCommand = {
  type t

  type input = {
    @as("Bucket") bucket: string,
    @as("Key") key: string,
    /** fetch a specific object version (requires a versioned bucket) */
    @as("VersionId")
    versionId?: string,
  }

  type output = {
    /** readable stream of the object */
    @as("Body")
    body: NodeStreams.Readable.t,
    @as("VersionId") versionId?: string,
  }

  @new @module("@aws-sdk/client-s3")
  external make: input => t = "GetObjectCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)

  // AWS SDK v3 returns the object body as an SdkStream that adds
  // `transformToString()` (UTF-8 by default) on top of the Node Readable the
  // output type reflects. Bind the method here rather than inline at the call site.
  @send
  external transformToString: NodeStreams.Readable.t => promise<string> = "transformToString"

  /** Fetch an object and return its body as a UTF-8 string. */
  let getString: (~bucket: string, ~key: string) => promise<string> = (~bucket, ~key) =>
    make({bucket, key})->send->Promise.then(output => output.body->transformToString)
}

module ListObjectVersionsCommand = {
  type t

  type input = {
    @as("Bucket") bucket: string,
    @as("Prefix") prefix?: string,
    @as("KeyMarker") keyMarker?: string,
    @as("VersionIdMarker") versionIdMarker?: string,
    @as("MaxKeys") maxKeys?: int,
    @as("Delimiter") delimiter?: string,
  }

  /** A single object version. S3 returns versions newest-first per key, so the
    entry with `isLatest: true` is the current object and the next entry for the
    same key is the immediately-prior version. */
  type objectVersion = {
    @as("Key") key: string,
    @as("VersionId") versionId: string,
    @as("IsLatest") isLatest: bool,
    @as("LastModified") lastModified?: Date.t,
    @as("ETag") eTag?: string,
    @as("Size") size?: int,
  }

  type output = {
    @as("Versions") versions?: array<objectVersion>,
    /** Delete markers are separate from `versions`; a full empty must remove
      these too, or the bucket keeps phantom keys. Shares the `objectVersion`
      shape (Key + VersionId + IsLatest). */
    @as("DeleteMarkers")
    deleteMarkers?: array<objectVersion>,
    @as("IsTruncated") isTruncated?: bool,
    @as("NextKeyMarker") nextKeyMarker?: string,
    @as("NextVersionIdMarker") nextVersionIdMarker?: string,
  }

  @new @module("@aws-sdk/client-s3")
  external make: input => t = "ListObjectVersionsCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

/** An object tag. Shared by the get/put tagging commands, which exchange the
  same `TagSet` — reading, filtering and writing back is the only way to remove
  one tag without discarding the rest. */
type tag = {
  @as("Key") key: string,
  @as("Value") value: string,
}

module GetObjectTaggingCommand = {
  type t

  type input = {
    @as("Bucket") bucket: string,
    @as("Key") key: string,
  }

  /** An object with no tags returns an empty `TagSet`, not an absent one — but
    the field is optional here anyway, since a caller that treats "absent" and
    "empty" differently would be reading a distinction S3 does not make. */
  type output = {@as("TagSet") tagSet?: array<tag>}

  @new @module("@aws-sdk/client-s3")
  external make: input => t = "GetObjectTaggingCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

module PutObjectTaggingCommand = {
  type t

  /** Replaces the object's whole tag set — there is no partial update, so
    removing one tag means putting back the others. An empty `tagSet` clears
    every tag and is a valid, idempotent call on an already-untagged object. */
  type tagging = {@as("TagSet") tagSet: array<tag>}

  type input = {
    @as("Bucket") bucket: string,
    @as("Key") key: string,
    @as("Tagging") tagging: tagging,
  }

  type output = {@as("VersionId") versionId?: string}

  @new @module("@aws-sdk/client-s3")
  external make: input => t = "PutObjectTaggingCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

module DeleteObjectsCommand = {
  /*** delete up to 1000 objects (each by key, optionally a specific version) in
    one call. Used by the seed reset to empty a bucket page by page.
    see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/s3/command/DeleteObjectsCommand/ */

  type t

  type objectIdentifier = {
    @as("Key") key: string,
    /** target a specific version; omit on an unversioned bucket */
    @as("VersionId")
    versionId?: string,
  }

  type delete = {
    @as("Objects") objects: array<objectIdentifier>,
    /** suppress the per-object success list in the response */
    @as("Quiet")
    quiet?: bool,
  }

  type input = {
    @as("Bucket") bucket: string,
    @as("Delete") delete: delete,
  }

  type deletedObject = {
    @as("Key") key?: string,
    @as("VersionId") versionId?: string,
  }

  type deleteError = {
    @as("Key") key?: string,
    @as("VersionId") versionId?: string,
    @as("Code") code?: string,
    @as("Message") message?: string,
  }

  type output = {
    @as("Deleted") deleted?: array<deletedObject>,
    @as("Errors") errors?: array<deleteError>,
  }

  @new @module("@aws-sdk/client-s3")
  external make: input => t = "DeleteObjectsCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

module PutObjectCommand = {
  type t

  type body //= String(string) | Stream(NodeStreams.Readable.t) // not implemented options: Buffer, Uint8Array
  external bodyFromString: string => body = "%identity"
  external bodyFromReadableStream: NodeStreams.Readable.t => body = "%identity"

  type input = {
    @as("Bucket")
    bucket: string,
    @as("Key")
    key: string,
    @as("Body")
    body: body,
    @as("ContentLength") contentLength?: int,
    @as("ContentType") contentType?: string,
  }

  type output = {@as("ETag") eTag: string, @as("VersionId") versionId: string}

  @new @module("@aws-sdk/client-s3")
  external make: input => t = "PutObjectCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = input => Raw.send(client(), input)
}

module CompleteMultipartUploadCommand = {
  type t
  type completedPart = {
    @as("ChecksumCRC32") checksumCRC32?: string,
    @as("ChecksumCRC32C") checksumCRC32C?: string,
    @as("ChecksumSHA1") checksumSHA1?: string,
    @as("ChecksumSHA256") checksumSHA256?: string,
    @as("ETag") eTag: string,
    /** positive integer between 1 and 10,000 */
    @as("PartNumber")
    partNumber: int,
  }
  type completeMultipartUpload = {@as("Parts") parts: array<completedPart>} //list({@as("ETag") eTag: string, @as("PartNumber") partNumber: int})
  type requestPayer = [#requester]
  type input = {
    @as("Bucket") bucket: string,
    @as("Key") key: string,
    @as("UploadId") uploadId: string,
    @as("ChecksumCRC32") checksumCRC32?: string,
    @as("ChecksumCRC32C") checksumCRC32C?: string,
    @as("ChecksumSHA1") checksumSHA1?: string,
    @as("ChecksumSHA256") checksumSHA256?: string,
    @as("ExpectedBucketOwner")
    expectedBucketOwner?: string,
    /** expects `"*"` */
    @as("IfNoneMatch")
    ifNoneMatch?: string,
    @as("MultipartUpload") multipartUpload: completeMultipartUpload,
    @as("RequestPayer") requestPayer?: requestPayer,
    @as("SSECustomerAlgorithm") sseCustomerAlgorithm?: string, // TODO: ensure only valid values can be passed
    @as("SSECustomerKey") sseCustomerKey?: string,
    @as("SSECustomerKeyMD5") sseCustomerKeyMD5?: string,
  }
  type output = {
    @as("Bucket") bucket: string,
    @as("BucketKeyEnabled") bucketKeyEnabled: bool,
    @as("ChecksumCRC32") checksumCRC32?: string,
    @as("ChecksumCRC32C") checksumCRC32C?: string,
    @as("ChecksumSHA1") checksumSHA1?: string,
    @as("ChecksumSHA256") checksumSHA256?: string,
    @as("ETag") eTag: string,
    @as("Expiration") expiration?: string,
    @as("Key") key: string,
    @as("Location") location: string,
    @as("RequestCharged") requestCharged?: string,
    @as("SSEKMSKeyId") sseKMSKeyId?: string,
    @as("ServerSideEncryption") serverSideEncryption?: string,
    @as("VersionId") versionId?: string,
  }

  @new @module("@aws-sdk/client-s3")
  external make: input => t = "CompleteMultipartUploadCommand"
}

module Upload = {
  type t

  module Raw = {
    type options = {
      leavePartsOnError?: bool,
      partSize?: int,
      queueSize?: int,
      tags?: array<dict<string>>, // NOTE: not sure if this type is correct
      // TODO: abortController?: Node.AbortController.t // There are no bindings for AbortController yet!
      client: client,
      params: PutObjectCommand.input,
    }
    @new @module("@aws-sdk/lib-storage")
    external make: options => t = "Upload"
  }

  type done = promise<CompleteMultipartUploadCommand.output>
  @send
  external done: t => done = "done"
}
