import { readdirSync, readFileSync, statSync } from "node:fs";
import { extname, join } from "node:path";

const WORKFLOW_EXTENSIONS = new Set([".yml", ".yaml"]);

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
    const seen = new Set();
    for (const item of rawNeeds) {
      if (typeof item !== "string" || item.trim().length === 0) {
        errors.push(`${filePath}: jobs.${jobId}.needs の要素は非空の文字列である必要があります`);
        continue;
      }
      if (seen.has(item)) {
        errors.push(`${filePath}: jobs.${jobId}.needs に重複したジョブ名 "${item}" があります`);
        continue;
      }
      seen.add(item);
      deps.push(item);
    }
    return deps;
  }

  errors.push(`${filePath}: jobs.${jobId}.needs は文字列または文字列配列である必要があります`);
  return [];
}

function detectCycles(graph, filePath, errors) {
  // 0: 未訪問, 1: 探索中, 2: 完了
  const state = new Map();
  const stack = [];
  const reportedCycles = new Set();

  function dfs(node) {
    state.set(node, 1);
    stack.push(node);

    for (const dep of graph.get(node) ?? []) {
      if (!graph.has(dep) || dep === node) {
        continue;
      }
      const depState = state.get(dep) ?? 0;
      if (depState === 1) {
        const startIdx = stack.indexOf(dep);
        const cyclePath = [...stack.slice(startIdx), dep].join(" -> ");
        if (!reportedCycles.has(cyclePath)) {
          reportedCycles.add(cyclePath);
          errors.push(`${filePath}: jobs の needs に循環依存があります (${cyclePath})`);
        }
      } else if (depState === 0) {
        dfs(dep);
      }
    }

    stack.pop();
    state.set(node, 2);
  }

  for (const jobId of graph.keys()) {
    if ((state.get(jobId) ?? 0) === 0) {
      dfs(jobId);
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
  const jobIds = new Set(Object.keys(jobs));
  const graph = new Map();

  for (const [jobId, jobDef] of Object.entries(jobs)) {
    if (!isPlainObject(jobDef)) {
      errors.push(`${filePath}: jobs.${jobId} はオブジェクトである必要があります`);
      graph.set(jobId, []);
      continue;
    }

    const deps = normalizeNeeds(jobId, jobDef.needs, filePath, errors);
    graph.set(jobId, deps);

    for (const dep of deps) {
      if (dep === jobId) {
        errors.push(`${filePath}: jobs.${jobId}.needs が自分自身を参照しています`);
      } else if (!jobIds.has(dep)) {
        errors.push(
          `${filePath}: jobs.${jobId}.needs が存在しないジョブ "${dep}" を参照しています`,
        );
      }
    }
  }

  detectCycles(graph, filePath, errors);
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
