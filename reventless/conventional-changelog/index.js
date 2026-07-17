const angular = require('conventional-changelog-angular');
const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');

function stripCoAuthoredBy(text) {
  if (!text) return text;
  return text.replace(/\n*Co-Authored-By:.*$/gmi, '').trim() || null;
}

/**
 * Compares current package.json dependencies with the last committed version
 * and returns a list of changed dependencies with their new versions.
 */
function getChangedDependencies(packageDir) {
  try {
    const pkgJsonPath = path.join(packageDir, 'package.json');
    if (!fs.existsSync(pkgJsonPath)) return [];

    const currentPkg = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'));
    const relativePath = path.relative(process.cwd(), pkgJsonPath);

    let previousPkg;
    try {
      const previous = execSync(`git show HEAD:${relativePath}`, {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      previousPkg = JSON.parse(previous);
    } catch {
      return [];
    }

    const changes = [];
    for (const depType of ['dependencies', 'devDependencies', 'peerDependencies']) {
      const current = currentPkg[depType] || {};
      const previous = previousPkg[depType] || {};
      for (const [name, version] of Object.entries(current)) {
        if (previous[name] !== version) {
          changes.push({ name, version, depType });
        }
      }
    }
    return changes;
  } catch {
    return [];
  }
}

module.exports = function(config) {
  return angular(config).then(preset => {
    // Strip Co-Authored-By trailers from changelog entries
    const originalTransform = preset.writerOpts.transform;
    preset.writerOpts.transform = (commit, context) => {
      if (commit.body) commit.body = stripCoAuthoredBy(commit.body);
      if (commit.footer) commit.footer = stripCoAuthoredBy(commit.footer);
      if (commit.notes) {
        commit.notes = commit.notes.map(note => ({
          ...note,
          text: stripCoAuthoredBy(note.text) || note.text
        }));
      }
      if (typeof originalTransform === 'function') {
        return originalTransform(commit, context);
      }
      return commit;
    };

    // When there are no conventional commits for a package (dependency-only bump),
    // inject dependency update entries so the changelog shows what actually changed
    // instead of the generic "Version bump only" message.
    const originalFinalizeContext = preset.writerOpts.finalizeContext;
    preset.writerOpts.finalizeContext = (context, writerOpts, filteredCommits, keyCommit, commits) => {
      if (originalFinalizeContext) {
        context = originalFinalizeContext(context, writerOpts, filteredCommits, keyCommit, commits);
      }

      const hasCommits = context.commitGroups && context.commitGroups.some(
        group => group.commits && group.commits.length > 0
      );

      if (!hasCommits && context.packageData) {
        const packageDir = context.packageData.name && findPackageDir(context.packageData.name);

        if (packageDir) {
          const changes = getChangedDependencies(packageDir);
          if (changes.length > 0) {
            context.dependencyUpdates = changes;
          }
        }
      }

      return context;
    };

    // Modify the main template to include dependency updates section
    preset.writerOpts.mainTemplate = `{{> header}}

{{#each commitGroups}}
{{#if title}}
### {{title}}

{{/if}}
{{#each commits}}
{{> commit root=@root}}
{{/each}}
{{/each}}
{{#if dependencyUpdates}}
### Dependency Updates

{{#each dependencyUpdates}}
* **{{name}}** updated to \`{{version}}\`
{{/each}}
{{/if}}
{{> footer}}
`;

    return preset;
  });
};

/**
 * Finds the directory of a package by name in the monorepo.
 * Walks workspace directories defined in lerna.json to match package names.
 */
function findPackageDir(packageName) {
  try {
    const lernaJson = JSON.parse(fs.readFileSync(
      path.join(process.cwd(), 'lerna.json'), 'utf8'
    ));
    for (const pattern of lernaJson.packages || []) {
      // Convert simple glob patterns (e.g., "packages/*", "examples/**") to directory walks
      const basePath = pattern.replace(/\/?\*+$/, '');
      const baseDir = path.join(process.cwd(), basePath);
      if (!fs.existsSync(baseDir)) continue;

      const candidates = pattern.includes('**')
        ? findPackageDirsRecursive(baseDir)
        : fs.readdirSync(baseDir)
            .map(d => path.join(baseDir, d))
            .filter(d => fs.statSync(d).isDirectory());

      for (const dir of candidates) {
        const pkgPath = path.join(dir, 'package.json');
        if (fs.existsSync(pkgPath)) {
          const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
          if (pkg.name === packageName) return dir;
        }
      }
    }
  } catch {
    // ignore
  }
  return null;
}

function findPackageDirsRecursive(dir) {
  const results = [];
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory() && entry.name !== 'node_modules') {
        const full = path.join(dir, entry.name);
        results.push(full);
        results.push(...findPackageDirsRecursive(full));
      }
    }
  } catch {
    // ignore permission errors
  }
  return results;
}
