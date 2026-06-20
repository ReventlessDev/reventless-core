// Point the AWS SDK at DynamoDB Local for the integration suite.
//
// The production adapter builds its DynamoDB client with no explicit endpoint
// (see rescript-aws-sdk/src/DynamoDb_DynamoDb.res), so AWS SDK v3 resolves the
// endpoint from `AWS_ENDPOINT_URL_DYNAMODB`. Dummy credentials satisfy the env
// credential provider (DynamoDB Local ignores their value).
//
// Each line is a no-op if the variable is already set, so CI or a developer can
// override the endpoint/region without editing this file.
process.env.AWS_REGION = process.env.AWS_REGION || "eu-west-1";
process.env.AWS_DEFAULT_REGION = process.env.AWS_DEFAULT_REGION || "eu-west-1";
process.env.AWS_ACCESS_KEY_ID = process.env.AWS_ACCESS_KEY_ID || "local";
process.env.AWS_SECRET_ACCESS_KEY =
  process.env.AWS_SECRET_ACCESS_KEY || "local";
process.env.AWS_ENDPOINT_URL_DYNAMODB =
  process.env.AWS_ENDPOINT_URL_DYNAMODB || "http://localhost:8000";
