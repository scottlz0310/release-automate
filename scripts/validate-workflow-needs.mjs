#!/usr/bin/env bun
import { validateWorkflowTargets } from "./lib/workflow-needs.mjs";

const targets = process.argv.slice(2);
const resolvedTargets = targets.length > 0 ? targets : [".github/workflows"];
const { checkedFiles, errors } = validateWorkflowTargets(resolvedTargets);

if (errors.length > 0) {
  for (const err of errors) {
    console.error(`::error::${err}`);
  }
  process.exit(1);
}

console.log(`Validated workflow job dependencies (${checkedFiles.length} files).`);
