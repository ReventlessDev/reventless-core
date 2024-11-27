export default function(docsPlugin) {

  return async function glossary(context, opts) {
    //console.debug("context:", context)
    //console.debug("opts:", opts)

    const docs = await docsPlugin(context, opts)

    return {
      ...docs,
      //name: 'docs-with-glossary',
      /*
      async contentLoaded({ content, actions }) {
        console.debug("contentLoaded");
        console.debug("content", content, JSON.stringify(content, null, 2));
        console.debug("actions", actions, JSON.stringify(actions, null, 2));
        return docs.contentLoaded({ content, actions })
      }
      */
    }
  }
}
