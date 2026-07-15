// Single source for the directory names pruned from every monorepo scan — test
// discovery, component scan, platform scan — and the equivalent chokidar globs
// for the watch. Previously duplicated verbatim across the three walkers and,
// divergently, as inline globs in `Watch`; that drift once let `dist/` writes
// drive a re-run loop.
let names = ["node_modules", ".git", "dist", "lib", ".history"]

let shouldIgnore = (name: string): bool => names->Array.includes(name)

// chokidar-style globs derived from the same list (the watch's ignore set).
let globs = names->Array.map(n => "**/" ++ n ++ "/**")
