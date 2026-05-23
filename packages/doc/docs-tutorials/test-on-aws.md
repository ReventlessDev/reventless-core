---
title: Test it on AWS
sidebar_position: 7
---

# Test the deployed shop

Once the stacks are up (from [Deploy to your AWS account](./deploy-to-aws)), this
page shows how to find the live URLs, sign in, and verify the end-to-end path —
including live subscriptions.

## Find the live URLs

The platform stack exports the endpoints. From `platform-aws/`:

```bash
pulumi stack output --stack alpha
```

Look for the AppSync GraphQL endpoint and the CloudFront URL that serves the
host-shell SPA. Open the CloudFront URL in a browser.

## Log in against deployed Cognito

The deployed platform authenticates against the Cognito user pool configured on
the [deploy page](./deploy-to-aws) (Step 2). A freshly auto-provisioned pool has
no users yet — create one:

```bash
aws cognito-idp admin-create-user \
  --user-pool-id <COGNITO_USER_POOL_ID> \
  --username you@example.com \
  --user-attributes Name=email,Value=you@example.com
# then set a permanent password:
aws cognito-idp admin-set-user-password \
  --user-pool-id <COGNITO_USER_POOL_ID> \
  --username you@example.com --password '<StrongPassw0rd!>' --permanent
```

Sign in to the host-shell with that user and run the same smoke test you ran
locally: add a category and product, register a customer, place an order, and
confirm read models update.

## Verify subscriptions end to end

The example ships a verification script that drives a command and confirms the
change is pushed over a WebSocket subscription — the AWS equivalent of watching
the live view update in the local UI. It exercises **Source B**:

```
AddProduct command → DynamoDB write → DynamoDB Stream → StateTopic Lambda
                   → AppSync Events API → WebSocket subscriber
```

Run it from `platform-aws/`:

```bash
cd examples/online-shop-hybrid/platform-aws
node verify-subscriptions.mjs
```

Requirements:

- AWS credentials with `appsync:EventPublish`, `appsync:EventSubscribe`, and
  `appsync:GraphQL`.
- The Pulumi stack deployed.
- **Update the config block at the top of `verify-subscriptions.mjs`** — the
  AppSync host and API IDs there point at the reference stack. Replace them with
  **your** values from `pulumi stack output` before running.

A successful run publishes an `AddProduct`, subscribes over the WebSocket, and
confirms the resulting event arrives at the subscriber.

## What you've proven

The deployed application runs the identical plugin code you tested locally — now
on real AWS infrastructure (DynamoDB, Lambda, SQS, AppSync, CloudFront, Cognito),
with live subscriptions flowing through the StateTopic Lambda to WebSocket
clients.

---

**Where to next?**

- Build your own application → [App Guide](/app/get-started).
- Point the deployed shell at your own domain →
  [Custom domain for the host UI](/infrastructure/custom-domain).
- Contribute to the framework → [Contributing](/framework/get-started).
