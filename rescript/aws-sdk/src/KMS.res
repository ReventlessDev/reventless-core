/**
AWS Key Management Service: the three calls an envelope-encryption key hierarchy
needs. A KMS key never leaves KMS; it wraps a data key, which is generated here,
used in memory, and stored only in its wrapped form.

The client is a module-level singleton, as the other clients here are.
*/
type client

type clientConfig = {region?: string}

module Raw = {
  @module("@aws-sdk/client-kms") @new
  external client: clientConfig => client = "KMSClient"
}

let clientInstance = ref(None)

let client = () =>
  switch clientInstance.contents {
  | Some(c) => c
  | None =>
    let c = Raw.client({})
    clientInstance := Some(c)
    c
  }

/** Bytes as the SDK hands them back: a `Uint8Array`. */
type bytes = Uint8Array.t

/** Which key a call addresses: an id, an ARN, or an alias (`alias/<name>`). */
type keyId = string

module GenerateDataKey = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/kms/command/GenerateDataKeyCommand/ */
  type t
  type input = {
    @as("KeyId") keyId: keyId,
    /** `AES_256` for a 32-byte key. */
    @as("KeySpec") keySpec?: string,
    @as("EncryptionContext") encryptionContext?: dict<string>,
  }
  type output = {
    @as("KeyId") keyId?: string,
    /** The data key, in the clear: use it in memory, never store it. */
    @as("Plaintext") plaintext?: bytes,
    /** The data key wrapped by the KMS key: what is stored. */
    @as("CiphertextBlob") ciphertextBlob?: bytes,
  }
  module Raw = {
    @module("@aws-sdk/client-kms") @new external make: input => t = "GenerateDataKeyCommand"
    @send external send: (client, t) => promise<output> = "send"
  }
  let send = (input: input): promise<output> => client()->Raw.send(Raw.make(input))
}

module Encrypt = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/kms/command/EncryptCommand/ */
  type t
  type input = {
    @as("KeyId") keyId: keyId,
    @as("Plaintext") plaintext: bytes,
    @as("EncryptionContext") encryptionContext?: dict<string>,
  }
  type output = {
    @as("KeyId") keyId?: string,
    @as("CiphertextBlob") ciphertextBlob?: bytes,
  }
  module Raw = {
    @module("@aws-sdk/client-kms") @new external make: input => t = "EncryptCommand"
    @send external send: (client, t) => promise<output> = "send"
  }
  let send = (input: input): promise<output> => client()->Raw.send(Raw.make(input))
}

module Decrypt = {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/kms/command/DecryptCommand/ */
  type t
  type input = {
    @as("CiphertextBlob") ciphertextBlob: bytes,
    /** Optional for a symmetric key, which the blob names; stating it refuses a
        blob wrapped by any other key. */
    @as("KeyId") keyId?: keyId,
    @as("EncryptionContext") encryptionContext?: dict<string>,
  }
  type output = {
    @as("KeyId") keyId?: string,
    @as("Plaintext") plaintext?: bytes,
  }
  module Raw = {
    @module("@aws-sdk/client-kms") @new external make: input => t = "DecryptCommand"
    @send external send: (client, t) => promise<output> = "send"
  }
  let send = (input: input): promise<output> => client()->Raw.send(Raw.make(input))
}
