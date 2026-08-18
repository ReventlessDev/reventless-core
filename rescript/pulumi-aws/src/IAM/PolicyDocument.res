/**
 https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_grammar.html
 */
@schema
type version = | @as("2008-10-17") Version2008 | @as("2012-10-17") Version2012

@schema
type effect = Allow | Deny

@schema @unboxed type principalEntry = PrincipalId(string) | PrincipalIds(array<string>)
@schema
type principal = {
  @as("AWS") aws?: principalEntry,
  @as("Federated") federated?: principalEntry,
  @as("Service") service?: principalEntry,
  @as("CanonicalUser") canonicalUser?: principalEntry,
}
@schema @unboxed type principals = | @as("*") AllPrincipals | Principals(principal)

@schema @unboxed
type actions = | @as("*") AllActions | Action(string) | Actions(array<string>)

@schema @unboxed
type resources =
  | @as("*") AllResources
  | Resource(string)
  | Resources(array<string>)

//TODO allow entry like: "key": "singleValue"
@schema @unboxed
type conditionEntry = ConditionValue(string) | ConditionValues(array<string>)
@schema
type conditionMap = dict<conditionEntry>
/**
 https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html#Conditions_Numeric
 */
@schema
type condition = {
  //String condition operators
  @as("StringEquals") stringEquals?: conditionMap,
  @as("StringNotEquals") stringNotEquals?: conditionMap,
  @as("StringEqualsIgnoreCase") stringEqualsIgnoreCase?: conditionMap,
  @as("StringNotEqualsIgnoreCase") stringNotEqualsIgnoreCase?: conditionMap,
  @as("StringLike") stringLike?: conditionMap,
  @as("StringNotLike") stringNotLike?: conditionMap,
  //Numeric condition operators
  @as("NumericEquals") numericEquals?: conditionMap,
  @as("NumericNotEquals") numericNotEquals?: conditionMap,
  @as("NumericLessThan") numericLessThan?: conditionMap,
  @as("NumericLessThanEquals") numericLessThanEquals?: conditionMap,
  @as("NumericGreaterThan") numericGreaterThan?: conditionMap,
  @as("NumericGreaterThanEquals") numericGreaterThanEquals?: conditionMap,
  //Date condition operators
  @as("DateEquals") dateEquals?: conditionMap,
  @as("DateNotEquals") dateNotEquals?: conditionMap,
  @as("DateLessThan") dateLessThan?: conditionMap,
  @as("DateLessThanEquals") dateThanEquals?: conditionMap,
  @as("DateGreaterThan") dateGreaterThan?: conditionMap,
  @as("DateGreaterThanEquals") dateGreaterThanEquals?: conditionMap,
  //Boolean condition operators
  @as("Bool") boolean?: conditionMap,
  //Binary condition operators
  @as("Binary") binary?: conditionMap,
  //ARN condition operators
  @as("ArnEquals") arnEquals?: conditionMap,
  @as("ArnLike") arnLike?: conditionMap,
  @as("ArnNotEquals") arnNotEquals?: conditionMap,
  @as("ArnNotLike") arnNotLike?: conditionMap,
  //If Exists operators
  //String condition operators
  @as("StringEqualsIfExists") stringEqualsIfExists?: conditionMap,
  @as("StringNotEqualsIfExists") stringNotEqualsIfExists?: conditionMap,
  @as("StringEqualsIgnoreCaseIfExists") stringEqualsIgnoreCaseIfExists?: conditionMap,
  @as("StringNotEqualsIgnoreCaseIfExists") stringNotEqualsIgnoreCaseIfExists?: conditionMap,
  @as("StringLikeIfExists") stringLikeIfExists?: conditionMap,
  @as("StringNotLikeIfExists") stringNotLikeIfExists?: conditionMap,
  //Numeric condition operators
  @as("NumericEqualsIfExists") numericEqualsIfExists?: conditionMap,
  @as("NumericNotEqualsIfExists") numericNotEqualsIfExists?: conditionMap,
  @as("NumericLessThanIfExists") numericLessThanIfExists?: conditionMap,
  @as("NumericLessThanEqualsIfExists") numericLessThanEqualsIfExists?: conditionMap,
  @as("NumericGreaterThanIfExists") numericGreaterThanIfExists?: conditionMap,
  @as("NumericGreaterThanEqualsIfExists") numericGreaterThanEqualsIfExists?: conditionMap,
  //Date condition operators
  @as("DateEqualsIfExists") dateEqualsIfExists?: conditionMap,
  @as("DateNotEqualsIfExists") dateNotEqualsIfExists?: conditionMap,
  @as("DateLessThanIfExists") dateLessThanIfExists?: conditionMap,
  @as("DateLessThanEqualsIfExists") dateThanEqualsIfExists?: conditionMap,
  @as("DateGreaterThanIfExists") dateGreaterThanIfExists?: conditionMap,
  @as("DateGreaterThanEqualsIfExists") dateGreaterThanEqualsIfExists?: conditionMap,
  //Boolean condition operators
  @as("BoolIfExists") booleanIfExists?: conditionMap,
  //Binary condition operators
  @as("BinaryIfExists") binaryIfExists?: conditionMap,
  //ARN condition operators
  @as("ArnEqualsIfExists") arnEqualsIfExists?: conditionMap,
  @as("ArnLikeIfExists") arnLikeIfExists?: conditionMap,
  @as("ArnNotEqualsIfExists") arnNotEqualsIfExists?: conditionMap,
  @as("ArnNotLikeIfExists") arnNotLikeIfExists?: conditionMap,
  //Existence check operator
  @as("Null") null?: conditionMap,
}

@schema
type statement = {
  @as("Sid") sid?: string,
  @as("Principal") principal?: principals,
  @as("NotPrincipal") notPrincipal?: principals,
  @as("Effect") effect: effect,
  @as("Action") actions?: actions,
  @as("NotAction") notAction?: actions,
  @as("Resource") resources?: resources,
  @as("NotResource") notResource?: resources,
  @as("Condition") conditions?: condition,
}

@schema
type policy = {
  @as("Version") version: version,
  @as("Id") id?: string,
  @as("Statement") statements: array<statement>, //TODO add single statement support
}
type t = policy

let toJsonString: t => string = t => {
  t
  ->S.decodeOrThrow(~from=policySchema, ~to=S.json)
  ->JSON.stringify(~space=1)
}

let fromJsonString: string => t = (policyString: string) =>
  policyString->S.decodeOrThrow(~from=S.jsonString, ~to=policySchema)

let make = (~version=Version2012, ~id=?, ~statements) => {
  version,
  ?id,
  statements,
}

type mergeArgs = {
  sourcePolicyDocuments: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  policyId: string,
}
type mergeResult = {json: string}

@module("@pulumi/aws") @scope("iam")
external merge: (~args: mergeArgs) => Pulumi.Output.t<mergeResult> = "getPolicyDocumentOutput"

let mergePolicyDocuments: (string, array<t>) => Pulumi.Output.t<string> = (
  policyId,
  policyDocuments,
) => {
  merge(
    ~args={
      sourcePolicyDocuments: policyDocuments
      ->Array.map(policyDocument => policyDocument->toJsonString->Pulumi.Input.make)
      ->Pulumi.Input.make,
      policyId,
    },
  )->Pulumi.Output.apply(policyDocument => {
    policyDocument.json
  })
}
