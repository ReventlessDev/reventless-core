@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external lambdaFullAccess: string = "LambdaFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external cognitoPowerUser: string = "AmazonCognitoPowerUser"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external dynamoDBFullAccess: string = "AmazonDynamoDBFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external iamFullAccess: string = "IAMFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external s3FullAccess: string = "AmazonS3FullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external snsFullAccess: string = "AmazonSNSFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external sqsFullAccess: string = "AmazonSQSFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external xrayFullAccess: string = "AWSXrayFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external cloudWatchFullAccess: string = "CloudWatchFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external cloudWatchEventsFullAccess: string = "CloudWatchEventsFullAccess"

@val @module("@pulumi/aws/iam") @scope("ManagedPolicy")
external lambdaVPCAccessExecutionRole: string = "AWSLambdaVPCAccessExecutionRole"
