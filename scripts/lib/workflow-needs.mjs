import { readdirSync, readFileSync, statSync } from "node:fs";
import { extname, join } from "node:path";

const WORKFLOW_EXTENSIONS = new Set([".yml", ".yaml"]);
const JOB_ID_PATTERN = /^[A-Za-z_][A-Za-z0-9_-]*$/;

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeJobId(jobId) {
  return jobId.toLowerCase();
}

function normalizeNeeds(jobId, rawNeeds, filePath, errors) {
  if (rawNeeds === undefined) {
    return [];
  }

  if (typeof rawNeeds === "string") {
    if (rawNeeds.trim().length === 0) {
      errors.push(`${filePath}: jobs.${jobId}.needs に空のジョブ名は指定できません`);
      return [];
    }
    return [rawNeeds];
  }

  if (Array.isArray(rawNeeds)) {
    if (rawNeeds.length === 0) {
      errors.push(`${filePath}: jobs.${jobId}.needs に空配列は指定できません`);
      return [];
    }

    const deps = [];
    const seen = new Map();
    for (const item of rawNeeds) {
      if (typeof item !== "string" || item.trim().length === 0) {
        errors.push(`${filePath}: jobs.${jobId}.needs の要素は非空の文字列である必要があります`);
        continue;
      }
      const key = normalizeJobId(item);
      if (seen.has(key)) {
        errors.push(`${filePath}: jobs.${jobId}.needs に重複したジョブ名 "${item}" があります`);
        continue;
      }
      seen.set(key, item);
      deps.push(item);
    }
    return deps;
  }

  errors.push(`${filePath}: jobs.${jobId}.needs は文字列または文字列配列である必要があります`);
  return [];
}

function detectCycles(graph, displayNames, filePath, errors) {
  // 0: 未訪問, 1: 探索中, 2: 完了
  const state = new Map();
  const stack = [];
  const reportedCycles = new Set();

  function dfs(nodeKey) {
    state.set(nodeKey, 1);
    stack.push(nodeKey);

    for (const depKey of graph.get(nodeKey) ?? []) {
      if (!graph.has(depKey) || depKey === nodeKey) {
        continue;
      }
      const depState = state.get(depKey) ?? 0;
      if (depState === 1) {
        const startIdx = stack.indexOf(depKey);
        const cyclePath = [...stack.slice(startIdx), depKey]
          .map((key) => displayNames.get(key) ?? key)
          .join(" -> ");
        if (!reportedCycles.has(cyclePath)) {
          reportedCycles.add(cyclePath);
          errors.push(`${filePath}: jobs の needs に循環依存があります (${cyclePath})`);
        }
      } else if (depState === 0) {
        dfs(depKey);
      }
    }

    stack.pop();
    state.set(nodeKey, 2);
  }

  for (const jobKey of graph.keys()) {
    if ((state.get(jobKey) ?? 0) === 0) {
      dfs(jobKey);
    }
  }
}

export function validateWorkflowContent(content, filePath = "<memory>") {
  let parsed;
  try {
    parsed = Bun.YAML.parse(content);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return [`${filePath}: YAML の解析に失敗しました: ${message}`];
  }

  if (!isPlainObject(parsed)) {
    return [`${filePath}: ワークフロー定義のルートはオブジェクトである必要があります`];
  }

  const { jobs } = parsed;
  if (!isPlainObject(jobs) || Object.keys(jobs).length === 0) {
    return [`${filePath}: jobs は 1 件以上のジョブを含むオブジェクトである必要があります`];
  }

  const errors = [];
  const jobEntries = Object.entries(jobs);
  const canonicalJobs = new Map();

  for (const [jobId] of jobEntries) {
    if (!JOB_ID_PATTERN.test(jobId)) {
      errors.push(`${filePath}: jobs.${jobId} のジョブ ID 形式が不正です`);
    }
    const key = normalizeJobId(jobId);
    const existing = canonicalJobs.get(key);
    if (existing !== undefined) {
      errors.push(
        `${filePath}: jobs に大文字・小文字を区別しない重複したジョブ ID があります ("${existing}" と "${jobId}")`,
      );
    } else {
      canonicalJobs.set(key, jobId);
    }
  }

  const graph = new Map();
  for (const [jobId, jobDef] of jobEntries) {
    const jobKey = normalizeJobId(jobId);
    if (!isPlainObject(jobDef)) {
      errors.push(`${filePath}: jobs.${jobId} はオブジェクトである必要があります`);
      if (!graph.has(jobKey)) {
        graph.set(jobKey, []);
      }
      continue;
    }

    const deps = normalizeNeeds(jobId, jobDef.needs, filePath, errors);
    const depKeys = [];
    for (const dep of deps) {
      const depKey = normalizeJobId(dep);
      if (depKey === jobKey) {
        errors.push(`${filePath}: jobs.${jobId}.needs が自分自身を参照しています`);
      } else if (!canonicalJobs.has(depKey)) {
        errors.push(
          `${filePath}: jobs.${jobId}.needs が存在しないジョブ "${dep}" を参照しています`,
        );
      } else {
        depKeys.push(depKey);
      }
    }

    if (!graph.has(jobKey)) {
      graph.set(jobKey, depKeys);
    }
  }

  detectCycles(graph, canonicalJobs, filePath, errors);
  return errors;
}

export function validateWorkflowTargets(targets) {
  const files = [];
  const errors = [];

  for (const target of targets) {
    let stat;
    try {
      stat = statSync(target);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      errors.push(`${target}: パスを読み取れません: ${message}`);
      continue;
    }

    if (stat.isDirectory()) {
      const entries = readdirSync(target)
        .filter((name) => WORKFLOW_EXTENSIONS.has(extname(name).toLowerCase()))
        .sort();
      if (entries.length === 0) {
        errors.push(`${target}: 検証対象のワークフロー YAML (*.yml, *.yaml) が見つかりません`);
        continue;
      }
      for (const name of entries) {
        files.push(join(target, name));
      }
    } else if (stat.isFile()) {
      files.push(target);
    } else {
      errors.push(`${target}: 通常ファイルまたはディレクトリを指定してください`);
    }
  }

  for (const filePath of files) {
    const content = readFileSync(filePath, "utf8");
    errors.push(...validateWorkflowContent(content, filePath));
  }

  return { checkedFiles: files, errors };
}
