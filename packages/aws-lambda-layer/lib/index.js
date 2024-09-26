import Arborist from '@npmcli/arborist';
import pacote from 'pacote';
import treeverse from 'treeverse';
import fs from 'fs';
import path, { dirname } from 'path';
import { fileURLToPath } from 'url';
import { execSync, spawnSync } from 'child_process';
import { zip } from 'zip-a-folder';

import ora from 'ora';
import debug from 'debug';

const __filename = fileURLToPath(import.meta.url);
const spinner = ora();
const logger = debug('lib');
const { depth, width } = treeverse;


function maxDepth(node, currentDepth = 1) {
    const log = logger.extend("maxDepth");
    if (node.children && node.children.size > 0) {
        var localMax = 0;
        for (const [key, child] of node.children) {
            if (child === undefined) {
                if (process.env.REVENTLESS_DEBUG)
                    log('child(%s) is undefined: %O', key, child);
                continue;
            };
            log('%s > %s', node.name, child.name);
            const childMaxDepth = maxDepth(child, currentDepth + 1)
            if (childMaxDepth > localMax) {
                localMax = childMaxDepth;
            }
        }
        log('- %s > localMax=', node.name, localMax);
        return localMax
    } else {
        log('- %s > leave %d', node.name, currentDepth);
        return currentDepth;
    }
};

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

function hasChildren(node) {
    return node.children && node.children.size > 0
}

/*filter the current node and all it's children, based on a predicate function
 * if the predicate returns true, the node will be deleted
 */
function filterNodes(node, predicate = node => false/*keep all nodes*/) {
    var count = 0;
    node.children.forEach((child, key, map) => {
        if (predicate(child) && map.delete(key)) {
            count += 1 + countChildrenRecursive(child);

        } else if (hasChildren(child)) {
            count += filterNodes(child, predicate);
        }
    });
    return count;
}

function predIsDev(node) {
    return node.dev;
};

function predIsDevOpt(node) {
    return node.devOptional;
};

function predIsDevOrDevOpt(node) {
    return predIsDev(node) || predIsDevOpt(node);
}

function isNodeScopeExcluded(excludedScopes, node) {
    for (const scope of excludedScopes) {
        if (node.name.startsWith(`@${scope}/`))
            return true
    }
    return false
}

function isNodeExcluded(excludedModules, node) {
    return excludedModules.includes(node.name)
}

function isNodeProd(node) {
    return (!node.dev && !node.optional && !node.devOptional && !node.peer)
}

function isEdgeNecessary(edge) {
    const edgeIsProd = edge.type === 'prod';
    return edgeIsProd
}

function predIsNecessary(excludedScopes, excludedModules, node) {
    const log = logger.extend('predIsNecessary')
    var msg;

    /*
    var prodEdgeExists = false;
    for (const e of node.edgesIn) {
        if (isEdgeNecessary(e)) {
            prodEdgeExists = true;
            break;
        }
    }
    */

    if (node.name === 'rescript' || node.name === 'typescript')
        log('isNecessary? %O: dev:%s - optional:%s - devOptiona:%s - peer:%s - type:%s - prodEdge:%s', node, node.dev, node.optional, node.devOptional, node.peer, node.type);

    if (node.dev)
        msg = `${node.name} is not necessary: dev`;
    else if (node.optional)
        msg = `${node.name} is not necessary: optional`;
    else if (node.devOptional)
        msg = `${node.name} is not necessary: optional dev`;
    else if (node.peer)
        msg = `${node.name} is not necessary: peer`;
    /*
    else if (!prodEdgeExists)
        msg = `${node.name} is not necessary: no prod edges`;
    */
    else if (isNodeScopeExcluded(excludedScopes, node))
        msg = `${node.name} is not necessary: scope excluded`;
    else if (isNodeExcluded(excludedModules, node))
        msg = `${node.name} is not necessary: module excluded`;
    else {
        var tracks = new Map();
        const res = depth({
            tree: node,
            visit: node => {
                tracks.delete(node.name);
                const isExcluded = (isNodeScopeExcluded(excludedScopes, node) || isNodeExcluded(excludedModules, node));
                return isExcluded;
            },
            getChildren: (node, isExcluded) => {
                if (!isExcluded) {
                    const edgesIn = Array.from(node.edgesIn.values());
                    if (edgesIn.length > 0) {
                        const children = edgesIn.filter(e => { return e.prod }).map(e => e.from);
                        children.forEach(n => tracks.set(n.name, n));
                        return children;
                    } else {
                        tracks.set('_reached_top_', true);
                        return []
                    }
                } else {
                    return []
                }
            },
        });
        log(`${node.name}.tracks:`, Array.from(tracks.values()).map(n => n.name));
        if (tracks.size === 0) {
            msg = `${node.name} is not necessary: dependent is excluded`
        }
    }

    if (msg) {
        log('%s', msg);
        return false;
    } else {
        return true;
    }
}

function isRescriptModule(node) {
    const log = logger.extend('isRescriptModule');
    const test = fs.existsSync(node.path + "/bsconfig.json") || fs.existsSync(node.path + "/rescript.json")
    log('%s: %s', node.name, test);
    return test;
};

function hasDependency(node, dependencyName) {
    const log = logger.extend('has-dependency');
    for (const [key, edge] of node.edgesOut) {
        const edgeName = key//edge.from.name
        const isEdgeNameEqualToDependencyName = edgeName === dependencyName;
        if (isEdgeNameEqualToDependencyName) {
            /* previously also tested for: && edge.type === 'prod'*/
            return true;
        } else {
            log('hasRescriptDependency("%s", "%s")="%s": "%s", %O', node.Name, dependencyName, isEdgeNameEqualToDependencyName, edgeName, edge);
        };
    }
    return false
};

function hasRescriptDependency(node) {
    return hasDependency(node, 'rescript');
}

function flattenChildren(root, children) {
    const log = logger.extend('flattenChildren');
    children.forEach((node, key, map) => {
        if (map.delete(key) && root.children.set(key, node))
            log('moved to root children: %s', key);
        if (hasChildren(node)) {
            flatten(root, node);
        }
    });
};

function flatten(root) {
    root.children.forEach((node, key, map) => {
        if (hasChildren(node))
            flattenChildren(root, node.children)
    });
};

function stats(node, shouldPrint) {
    const allNodesCount = countChildrenRecursive(node);
    const childNodesCount = node.children.size;
    const stats = {
        allNodesCount: allNodesCount,
        childNodesCount: childNodesCount,
        diffCount: allNodesCount - childNodesCount,
        maxDepth: maxDepth(node)
    };

    if (shouldPrint) {
        console.log("");
        console.log("---------");
        console.log("--STATS--");
        console.log("--" + node.name);
        console.log("---------");

        console.log("total nodes:", stats.allNodesCount)
        console.log("children:", stats.childNodesCount);
        console.log("nested nodes:", stats.diffCount);
        console.log("maxDepth:", stats.maxDepth);
        console.log("------");
        console.log("");
    };
    return stats;
}

async function doPostProcessing(node, pathToSavedDependencies, fn, spinner, log) {
    const cwd = path.resolve(pathToSavedDependencies, '../' + node.location);
    spinner.start(`postprocess ${node.name}: ${fn.name}`);
    console.log();
    try {
        /*
        const r = execSync(fn, {
            cwd: cwd
        });
        console.log(`${node.name} postProcess(${cwd}: ${fn.name}):`, r.toString());
        */
        await fn(node, cwd);
        spinner.succeed();
    } catch (error) {
        spinner.fail()
        console.error(`postprocessing of ${node.name} did fail at '${fn.name}':`, error.toString());
    }
}

export function build(opt) {
    const { sourcePackageName, sourcePackageVersion, pathToLayerData, pathToSavedDependencies, excludeScopes, excludeModules, postProcess } = opt;
    spinner.start('configure');
    const log = logger.extend('main');
    const logPostProcessing = logger.extend('post-processing');
    // FIXME: move this out into build opts
    const opts = {
        //path: "./",
        //path: "../../../fidap/wm-raw/plugin",
        //"@fidap-wm-raw:registry": "https://gitlab.com/api/v4/projects/43406890/packages/npm/",
        "@fidap-wm-raw:registry": "https://gitlab.com/api/v4/packages/npm/",
        "@fidap:registry": "https://gitlab.com/api/v4/packages/npm/",
        "@reventless:registry": "https://gitlab.com/api/v4/packages/npm/",
        "//gitlab.com/api/v4/projects/40879371/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
        "//gitlab.com/api/v4/projects/43406890/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
        "//gitlab.com/api/v4/projects/24127696/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN,
        "//gitlab.com/api/v4/packages/npm/:_authToken": process.env.NPM_GITLAB_TOKEN
    }

    //const modulePath = path.join(pathToLayerData, pathToSavedDependencies)
    const rootPath = path.resolve(pathToSavedDependencies, sourcePackageName)
    const sourcePackageVersionStr = (sourcePackageVersion) ? sourcePackageVersion : 'latest';
    const sourcePackageSpec = `${sourcePackageName}@${sourcePackageVersionStr}`

    log('root module: %s', sourcePackageSpec);
    log('storing modules in: %s', pathToSavedDependencies);
    log('storing root module in: %s', rootPath);

    var rescriptModule = undefined;
    var rescriptStdModule = undefined;
    var unnecessaryModules = [];
    var extractionCount = 0;
    var skippedExtractionCount = 0;

    spinner.succeed();
    spinner.start('extract source package');

    //------ extract root module ------//
    return pacote.extract(sourcePackageSpec,
        rootPath,
        opts)
        .then(res => {
            spinner.succeed();
            log('root module extracted: %O', res);

            spinner.start('build dependency tree');

            const arb = new Arborist({
                ...opts,
                path: rootPath,
            });


            return arb.buildIdealTree({
                preferDedupe: true,
                saveType: 'prod',
            })
        })
        .then(tree => {
            spinner.succeed();
            //------ extract all dependency modules ------//
            stats(tree, true);

            /* WARNING: if the unnecessary nodes are removed now: there will be no way to see, which nodes depend on rescript
            const numberOfFilteredNodes = filterNodes(tree, x=>!predIsNecessary(x));
            log("filtered nodes: %d", numberOfFilteredNodes);
            */
            log('total nodes in tree=%d', countChildrenRecursive(tree))

            log("");

            const logTree = logger.extend('tree');

            const extractSpinnerMsg = 'extract dependencies';
            spinner.start(extractSpinnerMsg);
            return depth({
                tree: tree,
                visit: node => {
                    spinner.suffixText = node.name;
                    if (node.name.startsWith('@opentelemetry'))
                        log(node);
                    if (node.isRoot) {
                        log('skip extracting %s@%s', node.name, node.version);
                        return;
                    } else if (node.name === 'rescript') {
                        log('found %s@%s', node.name, node.version);
                        rescriptModule = node;
                    } else if (node.name === '@rescript/std') {
                        log('found %s@%s', node.name, node.version);
                        rescriptStdModule = node;
                    };
                    if (predIsNecessary(excludeScopes, excludeModules, node)) {
                        log('extracting necessary node: %s', node.name);
                        const extractOpts = { ...opts, resolved: node.resolved };
                        return pacote.extract(node.name + '@' + node.version,
                            path.resolve(pathToSavedDependencies, node.name),
                            extractOpts)
                            .then(async res => {
                                spinner.suffixText = "";
                                spinner.succeed(`extracted dependency ${node.name}`);
                                extractionCount += 1;
                                const postProcessingNamesForDependencies =  // TODO: move out tree processing
                                    Object.keys(postProcess)
                                        .filter(postProcessingName => postProcessingName.startsWith('>'))
                                        .map(name => name.replace('>', ''));
                                const shouldPostProcess = Object.hasOwn(postProcess, node.name);
                                const shouldPostProcessDependendency = postProcessingNamesForDependencies.length > 0;
                                if (shouldPostProcess || shouldPostProcessDependendency) {
                                    spinner.start(`postprocess ${node.name}`);
                                }
                                if (shouldPostProcess) {
                                    //console.log(node.name, 'post-process', postProcess[node.name], node, cwd)
                                    /*
                                    postProcess[node.name].forEach(cmd => {
                                        doPostProcessing(node, pathToSavedDependencies, cmd, spinner, logPostProcessing);
                                    });
                                    */
                                    await doPostProcessing(node, pathToSavedDependencies, postProcess[node.name], spinner, logPostProcessing);
                                }
                                //check for matching `>DEPENDENCY` keys in postProcess
                                for (const dependencyForPostProcessing of postProcessingNamesForDependencies) {
                                    if (hasDependency(node, dependencyForPostProcessing)) {
                                        /*
                                        postProcess['>' + dependencyForPostProcessing].forEach(cmd => {
                                            doPostProcessing(node, pathToSavedDependencies, cmd, spinner, logPostProcessing);
                                        });
                                        */
                                        await doPostProcessing(node, pathToSavedDependencies, postProcess['>' + dependencyForPostProcessing], spinner, logPostProcessing);
                                    }
                                }
                            });
                    } else {
                        unnecessaryModules.push(node);
                        skippedExtractionCount += 1;
                    };
                },
                getChildren: node => hasChildren(node) ? Array.from(node.children.values()) : [],
                filter: node => {
                    const isNecessary = predIsNecessary(excludeScopes, excludeModules, node);
                    logTree('filter %s: isNecessary=%s', node.name, isNecessary);
                    if (node.name === 'rescript') {
                        log('found %s@%s', node.name, node.version);
                        rescriptModule = node;
                    }
                    if (!isNecessary) {
                        logTree('filtering: %O', node);
                        unnecessaryModules.push(node);
                    }
                    return isNecessary;
                }
            });

        })
        .then(res => {
            spinner.suffixText = "";
            spinner.succeed()
            return { rescript: rescriptModule, rescriptStd: rescriptStdModule }
        })
        .then(({ rescript, rescriptStd }) => {
            //------ rescript specific handling ------//
            for (const rescriptEdge of rescript.edgesIn) {
                if (rescriptEdge.type === "prod") {
                    const msg = `${rescriptEdge.name} requires rescript!`;
                    console.error(msg);
                    throw new Error(msg);
                }
                const rescriptDependent = rescriptEdge.from;

                log("rescript dependent: %s - %s - %s", rescriptDependent.name, rescriptEdge.type, isEdgeNecessary(rescriptDependent));
            }
        })
        .then(_ => {
            spinner.start(`zip layer to ${pathToLayerData}`);
            zip(pathToLayerData, path.join(pathToLayerData, '../reventless-layer.zip'))
                .then(_ => spinner.succeed())
                .catch(err => {
                    console.error(err);
                    spinner.fail(err.toString());
                });
        });

    // TODO: build all rescript dependencies to ensure up-to-date and existing js artifacts
    // maybe only build packages defined in config?
    // maybe install rescript somewhere above pathToLayerData, so it won't get zipped but can be executed to build
    // maybe use rescript version defined in sourcePackage (dev-/peer-) deps or from config?
    //
    // TODO: remove / replace all references/usage of `rescript` package --> use @rescript/std instead
    // TODO: introduce preProcess function object (to e.g. precompile js artifacts)
}

//main()
