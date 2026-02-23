let invalidNameChars = /[^.\-_a-zA-Z0-9]/g

let validateName = String.replaceRegExp(_, invalidNameChars, "_")

// Example ARN: arn:aws:sqs:eu-west-1:xxxxxx:MarketplaceServiceExtensionPointCommandTopic-0101023
let arn2Name: string => string = arn =>
  arn->String.split(":")->Array.get(5)->Option.getOr("unknown")
