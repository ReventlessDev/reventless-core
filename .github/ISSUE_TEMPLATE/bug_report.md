---
name: Bug Report
about: Report a bug or unexpected behavior
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description
A clear and concise description of what the bug is.

## Steps to Reproduce
```rescript
// Include minimal ReScript code that reproduces the issue
```

Or steps to reproduce:
1. Initialize project with `...`
2. Configure aggregate/read model with `...`
3. Deploy/run with `...`
4. Observe error

## Expected Behavior
What you expected to happen.

## Actual Behavior
What actually happened. Include error messages and stack traces.

## Environment
- **Node version**: (run `node --version`)
- **ReScript version**: (run `npx rescript -version`)
- **Package(s)**: (e.g., @reventless/reventless@1.0.0, @reventless/reventless-aws@1.0.0)
- **AWS Region** (if applicable):
- **OS**: (e.g., macOS 13.0, Ubuntu 22.04, AWS Lambda Node.js 22.x)

## Error Logs
```
Paste relevant error messages, stack traces, or build output here
```

## Infrastructure Configuration (if applicable)
```rescript
// Relevant Pulumi/infrastructure code
```

## Additional Context
- Is this a deploy-time error or runtime error?
- Does this occur during local development, deployment, or execution?
- Any relevant AWS CloudWatch logs or Lambda error messages?
