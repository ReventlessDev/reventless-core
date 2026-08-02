// The tag that makes "nobody has committed a reference to this object yet"
// visible to S3 itself.
//
// One definition, three readers, and they must agree exactly or the mechanism
// deletes live data:
//   - the mint side writes it on the presigned PUT (`Upload_Presign_S3_Ops`),
//   - the claim side removes it when a committed event carries the ref
//     (`Upload_Claim_S3_Ops`),
//   - the bucket's lifecycle rule expires what still carries it
//     (`Capability_ObjectStore_S3`).
// A rule filtered on a key the mint side never writes matches *nothing*, which
// fails safe; a claim side that strips a different key leaves every object
// tagged, which does not. Hence one module rather than three string literals.
//
// Runtime-pure and Pulumi-free on purpose: two of the three readers are Lambda
// handlers shipped as EntryPoint modules, so a deploy-time import here would
// leak `@pulumi/pulumi` into their cold-start graph.
//
// The tag's meaning is deliberately "not yet claimed", never "safe to delete".
// Nothing reads it as permission; the lifecycle rule adds an age condition of
// its own, and it is opt-in per store.

/** Tag key. `:` is a legal S3 tag-key character, and the `reventless:` prefix
    keeps the framework's tags from colliding with a deployment's own. */
let key = "reventless:pending"

/** Tag value. A single-valued tag: the key's presence is the fact, and the
    value exists only because S3 tags are pairs. */
let value = "true"

/**
The `Tagging` parameter of a `PutObject`, in the URL-encoded query-string form
S3 specifies for that header.

The colon is percent-encoded here because the value is parsed as a query string
by S3, so its key/value separators are the only characters that may appear raw.
The SDK hoists this into the presigned URL's query string (verified against a
live bucket: a PUT that sends nothing but `Content-Type` still lands the tag),
so the caller needs no cooperation and cannot opt out.
*/
let putObjectTagging = `${key->encodeURIComponent}=${value->encodeURIComponent}`
