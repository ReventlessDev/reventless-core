export const createFiles = {
  type: 'addMany',
  destination: 'src/ExtensionPoints/{{properCase extensionPointName}}/',
  base: 'plop-templates/ExtensionPoint/',
  templateFiles: 'plop-templates/ExtensionPoint/**/*'
};
export const addToMain = {
  type: "modify",
  path: "src/Main.re",
  pattern: /(~extensionPoints\W[\S\s]*?\[\|)/,
  template: "$1(module {{properCase extensionPointName}}ExtensionPoint),",
};
