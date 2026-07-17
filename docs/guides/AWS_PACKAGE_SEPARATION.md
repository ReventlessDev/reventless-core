# AWS Package Separation Analysis

## Overview

This document analyzes the potential extraction of AWS-specific packages from the Reventless monorepo into a separate repository. It examines the current state, identifies architectural issues, and provides a comprehensive assessment of the pros and cons of repository separation.

## Current State

### AWS-Specific Packages

The monorepo currently contains four AWS-specific packages:

1. **aws-lambda-layer** - Build tooling for Lambda layers
2. **rescript-aws-sdk** - ReScript bindings for aws-sdk
3. **rescript-pulumi-aws** - ReScript bindings for @pulumi/aws
4. **reventless-aws** - AWS adapter implementations

### Architectural Issue: Core Coupling

**Critical finding:** The core `reventless` package is currently coupled to AWS packages, contradicting the stated architecture of being "provider-agnostic."

Both `packages/reventless/package.json` and `rescript.json` declare dependencies on:
- `@reventless/rescript-aws-sdk`
- `@reventless/rescript-pulumi-aws`

This coupling prevents the core framework from being truly provider-agnostic and makes it difficult to support other cloud providers (Azure, GCP, etc.) without carrying AWS dependencies.

## Pros of Separate Repository

### 1. Enforces Architectural Separation

- **Forces proper provider-agnostic design** - Makes it architecturally impossible to accidentally couple core to AWS
- **Clear boundaries** - Separates generic framework concerns from cloud provider implementations
- **Better abstraction** - Core must rely solely on adapter interfaces, not concrete implementations

### 2. Independent Versioning & Release Cycles

- **Decoupled releases** - AWS packages can evolve at their own pace without forcing core releases
- **Focused changelogs** - Users only see changes relevant to their concerns
- **Reduced dependency noise** - Users not using AWS don't download AWS dependencies
- **Faster iteration** - AWS-specific features can be added without core framework review overhead

### 3. Clearer Ownership & Governance

- **Separate maintainers** - Different teams can own core vs cloud providers
- **Focused contributions** - Easier to accept AWS-specific PRs without core governance overhead
- **Independent CI/CD** - Different security scanning, compliance checks, and deployment pipelines
- **Clearer issue tracking** - AWS bugs go to AWS repo, core bugs go to core repo

### 4. Reduced Cognitive Load

- **Focused context** - Core developers don't see AWS implementation details
- **Easier onboarding** - New contributors can focus on one concern
- **Cleaner codebase** - Each repository is smaller and more focused
- **Better documentation** - Each repo can have documentation specific to its domain

### 5. Better for Future Cloud Providers

- **Sets precedent** - Establishes pattern for Azure, GCP, Cloudflare, etc. implementations
- **Parallel development** - Multiple provider implementations can evolve independently
- **Demonstrates provider-agnosticism** - Core framework proves it works without AWS

## Cons of Separate Repository

### 1. Development Workflow Complexity

- **Cross-repo changes** - Need `npm link` or pre-release versions for testing changes across repositories
- **Breaking changes coordination** - Interface changes in core require immediate AWS package updates
- **More complex CI/CD** - Need to test AWS packages against multiple core versions
- **Local development setup** - More complex bootstrap process for developers working on both

### 2. Versioning Coordination

- **Compatibility matrix** - Must document and maintain which AWS versions work with which core versions
- **Semantic-release complexity** - Need to coordinate releases across repositories
- **Dependency hell risk** - Users may encounter version conflicts more easily
- **Testing matrix explosion** - CI must test multiple version combinations

### 3. Monorepo Benefits Lost

- **No unified build** - Can't use `lerna run build` to build everything at once
- **No atomic commits** - Can't make changes spanning core + AWS in a single commit
- **Refactoring friction** - Interface changes touching both repos require multiple PRs
- **Lerna features unavailable** - Lose automatic dependency linking and bootstrapping

### 4. Discovery & Documentation

- **Fragmented discovery** - Users might not easily find AWS packages from core repo
- **Documentation spanning repos** - Need to maintain links and coordination across repositories
- **Multiple README files** - Have to keep multiple entry points in sync
- **Search complexity** - GitHub search won't find results across both repos easily

### 5. Initial Migration Effort

- **Extraction work** - Carefully extract packages with full git history
- **Import path updates** - Update all `@reventless/*` imports and dependencies
- **Registry configuration** - Set up new GitHub Package Registry for AWS packages
- **CI/CD migration** - Replicate and adapt workflows to new repository
- **Issue migration** - Move AWS-related issues to new repo
- **Documentation updates** - Update all references to package locations
- **User migration** - Existing users need to update their dependencies
- **Breaking change** - Major version bump required

### 6. Lerna/Monorepo Tooling Loss

- **Manual dependency management** - Can't rely on Lerna to link local packages
- **Bootstrap complexity** - Setting up dev environment requires more steps
- **Workspace features lost** - Can't use npm/yarn workspaces across repos
- **Testing cross-package changes** - Requires publishing or linking manually

## Recommendation

### Recommended Approach: Two-Phase Split

We recommend splitting the repository, but only after properly decoupling the core from AWS dependencies.

#### Phase 1: Decouple Core from AWS (Do This First!)

**Goal:** Make the core framework truly provider-agnostic.

**Steps:**
1. **Audit core dependencies** - Identify all AWS package usage in `packages/reventless/src`
2. **Remove AWS dependencies** - Delete AWS packages from `packages/reventless/package.json` and `rescript.json`
3. **Verify compilation** - Ensure core builds without AWS packages
4. **If AWS code found in core:**
   - Extract to proper adapter interfaces
   - Move concrete implementations to `reventless-aws`
   - Ensure core only depends on `reventless-spec` (interfaces)
5. **Test thoroughly** - Run all core tests without AWS packages available
6. **Update documentation** - Clarify core is provider-agnostic

**Success criteria:**
- Core package has zero dependencies on AWS-specific packages
- Core tests pass without AWS packages installed
- Adapter pattern properly enforces provider separation

#### Phase 2: Split Repository (After Core is Clean)

**Goal:** Create independent `reventless-aws` repository.

**Steps:**

1. **Create new repository: `reventless-aws`**
   - Initialize with same governance structure
   - Set up GitHub Package Registry
   - Configure CI/CD pipelines

2. **Extract packages with git history:**
   ```bash
   # Use git filter-repo or similar to extract package history
   git filter-repo --path packages/aws-lambda-layer/
   git filter-repo --path packages/rescript-aws-sdk/
   git filter-repo --path packages/rescript-pulumi-aws/
   git filter-repo --path packages/reventless-aws/
   ```

3. **Update package configurations:**
   - Change package names if desired (e.g., from `@reventless/` to `@reventless-aws/`)
   - Set up Lerna in new repo
   - Configure semantic-release
   - Update import paths

4. **Set up version compatibility:**
   - Document which AWS package versions support which core versions
   - Add peer dependency on core: `"@reventless/reventless": "^2.x || ^3.x"`
   - Set up CI to test against multiple core versions

5. **Update documentation:**
   - Main README: Add "Cloud Provider Implementations" section
   - Link to `reventless-aws` repository
   - Document installation: `npm install @reventless/reventless @reventless/aws`
   - Create compatibility matrix

6. **Migration guide:**
   - Provide clear upgrade path for existing users
   - Explain new package structure
   - Show before/after import examples

7. **Communicate changes:**
   - Blog post explaining the split
   - GitHub announcement
   - Update CHANGELOG with migration instructions

**Success criteria:**
- AWS packages build and test independently
- Core repository has no AWS packages remaining
- Documentation clearly explains the relationship
- Existing users have clear migration path

### Alternative: Keep Together If...

Consider keeping packages in a monorepo if:

- **Single developer/team** - You're the sole maintainer for foreseeable future
- **AWS-only strategy** - No plans to support other cloud providers
- **Fast iteration priority** - You value development speed over architectural purity
- **Early stage** - Project is still experimental and needs flexibility
- **Unified versioning preferred** - You want all packages versioned together

The decision should be based on your specific context:
- How many developers will work on this?
- Are you planning to support multiple cloud providers?
- Is this for open source adoption or internal use?
- What's the expected contribution model?

## Conclusion

Repository separation is architecturally sound and prepares the framework for multi-cloud support. However, the **immediate priority should be decoupling the core from AWS dependencies**, regardless of whether repositories are split. A truly provider-agnostic core is valuable even in a monorepo structure.

The split should be considered after the core is properly decoupled and when:
1. Multiple cloud providers are being actively developed
2. Different teams are maintaining core vs providers
3. AWS packages need faster release cycles than core
4. Clear separation helps with open source adoption
