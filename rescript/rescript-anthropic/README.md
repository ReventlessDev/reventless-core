[![npm](https://img.shields.io/npm/v/@reventlessdev/rescript-anthropic.svg?label=npm)](https://www.npmjs.com/package/@reventlessdev/rescript-anthropic)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Docs](https://img.shields.io/badge/docs-reventless.dev-blue)](https://docs.reventless.dev)

# @reventlessdev/rescript-anthropic

> ⚠️ **Alpha.** APIs can change without notice between releases.
> Pin exact versions and expect breaking changes.

ReScript bindings for [`@anthropic-ai/sdk`](https://github.com/anthropics/anthropic-sdk-typescript) and the [`@anthropic-ai/claude-agent-sdk`](https://github.com/anthropics/claude-agent-sdk-typescript), used across the [Reventless](https://docs.reventless.dev) framework. It binds `@anthropic-ai/sdk` `^0.71.0` (bundled dependency) and, optionally, `@anthropic-ai/claude-agent-sdk` `>=0.3.0`.

## Install

```bash
pnpm add @reventlessdev/rescript-anthropic
```

Then register it as a ReScript dependency in `rescript.json`:

```json
{
  "dependencies": ["@reventlessdev/rescript-anthropic"]
}
```

Requires ReScript `^12.3.0` (peer dependency). The `@anthropic-ai/claude-agent-sdk` (`>=0.3.0`) is an optional peer dependency — install it only if you use the agent-SDK bindings.

## Usage

The bindings are exposed as ReScript modules:

- `Anthropic` — bindings for `@anthropic-ai/sdk`.
- `AnthropicAgentSdk` — bindings for `@anthropic-ai/claude-agent-sdk`.
- `AnthropicZod` — Zod helpers used by the SDK bindings.

## Links

- 📚 Documentation — [docs.reventless.dev](https://docs.reventless.dev)
- 📦 Repository — [ReventlessDev/reventless-core](https://github.com/ReventlessDev/reventless-core)
- 📋 [Changelog](./CHANGELOG.md)
- 🔗 Upstream — [`@anthropic-ai/sdk`](https://github.com/anthropics/anthropic-sdk-typescript)

## License

[Apache-2.0](https://opensource.org/licenses/Apache-2.0)
