#!/usr/bin/env node
// `vue-tsc --noEmit`, scoped to OUR files.
//
// Why a wrapper rather than calling vue-tsc directly: TypeScript type-checks every file reachable
// through an import, and `exclude` does not stop that — so `deps/live_vue/assets/*.ts` gets checked
// along with ours. Those are a Hex dependency's sources: we cannot fix them, and they currently
// report a real version skew (live_vue imports `LiveSocketInstanceInterface`, which the installed
// phoenix_live_view types no longer export). Gating `precommit` on a dependency's type errors would
// mean a red build that no edit in this repo can turn green, and it would come back on every
// `mix deps.get`.
//
// So: run the full check (dependency types still inform OUR inference — this is not `skipLibCheck`),
// print everything for context, and fail only on diagnostics whose file lives outside `deps/`.
//
// This is the only compile-time check that a LiveVue prop contract still holds. `mix compile` cannot
// see a Vue prop, and a broken one is a silently wrong screen rather than a red build.

import { spawnSync } from "node:child_process"
import { join } from "node:path"

const bin = join("node_modules", ".bin", process.platform === "win32" ? "vue-tsc.cmd" : "vue-tsc")

const { status, stdout, stderr, error } = spawnSync(bin, ["--noEmit", "--pretty", "false"], {
  encoding: "utf8",
})

if (error) {
  console.error(`typecheck: could not run ${bin} — ${error.message}`)
  console.error("Run `mix assets.setup` to install node dependencies.")
  process.exit(1)
}

const output = `${stdout ?? ""}${stderr ?? ""}`
if (output.trim()) process.stdout.write(output)

// tsc diagnostics are `path(line,col): error TSxxxx: message`, paths relative to the tsconfig dir.
const diagnostics = output.split("\n").filter(line => /^\S.*\(\d+,\d+\): error TS/.test(line))
const ours = diagnostics.filter(line => !line.startsWith("deps/"))
const vendored = diagnostics.length - ours.length

if (vendored > 0) {
  console.log(`\ntypecheck: ignoring ${vendored} error(s) in deps/ (vendored Hex sources).`)
}

if (ours.length > 0) {
  console.error(`\ntypecheck: ${ours.length} error(s) in project files.`)
  process.exit(1)
}

// A non-zero exit with no parsed diagnostics means vue-tsc failed for some other reason (bad
// tsconfig, crash) — surface it rather than reporting a false pass.
if (status !== 0 && diagnostics.length === 0) {
  console.error(`\ntypecheck: vue-tsc exited ${status} without diagnostics.`)
  process.exit(status ?? 1)
}

console.log("typecheck: no type errors in project files.")
