/**
 * playlist-admin OpenTUI — opencode 風格的終端介面。
 *
 * 設計原則（為什麼是薄的）：
 *   所有邏輯仍在 Dart 引擎（lib/cli_main.dart，與 GUI 同一份實作）。
 *   這個 TUI 只負責「版面 + 互動」，每個動作都 spawn 一次 exe 並串流它的 stdout。
 *   好處：GUI / CLI / TUI 三者行為永遠一致，改 Dart 不用改 TS。
 *
 * 執行：bun run index.ts        （需先 build 出 exe，見 README）
 * 環境：PA_EXE  指定 exe 路徑（預設 ../build/windows/x64/runner/Release/playlist-admin.exe）
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import os from "node:os";

// ---------------------------------------------------------------- 後端：exe 橋接

const EXE_CANDIDATES = [
  process.env.PA_EXE,
  path.resolve(import.meta.dir, "../build/windows/x64/runner/Release/playlist-admin.exe"),
  path.join(os.homedir(), "Desktop/thumb/Projects/playlist-admin-src/build/windows/x64/runner/Release/playlist-admin.exe"),
].filter(Boolean) as string[];

const EXE = EXE_CANDIDATES.find((p) => existsSync(p)) ?? null;

type LineHandler = (line: string) => void;

/** 跑一條 CLI 命令，stdout/stderr 逐行回呼。回傳 exit code。 */
export function runCli(args: string[], onLine: LineHandler): Promise<number> {
  return new Promise((resolve) => {
    if (!EXE) {
      onLine(`找不到 exe（試過：${EXE_CANDIDATES.join(", ")}）`);
      resolve(127);
      return;
    }
    const ps = spawn(EXE, [], {
      env: { ...process.env, PA_CLI_ARGS: JSON.stringify(args) },
      windowsHide: true,
    });
    let buf = "";
    const pump = (chunk: Buffer | string) => {
      buf += chunk.toString();
      const parts = buf.split(/\r?\n/);
      buf = parts.pop() ?? "";
      for (const l of parts) if (l.trim().length) onLine(l);
    };
    ps.stdout.on("data", pump);
    ps.stderr.on("data", pump);
    ps.on("close", (code) => {
      if (buf.trim().length) onLine(buf.trim());
      resolve(code ?? 1);
    });
    ps.on("error", (e) => {
      onLine(`spawn 失敗: ${e.message}`);
      resolve(1);
    });
  });
}

export const hasExe = () => EXE !== null;
export const exePath = () => EXE ?? "(none)";

// ---------------------------------------------------------------- 指令表

export type Cmd = {
  id: string;
  label: string;
  hint: string;
  args: string[];
};

export const COMMANDS: Cmd[] = [
  { id: "status", label: "狀態", hint: "library / playlists / downloaded", args: ["status"] },
  { id: "pipeline", label: "執行 Pipeline", hint: "全部步驟", args: ["pipeline"] },
  { id: "podcast", label: "Podcast Pipeline", hint: "逐字稿 + RAG", args: ["podcast"] },
  { id: "lyrics", label: "歌詞下載", hint: "lyrics download", args: ["lyrics", "download"] },
  { id: "organize", label: "整理音樂庫", hint: "未分類搬移", args: ["organize"] },
  { id: "artwork", label: "補嵌封面", hint: "artwork backfill", args: ["artwork"] },
  { id: "favorite", label: "我的最愛", hint: "favorite list", args: ["favorite", "list"] },
  { id: "doctor", label: "環境健檢", hint: "doctor --fast", args: ["doctor", "--fast"] },
  { id: "estimate", label: "用量預估", hint: "下載前先看流量/磁碟", args: ["estimate"] },
];

// ---------------------------------------------------------------- 狀態

type Mode = "list" | "run";

const state = {
  mode: "list" as Mode,
  selected: 0,
  query: "",
  logs: [] as string[],
  running: false,
  status: "就緒",
};

function pushLog(s: string) {
  state.logs.push(s);
  if (state.logs.length > 2000) state.logs.splice(0, state.logs.length - 2000);
}

export function filtered(): Cmd[] {
  const q = state.query.trim().toLowerCase();
  if (!q) return COMMANDS;
  return COMMANDS.filter(
    (c) =>
      c.label.toLowerCase().includes(q) ||
      c.id.includes(q) ||
      c.hint.toLowerCase().includes(q),
  );
}

export async function exec(cmd: Cmd) {
  if (state.running) return;
  state.running = true;
  state.mode = "run";
  state.status = `執行 ${cmd.label}…`;
  pushLog(`$ playlist-admin ${cmd.args.join(" ")}`);
  try {
    const code = await runCli(cmd.args, pushLog);
    state.status = code === 0 ? `${cmd.label} 完成` : `${cmd.label} 失敗 (exit ${code})`;
    pushLog(`— exit ${code} —`);
  } finally {
    state.running = false;
  }
}

export const getState = () => state;