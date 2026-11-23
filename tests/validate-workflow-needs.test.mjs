import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  validateWorkflowContent,
  validateWorkflowTargets,
} from "../scripts/lib/workflow-needs.mjs";
import { runCli } from "../scripts/validate-workflow-needs.mjs";

const repoRoot = resolve(import.meta.dir, "..");
const cliPath = join(repoRoot, "scripts", "validate-workflow-needs.mjs");

describe("validateWorkflowContent", () => {
  test("リポジトリ内の全ワークフロー定義が検証を通過する", () => {
    const result = validateWorkflowTargets([join(repoRoot, ".github", "workflows")]);
    expect(result.checkedFiles.length).toBeGreaterThan(0);
    expect(result.errors).toEqual([]);
  });

  test.each([
    [
      "needs なし",
      `name: Simple
on: [push]
jobs:
  build:
    runs-on: ubuntu-26.04
    steps: []
`,
    ],
    [
      "単一文字列の needs",
      `name: Single
on: [push]
jobs:
  build:
    runs-on: ubuntu-26.04
    steps: []
  deploy:
    needs: build
    runs-on: ubuntu-26.04
    steps: []
`,
    ],
    [
      "ダイヤモンド型の DAG",
      `name: Dag
on: [push]
jobs:
  prepare:
    runs-on: ubuntu-26.04
    steps: []
  lint:
    needs: prepare
    runs-on: ubuntu-26.04
    steps: []
  test:
    needs: [prepare]
    runs-on: ubuntu-26.04
    steps: []
  finalize:
    needs: [lint, test]
    runs-on: ubuntu-26.04
    steps: []
`,
    ],
  ])("正常系: %s", (_label, yaml) => {
    expect(validateWorkflowContent(yaml, "valid.yml")).toEqual([]);
  });

  test.each([
    [
      "存在しないジョブを文字列で指定",
      `name: MissingString
on: [push]
jobs:
  deploy:
    needs: nonexistent
    runs-on: ubuntu-26.04
    steps: []
`,
      '存在しないジョブ "nonexistent"',
    ],
    [
      "存在しないジョブを配列で指定",
      `name: MissingArray
on: [push]
jobs:
  build:
    runs-on: ubuntu-26.04
    steps: []
  deploy:
    needs: [build, missing-job]
    runs-on: ubuntu-26.04
    steps: []
`,
      '存在しないジョブ "missing-job"',
    ],
    [
      "自己依存",
      `name: SelfDep
on: [push]
jobs:
  build:
    needs: build
    runs-on: ubuntu-26.04
    steps: []
`,
      "自分自身を参照",
    ],
    [
      "2 ジョブ間の循環依存",
      `name: Cycle2
on: [push]
jobs:
  a:
    needs: b
    runs-on: ubuntu-26.04
    steps: []
  b:
    needs: a
    runs-on: ubuntu-26.04
    steps: []
`,
      "循環依存",
    ],
    [
      "3 ジョブ間の循環依存",
      `name: Cycle3
on: [push]
jobs:
  a:
    needs: c
    runs-on: ubuntu-26.04
    steps: []
  b:
    needs: a
    runs-on: ubuntu-26.04
    steps: []
  c:
    needs: b
    runs-on: ubuntu-26.04
    steps: []
`,
      "循環依存",
    ],
    [
      "needs 配列内の重複",
      `name: Duplicate
on: [push]
jobs:
  build:
    runs-on: ubuntu-26.04
    steps: []
  deploy:
    needs: [build, build]
    runs-on: ubuntu-26.04
    steps: []
`,
      '重複したジョブ名 "build"',
    ],
    [
      "大文字・小文字だけが異なるジョブ ID の重複",
      `name: DuplicateJobIdCaseInsensitive
on: [push]
jobs:
  validate:
    runs-on: ubuntu-26.04
    steps: []
  VALIDATE:
    runs-on: ubuntu-26.04
    steps: []
  prepare:
    needs: validate
    runs-on: ubuntu-26.04
    steps: []
`,
      '重複したジョブ ID があります ("validate" と "VALIDATE")',
    ],
    [
      "needs 配列内の大文字・小文字違いの重複",
      `name: DuplicateNeedsCaseInsensitive
on: [push]
jobs:
  validate:
    runs-on: ubuntu-26.04
    steps: []
  prepare:
    needs: [validate, VALIDATE]
    runs-on: ubuntu-26.04
    steps: []
`,
      '重複したジョブ名 "VALIDATE"',
    ],
    [
      "大文字・小文字違いの自己依存",
      `name: SelfDepCaseInsensitive
on: [push]
jobs:
  Build:
    needs: build
    runs-on: ubuntu-26.04
    steps: []
`,
      "自分自身を参照",
    ],
    [
      "大文字・小文字違いの循環依存",
      `name: CycleCaseInsensitive
on: [push]
jobs:
  Alpha:
    needs: beta
    runs-on: ubuntu-26.04
    steps: []
  Beta:
    needs: alpha
    runs-on: ubuntu-26.04
    steps: []
`,
      "循環依存",
    ],
    [
      "不正な形式のジョブ ID",
      `name: InvalidJobId
on: [push]
jobs:
  123-job:
    runs-on: ubuntu-26.04
    steps: []
`,
      "ジョブ ID 形式が不正",
    ],
    [
      "needs に空文字列",
      `name: EmptyString
on: [push]
jobs:
  build:
    needs: ""
    runs-on: ubuntu-26.04
    steps: []
`,
      "空のジョブ名",
    ],
    [
      "needs に空配列",
      `name: EmptyArray
on: [push]
jobs:
  build:
    needs: []
    runs-on: ubuntu-26.04
    steps: []
`,
      "空配列",
    ],
    [
      "needs に数値",
      `name: NumberNeeds
on: [push]
jobs:
  build:
    needs: 123
    runs-on: ubuntu-26.04
    steps: []
`,
      "文字列または文字列配列",
    ],
    [
      "needs 配列に非文字列要素",
      `name: NonStringItem
on: [push]
jobs:
  build:
    runs-on: ubuntu-26.04
    steps: []
  deploy:
    needs: [build, 42]
    runs-on: ubuntu-26.04
    steps: []
`,
      "非空の文字列",
    ],
    [
      "jobs が欠落",
      `name: NoJobs
on: [push]
`,
      "jobs は 1 件以上のジョブを含むオブジェクト",
    ],
    [
      "ルートがオブジェクトではない",
      `- item1
- item2
`,
      "ルートはオブジェクト",
    ],
    [
      "ジョブ定義がオブジェクトではない",
      `name: InvalidJobDef
on: [push]
jobs:
  build: "not-an-object"
`,
      "jobs.build はオブジェクト",
    ],
    [
      "YAML 構文エラー",
      `name: Broken
jobs:
  build: [unterminated
`,
      "YAML の解析に失敗",
    ],
  ])("異常系: %s", (_label, yaml, expectedFragment) => {
    const errors = validateWorkflowContent(yaml, "broken.yml");
    expect(errors.length).toBeGreaterThan(0);
    expect(errors.some((e) => e.includes(expectedFragment))).toBe(true);
  });
});

describe("validate-workflow-needs CLI", () => {
  test("Biome 整形済みの存在しない needs を含むワークフローを負例として確実に拒否する", () => {
    const workDir = mkdtempSync(join(tmpdir(), "workflow-needs-"));
    try {
      const brokenFile = join(workDir, "broken-needs.yml");
      writeFileSync(
        brokenFile,
        `name: Broken Needs

on:
  workflow_dispatch:

jobs:
  prepare:
    needs: typo-validate
    runs-on: ubuntu-26.04
    steps:
      - run: echo ok
`,
        "utf8",
      );

      // 整形済み YAML は Biome を通過することを前提確認する
      const biomeProc = Bun.spawnSync(
        [process.execPath, "x", "biome", "check", "--vcs-enabled=false", brokenFile],
        {
          cwd: repoRoot,
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      expect(biomeProc.exitCode).toBe(0);

      // 依存検証 CLI は確実に失敗し、問題箇所を報告する
      const cliProc = Bun.spawnSync([process.execPath, cliPath, workDir], {
        cwd: repoRoot,
        stdout: "pipe",
        stderr: "pipe",
      });
      expect(cliProc.exitCode).toBe(1);
      const stderr = cliProc.stderr.toString("utf8");
      expect(stderr).toContain("broken-needs.yml");
      expect(stderr).toContain('存在しないジョブ "typo-validate"');
    } finally {
      rmSync(workDir, { recursive: true, force: true });
    }
  });

  test("Biome 整形済みの大文字・小文字違いの重複ジョブ ID を負例として確実に拒否する", () => {
    const workDir = mkdtempSync(join(tmpdir(), "workflow-dup-job-id-"));
    try {
      const dupFile = join(workDir, "dup-job-id.yml");
      writeFileSync(
        dupFile,
        `name: Duplicate Job ID

on:
  workflow_dispatch:

jobs:
  validate:
    runs-on: ubuntu-26.04
    steps:
      - run: echo ok
  VALIDATE:
    runs-on: ubuntu-26.04
    steps:
      - run: echo dup
  prepare:
    needs: validate
    runs-on: ubuntu-26.04
    steps:
      - run: echo prepare
`,
        "utf8",
      );

      const biomeProc = Bun.spawnSync(
        [process.execPath, "x", "biome", "check", "--vcs-enabled=false", dupFile],
        {
          cwd: repoRoot,
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      expect(biomeProc.exitCode).toBe(0);

      const cliProc = Bun.spawnSync([process.execPath, cliPath, workDir], {
        cwd: repoRoot,
        stdout: "pipe",
        stderr: "pipe",
      });
      expect(cliProc.exitCode).toBe(1);
      const stderr = cliProc.stderr.toString("utf8");
      expect(stderr).toContain("dup-job-id.yml");
      expect(stderr).toContain("重複したジョブ ID");
    } finally {
      rmSync(workDir, { recursive: true, force: true });
    }
  });

  test("対象ディレクトリに YAML が 0 件の場合は失敗する", () => {
    const emptyDir = mkdtempSync(join(tmpdir(), "workflow-needs-empty-"));
    try {
      const cliProc = Bun.spawnSync([process.execPath, cliPath, emptyDir], {
        cwd: repoRoot,
        stdout: "pipe",
        stderr: "pipe",
      });
      expect(cliProc.exitCode).toBe(1);
      expect(cliProc.stderr.toString("utf8")).toContain("見つかりません");
    } finally {
      rmSync(emptyDir, { recursive: true, force: true });
    }
  });

  test("runCli は単一ファイル指定で正常終了し、存在しないパスは終了コード 1 を返す", () => {
    const logs = [];
    const errors = [];
    const io = {
      log: (msg) => logs.push(msg),
      error: (msg) => errors.push(msg),
    };

    const okCode = runCli([join(repoRoot, ".github", "workflows", "ci.yml")], io);
    expect(okCode).toBe(0);
    expect(logs.some((msg) => msg.includes("(1 files)"))).toBe(true);
    expect(errors).toEqual([]);

    const missingCode = runCli([join(repoRoot, ".github", "workflows", "does-not-exist.yml")], io);
    expect(missingCode).toBe(1);
    expect(errors.some((msg) => msg.includes("パスを読み取れません"))).toBe(true);
  });

  test("runCli は引数省略時に既定の .github/workflows を検証する", () => {
    const logs = [];
    const errors = [];
    const code = runCli([], {
      log: (msg) => logs.push(msg),
      error: (msg) => errors.push(msg),
    });
    expect(code).toBe(0);
    expect(errors).toEqual([]);
    expect(logs.length).toBe(1);
  });
});
