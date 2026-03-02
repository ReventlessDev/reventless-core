// AWS-specific resource naming operations

let invalidNameChars = /[^.\-_a-zA-Z0-9]/g

let validateName = String.replaceRegExp(_, invalidNameChars, "_")

// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
let urnName: string => string = arn =>
  arn->String.split(":")->Array.get(5)->Option.getOr("unknown")

// Export as operations interface
let operations: ReventlessInfra.ResourceNaming.operations = {
  validateName,
  urnName,
}
