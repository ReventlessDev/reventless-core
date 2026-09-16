// A deploy stops when no Reventless layer is found, and these suites create
// functions — some at import time — so they get a stand-in rather than a lookup
// in whatever AWS account the shell happens to reach.
process.env.REVENTLESS_LAYER_ARN =
  "arn:aws:lambda:eu-central-1:000000000000:layer:reventless-test:1";
