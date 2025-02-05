import { resolve as resolvePath, dirname } from 'node:path';
import { fileURLToPath } from 'node:url'
import { cp } from 'node:fs';
import fs from 'fs';
import path from 'path';
import ora from 'ora';
import pacote from 'pacote';
import Arborist from '@npmcli/arborist';
import treeverse from 'treeverse';
import Pino from 'pino';
import { zip } from 'zip-a-folder';

const { depth } = treeverse;

const spinner = ora();
const log = Pino({
  level: process.env.PINO_LOG_LEVEL || 'info',
  transport: {
    target: 'pino-pretty'
  },
});

const __dirname = dirname(fileURLToPath(import.meta.url));
const pathToLayerData = resolvePath(__dirname, 'layer/');
const pathToSavedDependencies = resolvePath(__dirname, 'layer/nodejs/node_modules');
const pathToPrecompiled = resolvePath(__dirname, 'precompiled/');

const npmPackages = ['npm-bundled', 'npm-install-checks', 'npm-normalize-package-bin', 'npm-package-arg',
  'npm-packlist', 'npm-pick-manifest', 'npm-registry-fetch', 'npm-run-path']

const options = {
  sourcePackageName: '@reventless/reventless-aws',
  sourcePackageVersion: '2.0.3-runtime.15',
  pathToLayerData,
  pathToSavedDependencies,
  pathToPrecompiled,
  precompiledModules: { '@rescript-labs/decco': '@rescript-labs/decco@2.0.4' },
  includePrecompiledModules: { '@reventless/rescript-moment': 'bs-moment@0.8.0' },
  excludeScopes: ['@pulumi', '@types', '@opentelemetry', '@aws-sdk', '@smithy', '@protobufjs', '@npmcli', '@sigstore'],
  excludeModules: ['rescript', 'treeverse', 'pacote', ...npmPackages],
  excludedFileFormats: ['.res', '.resi', '.ts', '.cts'],
  gitlabOpts: {
    "@fidap-wm-raw:registry": "https://gitlab.com/api/v4/packages/npm/",
    "@fidap:registry": "https://gitlab.com/api/v4/packages/npm/",
    "@reventless:registry": "https://gitlab.com/api/v4/packages/npm/",
    "//gitlab.com/api/v4/projects/40879371/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
    "//gitlab.com/api/v4/projects/43406890/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
    "//gitlab.com/api/v4/projects/24127696/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
    "//gitlab.com/api/v4/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN
  }
};

//This should be boxed somewhere, as it does not work in promises otherwise
var extractionCount = 0;
var skippedExtractionCount = 0;

async function cleanup(opts) {
  spinner.start('Preparing to build Layer');
  return deleteFolderContents(opts.pathToSavedDependencies)
    .then(() => {
      spinner.succeed('Cleanup successful');
    }).catch(err => {
      spinner.fail(`Cleanup failed ${err}`);
      throw err;
    });
}

async function build(opt) {
  const { sourcePackageName, sourcePackageVersion, pathToLayerData, pathToSavedDependencies, pathToPrecompiled, excludeScopes, excludeModules, postProcess } = opt;

  const rootPath = path.resolve(pathToSavedDependencies, sourcePackageName)
  const sourcePackageVersionStr = (sourcePackageVersion) ? sourcePackageVersion : 'latest';
  const sourcePackageSpec = `${sourcePackageName}@${sourcePackageVersionStr}`

  log.info('root module: %s', sourcePackageSpec);
  log.info('storing modules in: %s', pathToSavedDependencies);
  log.info('storing root module in: %s', rootPath);

  spinner.start('Extract source package');

  return await pacote.extract(sourcePackageSpec, rootPath, opt.gitlabOpts)
    .then(res => {
      //If we successfully extracted the source package, it will end up in ./nodejs/node_modules
      //Now we need to go through the dependencies and extract them into the same directory
      spinner.succeed(`Extracted source package ${res.resolved}`);
      extractionCount++;
      return buildTree(rootPath, opt)
    })
    .then(tree => {
      return processTree(tree, opt, pathToPrecompiled, pathToSavedDependencies, excludeScopes, excludeModules)
    })
    .then(() => {
      log.info(`Successfully extracted ${extractionCount} dependencies`);
      log.info(`Skipped ${skippedExtractionCount} dependencies`);
    })
    .then(() => {
      //Add explicitly included modules
      for (const [key, value] of Object.entries(opt.includePrecompiledModules)) {
        spinner.start(`Processing additionally required module ${key}`);
        copyPrecompiled(value, key, pathToPrecompiled, pathToSavedDependencies);
        spinner.succeed(`Processed additionally required dependency ${key}`);
      }
    })
    .then(() => {
      spinner.start(`zip layer to ${pathToLayerData}`);
      zip(pathToLayerData, path.join(pathToLayerData, '../reventless-layer.zip'))
        .then(_ => spinner.succeed('Layer zipped'))
        .catch(err => {
          console.error(err);
          spinner.fail(err.toString());
        })
    });
}

async function buildTree(rootPath, opt) {
  const arb = new Arborist({
    ...opt.gitlabOpts,
    path: rootPath,
  });
  spinner.succeed(`Building dependency tree for ${rootPath}`);
  return arb.buildIdealTree({
    preferDedupe: true,
    saveType: 'prod',
  }).then(tree => {
    spinner.succeed(`Successfully built dependency tree for ${tree.name}`);
    printStats(tree);
    return tree;
  }).catch(err => {
    spinner.fail(`Failed to extract source package ${err}`);
    throw err;
  })
}

function processTree(tree, opt, pathToPrecompiled, pathToSavedDependencies, excludeScopes, excludeModules) {
  spinner.start('Extracting dependencies');
  return depth({
    tree: tree,
    visit: async node => {
      return await processNode(node, opt, pathToPrecompiled, pathToSavedDependencies)
    },
    getChildren: node => node.children && node.children.size > 0 ? Array.from(node.children.values()) : [],
    filter: node => {
      const isNodeFiltered = filterOptional(node) && filterExcluded(node, excludeScopes, excludeModules);
      if (isNodeFiltered) skippedExtractionCount++;
      return isNodeFiltered
    }
  })
}

async function processNode(node, options, pathToPrecompiled, pathToSavedDependencies) {
  spinner.start(`Extracting dependency ${node.name}`);
  const precompiledModuleNames = Object.keys(options.precompiledModules);
  var result
  //If we have precompiled the module, we copy instead of extracting it
  if (precompiledModuleNames && precompiledModuleNames.includes(node.name)) {
    result = processPrecompiledNode(node, options, pathToPrecompiled, pathToSavedDependencies)
      .then(() => {
        spinner.succeed(`Copied precompiled dependency ${node.name}`);
      })
  } else {
    result = processNodeDefault(node, options, pathToSavedDependencies)
      .then(() => {
        spinner.succeed(`Extracted dependency ${node.name}`);
      })
  }
  return result
    .then(res => {
      log.debug(`Removing unneccessary Files for ${node.name}`);
      deleteFilesWithSuffixes(path.resolve(pathToSavedDependencies, node.packageName), options.excludedFileFormats);
      log.debug(`Removed unneccessary Files for ${node.name}`);
      extractionCount++;
      return res
    })
    .catch(err => {
      spinner.fail(`Failed to extract dependency ${err}`);
      throw err;
    });
}

async function processPrecompiledNode(node, options, pathToPrecompiled, pathToSavedDependencies) {
  return copyPrecompiled(options.precompiledModules[node.name], node.name, pathToPrecompiled, pathToSavedDependencies)
    .catch(err => {
      spinner.fail(`Failed to copy precompiled dependency ${err}`);
      throw err;
    });
}

async function processNodeDefault(node, options, pathToSavedDependencies) {
  //The name could be a package alias, therefore we use the package name instead
  return pacote.extract(node.packageName + '@' + node.version,
    path.resolve(pathToSavedDependencies, node.packageName), options.gitlabOpts)
    .catch(err => {
      spinner.fail(`Failed to extract dependency ${err}`);
      throw err;
    });
}

function filterOptional(node) {
  if (node.dev) {
    log.info(`Excluding ${node.name} because it is a dev dependency`);
    return false;
  }
  else if (node.optional) {
    log.info(`Excluding ${node.name} because it is an optional dependency`);
    return false;
  }
  else if (node.devOptional) {
    log.info(`Excluding ${node.name} because it is a devOptional dependency`);
    return false;
  }
  else if (node.peer) {
    log.info(`Excluding ${node.name} because it is a peer dependency`);
    return false;
  }
  else return true;
}

function filterExcluded(node, excludeScopes, excludeModules) {
  if (excludeScopes && excludeScopes.length > 0) {
    for (let i = 0; i < excludeScopes.length; i++) {
      const scope = node.name.split('/')[0];
      if (scope === excludeScopes[i]) {
        log.info(`Excluding ${node.name} because it is in scope ${excludeScopes[i]}`);
        return false;
      }
    }
  }
  if (excludeModules && excludeModules.length > 0) {
    for (let i = 0; i < excludeModules.length; i++) {
      if (node.name === excludeModules[i]) {
        log.info(`Excluding ${node.name} because it is in the exclude list`);
        return false;
      }
    }
  }
  return true
}

async function deleteFolderContents(folderPath) {
  const entries = fs.readdirSync(folderPath, { withFileTypes: true });

  for (let entry of entries) {
    const entryPath = path.join(folderPath, entry.name);

    if (entry.isDirectory()) {
      await deleteFolderContents(entryPath);
      fs.rmdirSync(entryPath);
    } else {
      fs.unlinkSync(entryPath);
    }
  }
}

async function copyPrecompiled(source, target, pathToPrecompiled, dependenciesPath) {
  const sourcePath = resolvePath(pathToPrecompiled, source)
  const targetPath = resolvePath(dependenciesPath, target)
  return new Promise((resolve, reject) =>
    cp(
      sourcePath,
      targetPath,
      { recursive: true },
      (err) => {
        if (err) {
          reject(err)
        } else {
          resolve()
        }
      }
    ));
}

async function deleteFilesWithSuffixes(folderPath, suffixes) {
  for (let i = 0; i < suffixes.length; i++) {
    await deleteFilesWithSuffix(folderPath, suffixes[i]);
  }
}

async function deleteFilesWithSuffix(folderPath, suffix) {
  const entries = fs.readdirSync(folderPath, { withFileTypes: true });

  for (let entry of entries) {
    const entryPath = path.join(folderPath, entry.name);

    if (entry.isDirectory()) {
      await deleteFilesWithSuffix(entryPath, suffix);
    } else if (entry.isFile() && entry.name.endsWith(suffix)) {
      fs.unlinkSync(entryPath);
      log.debug(`Deleted file: ${entryPath}`);
    }
  }
}

function printStats(node) {
  const allNodesCount = countChildrenRecursive(node);
  const childNodesCount = node.children.size;
  const stats = {
    allNodesCount: allNodesCount,
    childNodesCount: childNodesCount,
    diffCount: allNodesCount - childNodesCount,
    maxDepth: maxDepth(node)
  };

  log.info("");
  log.info("---------");
  log.info("--STATS--");
  log.info("--%s", node.name);
  log.info("---------");

  log.info("total nodes: %d", stats.allNodesCount)
  log.info("children: %d", stats.childNodesCount);
  log.info("nested nodes: %d", stats.diffCount);
  log.info("maxDepth: %d", stats.maxDepth);
  log.info("------");
  log.info("");
  return stats;
}

function countChildrenRecursive(node, count = 0) {
  if (!node.children || node.children.size == 0) {
    return 0;
  } else {
    var count = node.children.size;
    node.children.forEach((child, key, map) => {
      count += countChildrenRecursive(child)
    });
    return count;
  }
};

function maxDepth(node, currentDepth = 1) {
  if (node.children && node.children.size > 0) {
    var localMax = 0;
    for (const [key, child] of node.children) {
      if (child === undefined) {
        if (process.env.REVENTLESS_DEBUG)
          log.debug(`child(${key}) is undefined: ${child}`);
        continue;
      };
      log.debug(`${node.name} > ${child.name}`, node.name, child.name);
      const childMaxDepth = maxDepth(child, currentDepth + 1)
      if (childMaxDepth > localMax) {
        localMax = childMaxDepth;
      }
    }
    log.debug(`- ${node.name} > localMax=${localMax}`);
    return localMax
  } else {
    log.debug(`- ${node.name} > leave ${currentDepth}`);
    return currentDepth;
  }
};

await cleanup(options)
  .then(build(options))
  .catch(err => { console.error(err) });

