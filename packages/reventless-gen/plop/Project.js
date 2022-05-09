export const createProjectFiles = {
  type: 'addMany',
  destination: '{{dashCase projectName}}/',
  base: 'plop-templates/Project/',
  templateFiles: 'plop-templates/Project/**/*',
  globOptions: {dot: true}
};
export const gitInitPlatform = data => ({
  type: 'gitInit',
  path: `${process.cwd()}/${data.projectName}/platform/`,
  verbose: true,
  abortOnFail: false
});
export const npmInstallApi = data => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${data.projectName}/platform/api`,
  verbose: true
});
export const rebuildApi = data => ({
  type: 'rebuild',
  path: `${process.cwd()}/${data.projectName}/platform/api`,
  verbose: true
});
export const npmInstallCore = data => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${data.projectName}/platform/core`,
  verbose: true
});
export const rebuildCore = data => ({
  type: 'rebuild',
  path: `${process.cwd()}/${data.projectName}/platform/core`,
  verbose: true
});
