export const createPlatformFiles = {
  type: 'addMany',
  destination: '{{dashCase platformName}}/',
  base: 'plop-templates/Platform/',
  templateFiles: 'plop-templates/Platform/**/*',
  globOptions: {dot: true}
};
export const gitInitPlatform = data => ({
  type: 'gitInit',
  path: `${process.cwd()}/${data.platformName}/platform/`,
  verbose: true,
  abortOnFail: false
});
export const npmInstallApi = data => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${data.platformName}/platform/api`,
  verbose: true
});
export const rebuildApi = data => ({
  type: 'rebuild',
  path: `${process.cwd()}/${data.platformName}/platform/api`,
  verbose: true
});
export const npmInstallCore = data => ({
  type: 'npmInstall',
  path: `${process.cwd()}/${data.platformName}/platform/core`,
  verbose: true
});
export const rebuildCore = data => ({
  type: 'rebuild',
  path: `${process.cwd()}/${data.platformName}/platform/core`,
  verbose: true
});
