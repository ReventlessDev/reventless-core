[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-aws-sdk.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-aws-sdk)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-aws-sdk

> ⚠️ **Alpha.** APIs and on-disk formats can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [aws-sdk](https://github.com/aws/aws-sdk-js).  
Also see the [official documentation](https://docs.aws.amazon.com/AWSJavaScriptSDK/latest/AWS.html).

## Install

```bash
pnpm add @reventlessdev/rescript-aws-sdk aws-sdk
```

> If you deploy to AWS Lambda you don't need `aws-sdk` in your dependencies — the runtime provides it.

Add it to your `rescript.json` dependencies:

```json
{
  "dependencies": ["@reventlessdev/rescript-aws-sdk"]
}
```

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
