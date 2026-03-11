/*** bindings for `@aws-sdk/util-dynamodb`dynamoutil
  https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-util-dynamodb

  in aws sdk v2 this was `aws-sdk/DynamoDb/Converter`
*/

type rec attributeValue = {
  /** `B`inary attribute */
  @as("B")
  binary?: Js.TypedArray2.Uint8Array.t,
  @as("BOOL") bool?: bool,
  @as("BS") binarySet?: array<Js.TypedArray2.Uint8Array.t>,
  @as("L") list?: array<attributeValue>,
  @as("M") map?: dict<attributeValue>,
  @as("N") number?: string,
  @as("NS") numberSet?: array<string>,
  @as("NULL") null?: bool,
  @as("S") string?: string,
  @as("SS") stringSet?: array<string>,
  @as("$unknown") unknown?: (string, unknown),
}

module MarshallOptions: {
  /*** see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-util-dynamodb/Interface/marshallOptions/ */

  type options = {
    /** Whether to automatically convert empty strings, blobs, and sets to `null` */
    convertEmptyValues?: bool,
    /** Whether to remove undefined values while marshalling. */
    removeUndefinedValues?: bool,
    /** Whether to convert typeof object to map attribute. */
    convertClassInstanceToMap?: bool,
    /** Whether to convert the top level container if it is a map or list. */
    convertTopLevelContainer?: bool,
    wrapNumbers?: bool,
  }

  /**
  The `marshall` function returns different types depending on `option.convertTopLevelContainer`.
  To model this, the phantom type (parameter) `'output` is used. This type is abstract to enforce proper creation with one of this functions:
    - `topLevelContainerConverted`
    - `topLevelContainerNotConverted`
  */
  type t<'output>

  external toOptions: t<'output> => options = "%identity"

  /** create objections with `convertTopLevelContainer` set to `true` */
  let topLevelContainerConverted: (
    ~convertEmptyValues: bool=?,
    ~removeUndefinedValues: bool=?,
    ~convertClassInstanceToMap: bool=?,
    ~wrapNumbers: bool=?,
  ) => t<attributeValue>

  /** create objections with `convertTopLevelContainer` set to `false` */
  let topLevelContainerNotConverted: (
    ~convertEmptyValues: bool=?,
    ~removeUndefinedValues: bool=?,
    ~convertClassInstanceToMap: bool=?,
    ~wrapNumbers: bool=?,
  ) => t<dict<attributeValue>>
} = {
  type options = {
    convertEmptyValues?: bool,
    removeUndefinedValues?: bool,
    convertClassInstanceToMap?: bool,
    convertTopLevelContainer?: bool,
    wrapNumbers?: bool,
  }

  type t<'output> = options

  external toOptions: t<'output> => options = "%identity"

  /** convert the top level container into an attributeValue if it is a map or list. */
  let topLevelContainerConverted = (
    ~convertEmptyValues=?,
    ~removeUndefinedValues=?,
    ~convertClassInstanceToMap=?,
    ~wrapNumbers=?,
  ) => {
    {
      ?convertEmptyValues,
      ?removeUndefinedValues,
      ?convertClassInstanceToMap,
      convertTopLevelContainer: true,
      ?wrapNumbers,
    }
  }

  /** do NOT convert the top level container into an attributeValue if it is a map or list. */
  let topLevelContainerNotConverted = (
    ~convertEmptyValues=?,
    ~removeUndefinedValues=?,
    ~convertClassInstanceToMap=?,
    ~wrapNumbers=?,
  ) => {
    {
      ?convertEmptyValues,
      ?removeUndefinedValues,
      ?convertClassInstanceToMap,
      convertTopLevelContainer: false,
      ?wrapNumbers,
    }
  }
}

/** Convert JavaScript object into DynamoDB Record
  see: https://github.com/aws/aws-sdk-js-v3/blob/de4dc495455a47cd718c635209cd7aef9167797c/packages/util-dynamodb/src/marshall.ts#L40
*/
@module("@aws-sdk/util-dynamodb")
external marshall: ('a, ~options: MarshallOptions.t<'output>=?) => 'output = "marshall"

module Raw = {
  type unmarshallOptions = {
    /** When true, skip wrapping the data in { M: data } before converting. Default is true when using the DynamoDBDocumentClient, but false if directly using the unmarshall function (backwards compatibility).

  Set this to false if top level data is dict<attributeValue>
  */
    convertWithoutMapWrapper?: bool,
    /** Whether to return numbers as a string instead of converting them to native JavaScript numbers. This allows for the safe round-trip transport of numbers of arbitrary size. */
    wrapNumbers?: bool,
  }
  @module("@aws-sdk/util-dynamodb")
  external unmarshall: ('data, ~options: unmarshallOptions) => 'output = "unmarshall"
}

