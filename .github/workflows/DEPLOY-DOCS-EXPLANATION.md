# Documentation Deployment Workflow

## Overview

This workflow builds and deploys multi-version documentation to GitHub Pages with intelligent branch handling.

## Key Features

### 1. **Resilient Branch Handling**
- Checks if branches exist before attempting to build
- Gracefully handles missing branches (e.g., if beta branch doesn't exist yet)
- Never fails due to missing branches

### 2. **Incremental Builds**
- **On push**: Builds only the changed branch's documentation
- **On manual trigger** (`workflow_dispatch`): Builds all existing branches

### 3. **Download & Merge Strategy**
When building only one branch:
1. Downloads existing deployed documentation from GitHub Pages
2. Builds only the changed branch
3. Overwrites only that branch's folder in the build output
4. Deploys the merged result (preserving other versions)

## Branch Behavior

| Event Type | Trigger | Behavior |
|------------|---------|----------|
| Push to `main` | Docs changed in main | Downloads existing site → Builds main → Merges → Deploys |
| Push to `beta` | Docs changed in beta | Downloads existing site → Builds beta → Merges → Deploys |
| Push to `alpha` | Docs changed in alpha | Downloads existing site → Builds alpha → Merges → Deploys |
| Manual trigger | workflow_dispatch | Builds all existing branches from scratch |

## Directory Structure

```
build-output/
├── index.html              # Main (latest) documentation
├── versions.html           # Version selector page
├── beta/                   # Beta documentation (if branch exists)
│   └── index.html
└── alpha/                  # Alpha documentation (if branch exists)
    └── index.html
```

## Example Scenarios

### Scenario 1: Beta branch doesn't exist
- Push to `alpha` branch
- Workflow checks branches: ✓ main, ✗ beta, ✓ alpha
- Downloads existing site (contains main and alpha)
- Builds only alpha documentation
- Deploys: main (preserved) + alpha (updated)

### Scenario 2: First deployment (no existing docs)
- Push to `main` branch
- Download step finds no existing docs
- Builds only main documentation
- Deploys: main only

### Scenario 3: Manual full rebuild
- Trigger workflow_dispatch
- Checks all branches: ✓ main, ✗ beta, ✓ alpha
- Builds main and alpha (skips beta)
- Deploys: fresh builds of all existing branches

## Benefits

1. **Faster CI**: Only rebuilds changed documentation
2. **Resilient**: Handles missing branches gracefully
3. **Complete**: Always serves full multi-version documentation
4. **Efficient**: Preserves unchanged versions instead of rebuilding
