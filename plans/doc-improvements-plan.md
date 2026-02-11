# Documentation Improvements Plan

## Overview

This plan outlines the changes needed to improve the Reventless documentation structure by:
1. Removing redundant/incomplete pages
2. Renaming a key overview page for clarity
3. Filling in missing content for the Config module
4. Updating all references to maintain working links

## Current State Analysis

### Files to Remove
- [`advanced.md`](../packages/doc/docs/advanced.md) - Contains minimal content about Extension Points that's better covered in component-specific docs
- [`reventless-component-relations.md`](../packages/doc/docs/reventless-component-relations.md) - Contains Mermaid diagrams showing component relationships
- [`reventless-common-modules/counter.md`](../packages/doc/docs/reventless-common-modules/counter.md) - Stub with TODO to move content elsewhere

### Files to Rename
- [`reventless-components-overview.md`](../packages/doc/docs/reventless-components-overview.md) → `component-overview.md`

### Files to Update
- [`reventless-common-modules/config.md`](../packages/doc/docs/reventless-common-modules/config.md) - Currently just contains a TODO, needs comprehensive content

### Files with References That Need Updating

Based on search results, the following files reference the pages being modified:

**References to `advanced.md` (2 occurrences):**
- [`index.md`](../packages/doc/docs/index.md):95 - "Learn about [avanced usage](./advanced.md)"

**References to `reventless-component-relations.md` (2 occurrences):**
- [`reventless-components/aggregate.md`](../packages/doc/docs/reventless-components/aggregate.md):57
- [`inner-workings/framework-inner-workings.md`](../packages/doc/docs/inner-workings/framework-inner-workings.md):99

**References to `reventless-components-overview.md` (23 occurrences across multiple files):**
- Multiple component documentation files link to sections in this overview
- [`get-started.md`](../packages/doc/docs/get-started.md):26
- [`inner-workings/framework-inner-workings.md`](../packages/doc/docs/inner-workings/framework-inner-workings.md):98
- [`inner-workings/aws-adapters/index.md`](../packages/doc/docs/inner-workings/aws-adapters/index.md):11
- [`inner-workings/resources.md`](../packages/doc/docs/inner-workings/resources.md):369
- All component documentation files in `reventless-components/`:
  - aggregate.md, readmodel.md, task.md, plugin.md, extension.md, extensionpoint.md
  - eventlog.md, eventtopic.md, commandtopic.md, commandgenerator.md
  - eventcollector.md, eventmapper.md, querydb.md, counter.md
  - heartbeat.md, scheduler.md, sideeffecthandler.md

## Implementation Steps

### 1. Update Sidebar Configuration

File: [`packages/doc/sidebars.js`](../packages/doc/sidebars.js)

Changes needed:
- Line 21: Change `'reventless-components-overview'` to `'component-overview'`
- Line 22: Remove `'reventless-component-relations'`
- Line 53: Remove `'reventless-common-modules/counter'`
- Line 56: Remove `'advanced'`

### 2. Update Link References

#### In [`index.md`](../packages/doc/docs/index.md)
- Remove or replace lines 95-96 that reference advanced.md
- Suggest: Either remove the "Learn about advanced usage" section or replace with link to Extension Points documentation

#### In [`aggregate.md`](../packages/doc/docs/reventless-components/aggregate.md)
- Line 57: Change reference from `reventless-component-relations.md#runtime-communication` to appropriate alternative
- Suggest: Remove this reference or replace with inline explanation of command sources

#### In [`framework-inner-workings.md`](../packages/doc/docs/inner-workings/framework-inner-workings.md)
- Line 98: Change `../reventless-components-overview.md` to `../component-overview.md`
- Line 99: Remove or replace reference to `../reventless-component-relations.md`

#### In [`resources.md`](../packages/doc/docs/inner-workings/resources.md)
- Line 369: Change reference from `../reventless-components-overview.md` to `../component-overview.md`

#### In [`get-started.md`](../packages/doc/docs/get-started.md)
- Line 26: Change `./reventless-components-overview.md` to `./component-overview.md`

#### In [`aws-adapters/index.md`](../packages/doc/docs/inner-workings/aws-adapters/index.md)
- Line 11: Change `../reventless-components-overview.md` to `../component-overview.md`

#### In All Component Documentation Files
Update references in these 17 files to change `reventless-components-overview.md` to `component-overview.md`:
- aggregate.md, readmodel.md, task.md, plugin.md
- extension.md, extensionpoint.md
- eventlog.md, eventtopic.md, commandtopic.md, commandgenerator.md
- eventcollector.md, eventmapper.md, querydb.md, counter.md
- heartbeat.md, scheduler.md, sideeffecthandler.md

Pattern to replace: `../reventless-components-overview.md` → `../component-overview.md`

### 3. Write Config Documentation

File: [`packages/doc/docs/reventless-common-modules/config.md`](../packages/doc/docs/reventless-common-modules/config.md)

Content to add based on [`Config.res`](../packages/reventless/src/Config.res):

```markdown
---
title: Config
date: 2024-08-13
draft: false
---

# Config Module

The Config module defines the configuration interface that plugins use to access shared infrastructure resources and settings within a Reventless application.

## Module Type Definition

The Config module type is defined as follows:

```rescript
module type T = {
  type api
  type role
  type userPool

  let pluginName: string

  let api: api
  let apiRole: role
  let userPoolId: Pulumi.Output.t<string>

  let scheduler: Pulumi.Output.t<Scheduler.operations>
}
```

## Configuration Fields

### Type Parameters

- **`api`** - Abstract type representing the API Gateway instance
- **`role`** - Abstract type representing IAM role resources
- **`userPool`** - Abstract type representing Cognito User Pool resources

### Required Fields

- **`pluginName: string`** - Unique identifier for the plugin within the application

- **`api: api`** - Reference to the shared API Gateway instance that the plugin's endpoints will be attached to

- **`apiRole: role`** - IAM role used by the API Gateway to invoke Lambda functions

- **`userPoolId: Pulumi.Output.t<string>`** - Cognito User Pool ID for authentication integration

- **`scheduler: Pulumi.Output.t<Scheduler.operations>`** - Reference to the shared scheduler component for scheduled task execution

## Usage

The Config module is typically created at the application/stack level and passed to plugins during initialization. Each plugin receives the same configuration, allowing them to:

1. Register API endpoints with the shared API Gateway
2. Use common authentication via the User Pool
3. Schedule recurring tasks via the shared Scheduler
4. Maintain consistent IAM permissions via the shared role

## Example

```rescript
// In your stack/application setup
module MyConfig = {
  type api = Pulumi.Aws.ApiGateway.RestApi.t
  type role = Pulumi.Aws.Iam.Role.t
  type userPool = Pulumi.Aws.Cognito.UserPool.t

  let pluginName = "my-plugin"
  let api = myApiGatewayInstance
  let apiRole = myIamRole
  let userPoolId = myUserPool.id
  let scheduler = schedulerOperations
}

// Pass to plugin
module MyPlugin = Plugin.Make(MyPluginSpec, MyConfig)
```

## Related Documentation

- [Plugin Component](../reventless-components/plugin.md) - Plugins consume Config
- [Scheduler Component](../reventless-components/scheduler.md) - Scheduler operations
- [API Component](../reventless-components/api.md) - API Gateway integration
```

### 4. Rename File

Rename [`reventless-components-overview.md`](../packages/doc/docs/reventless-components-overview.md) to `component-overview.md`

### 5. Delete Files

Remove these files:
- [`advanced.md`](../packages/doc/docs/advanced.md)
- [`reventless-component-relations.md`](../packages/doc/docs/reventless-component-relations.md)
- [`reventless-common-modules/counter.md`](../packages/doc/docs/reventless-common-modules/counter.md)

## Rationale

### Why Remove `advanced.md`?
- Contains only 25 lines with minimal content about Extension Points
- Content is already covered more thoroughly in:
  - [`extensionpoint.md`](../packages/doc/docs/reventless-components/extensionpoint.md)
  - [`extension.md`](../packages/doc/docs/reventless-components/extension.md)
- Has a TODO for adding diagrams that were never completed
- Removing reduces duplication and maintenance burden

### Why Remove `reventless-component-relations.md`?
- Contains primarily Mermaid diagrams showing component relationships
- Only 2 references in the codebase (aggregate.md and framework-inner-workings.md)
- Diagrams may be outdated or redundant with component-specific documentation
- Can be reconsidered later if visual relationship diagrams are needed

### Why Remove `counter.md` from Common Modules?
- Contains only a TODO note to move content elsewhere
- The Counter component is already documented in:
  - [`reventless-components/counter.md`](../packages/doc/docs/reventless-components/counter.md)
  - [`inner-workings/aws-adapters/counter.md`](../packages/doc/docs/inner-workings/aws-adapters/counter.md)
- Removing eliminates stub documentation

### Why Rename to `component-overview.md`?
- Shorter, clearer name
- "Reventless" prefix is redundant within Reventless documentation
- Aligns with common documentation naming conventions
- Easier to reference and remember

### Why Fill `config.md`?
- Config module is a critical shared interface used by all plugins
- Currently only contains a TODO, which is incomplete documentation
- Developers need to understand how to configure plugins properly
- Based on [`Config.res`](../packages/reventless/src/Config.res), clear structure exists to document

## Testing Plan

After implementation:

1. **Build Documentation Site**
   ```bash
   cd packages/doc
   npm run build
   ```
   - Verify no broken links
   - Verify sidebar renders correctly

2. **Local Preview**
   ```bash
   npm run start
   ```
   - Navigate through documentation
   - Test all updated links
   - Verify removed pages return 404
   - Verify renamed page is accessible

3. **Link Verification**
   - Check all 23 component documentation files load correctly
   - Verify section anchors still work (e.g., `#aggregate`, `#readmodel`)
   - Test cross-references between pages

## Notes

- All file operations should preserve git history where possible
- Consider keeping Mermaid diagrams from component-relations.md in a backup for potential future use
- The Config module documentation should be reviewed by someone familiar with plugin configuration