#!/usr/bin/env bun
import { validateWorkflowTargets } from "./lib/workflow-needs.mjs";

export function runCli(argv, io = { log: console.log, error: console.error }) {
  const resolvedTargets = argv.length > 0 ? argv : [".github/workflows"];
  const { checkedFiles, errors } = validateWorkflowTargets(resolvedTargets);

  if (errors.length > 0) {
    for (const err of errors) {
      io.error(`::error::${err}`);
    }
    return 1;
  }

  io.log(`Validated workflow job dependencies (${checkedFiles.length} files).`);
  return 0;
}

if (import.meta.main) {
  process.exit(runCli(process.argv.slice(2)));
}
