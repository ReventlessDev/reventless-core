const pluginMermaid = require("@kevingimbel/eleventy-plugin-mermaid");

module.exports = function(eleventyConfig) {
  eleventyConfig.addGlobalData("layout", "doclayout.html");
  eleventyConfig.addPlugin(pluginMermaid);

  return {
    dir: {
      input: "docs",
      output: "_site",
      includes: "_includes",
      layouts: "_layouts", // relative to the input directory
      data: "_data", // relative to the input directory
    },
    templateFormats: ["html", "liquid", "md"]
  }
}
