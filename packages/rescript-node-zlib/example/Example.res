/*
 * To run this example:
 *  - build this package
 *  - cd into the example directory
 *  - run `node Example.bs.js`
 *  - Test was successfull if:
 *    - no exception was raised (and outputed during program execution)
 *    - testResult.txt file is now present in the example directory
 */

open NodeZlib

let f = async () => {
  let readFile = NodeStreams.createReadStream("./test.txt.gz")
  let unzipFile = createUnzip()
  let writeFile = NodeStreams.createWriteStream("./testResult.txt")
  await NodeStreams.pipeline(readFile, unzipFile, writeFile)
}

f()->ignore
