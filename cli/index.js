#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Thin launcher: the CLI engine lives in the Flutter app binary
// (lib/cli_main.dart), so GUI and CLI share one implementation.
// This script just locates the built exe / rag scripts and forwards args.

const HELP = `playlist-admin CLI

  Runs the same engine as the GUI app (shared Dart code). Requires a built
  release: flutter build windows --release

Usage:
  playlist-admin pipeline [--step N]     Run full pipeline (or from step N)
  playlist-admin podcast                 Run podcast pipeline
  playlist-admin status                  Show status
  playlist-admin favorite list           List favorite songs
  playlist-admin favorite toggle <song>  Toggle favorite (我的最愛)
  playlist-admin rag build [--reset]     Build podcast RAG vector DB
  playlist-admin rag query "問題" [--topk N] [--show 節目] [--json]
  playlist-admin study build [--reset]   Build study RAG (PDF + 課程)
  playlist-admin study query "問題" [--topk N] [--category X] [--json]
  playlist-admin skill list              List bundled opencode skills
  playlist-admin skill install [--dir X] Install skill(s) to opencode (~/.config/opencode/skills)
  playlist-admin skill path [name]       Print installed path of a skill
`;

function projectRoot() {
  if (process.env.PA_ROOT && fs.existsSync(process.env.PA_ROOT)) {
    return process.env.PA_ROOT;
  }
  // Start from cwd and walk up to find the Flutter project (works whether
  // invoked locally or from a globally installed npm package).
  let dir = process.cwd();
  while (true) {
    if (fs.existsSync(path.join(dir, 'pubspec.yaml'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/// npm 包自身目錄（全域 npm i -g 時，cwd 向上找不到 pubspec，
/// 但包內自帶 cli/ + rag/，RAG 命令靠它就能跑）。
function packageRoot() {
  try {
    return path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  } catch {
    return null;
  }
}

function exePath(root) {
  const candidates = [
    path.join(root, 'build', 'windows', 'x64', 'runner', 'Release', 'playlist-admin.exe'),
    path.join(root, 'build', 'windows', 'x64', 'runner', 'Debug', 'playlist-admin.exe'),
    path.join(root, 'build', 'windows', 'arm64', 'runner', 'Release', 'playlist-admin.exe'),
    path.join(root, 'build', 'windows', 'arm64', 'runner', 'Debug', 'playlist-admin.exe'),
    path.join(root, 'build', 'windows', 'x64', 'runner', 'Release', 'playlist_administrator.exe'),
  ];
  return candidates.find((c) => fs.existsSync(c)) || null;
}

function python() {
  if (process.env.PYTHON) return process.env.PYTHON;
  // Windows 常只有 py launcher 或 python：依序探測可用的。
  for (const cmd of ['py', 'python', 'python3']) {
    try {
      const r = spawnSync(cmd, ['--version'], { stdio: 'ignore', windowsHide: true });
      if (r.status === 0) return cmd;
    } catch {
      // 試下一個
    }
  }
  return 'python';
}

function forward(exe, args) {
  // Deliver CLI args via PA_CLI_ARGS (JSON) — Flutter Dart exposes no
  // command-line args in release on this SDK (see lib/main.dart).
  // PA_ROOT lets the Python bridge find rag/ scripts when invoked from the CLI.
  const root = projectRoot();
  const child = spawn(exe, [], {
    stdio: 'inherit',
    windowsHide: false,
    env: {
      ...process.env,
      PA_CLI_ARGS: JSON.stringify(args),
      ...(root ? { PA_ROOT: root } : {}),
    },
  });
  child.on('exit', (code) => process.exit(code ?? 1));
  child.on('error', (e) => {
    console.error(`無法啟動 ${exe}: ${e.message}`);
    process.exit(1);
  });
}

function forwardPy(args) {
  // Python scripts take real argv.
  const child = spawn(python(), args, { stdio: 'inherit', windowsHide: false });
  child.on('exit', (code) => process.exit(code ?? 1));
  child.on('error', (e) => {
    console.error(`無法啟動 python: ${e.message}`);
    process.exit(1);
  });
}

function runRag(args) {
  const sub = args[0];
  if (sub !== 'build' && sub !== 'query') {
    console.error(`未知 rag 子命令: ${sub ?? '(空)'}\n用法: playlist-admin rag build | playlist-admin rag query "問題"`);
    process.exit(1);
  }
  // 優先專案內 rag/（開發時最新），全域安裝時退回包內自帶的 rag/。
  const roots = [projectRoot(), packageRoot()].filter(Boolean);
  const fname = sub === 'build' ? 'build_db.py' : 'query.py';
  const script = roots.map((r) => path.join(r, 'rag', fname)).find((s) => fs.existsSync(s));
  if (!script) {
    console.error(`找不到 rag/${fname}。請在專案內執行，或設定 PA_ROOT`);
    process.exit(1);
  }
  forwardPy([script, ...args.slice(1)]);
}

function runStudy(args) {
  const sub = args[0];
  if (sub !== 'build' && sub !== 'query') {
    console.error(`未知 study 子命令: ${sub ?? '(空)'}\n用法: playlist-admin study build | playlist-admin study query "問題"`);
    process.exit(1);
  }
  const roots = [projectRoot(), packageRoot()].filter(Boolean);
  const fname = sub === 'build' ? 'study_build.py' : 'study_query.py';
  const script = roots.map((r) => path.join(r, 'rag', fname)).find((s) => fs.existsSync(s));
  if (!script) {
    console.error(`找不到 rag/${fname}。請在專案內執行，或設定 PA_ROOT`);
    process.exit(1);
  }
  forwardPy([script, ...args.slice(1)]);
}

// --- opencode skill ------------------------------------------------------
// 單一真相來源：.opencode/skills/<name>/SKILL.md（專案內）
// 發佈物內位置：npm 包同路徑；GUI 安裝目錄下 skills/<name>/SKILL.md。
// 安裝目標（opencode v2 官方）：~/.config/opencode/skills/<name>/SKILL.md

function skillBaseDirs() {
  const dirs = [];
  for (const r of [projectRoot(), packageRoot()].filter(Boolean)) {
    for (const sub of ['.opencode/skills', 'skills']) {
      const d = path.join(r, sub);
      if (fs.existsSync(d)) dirs.push(d);
    }
  }
  // GUI 安裝目錄（Inno DefaultDirName {autopf}\playlist-admin）
  const pf = [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean);
  for (const p of pf) {
    const d = path.join(p, 'playlist-admin', 'skills');
    if (fs.existsSync(d)) dirs.push(d);
  }
  return [...new Set(dirs)];
}

function findSkills() {
  // [{name, dir}]，同名以前面的來源優先
  const out = [];
  const seen = new Set();
  for (const base of skillBaseDirs()) {
    let entries = [];
    try {
      entries = fs.readdirSync(base, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (!e.isDirectory() || seen.has(e.name)) continue;
      if (!fs.existsSync(path.join(base, e.name, 'SKILL.md'))) continue;
      seen.add(e.name);
      out.push({ name: e.name, dir: path.join(base, e.name) });
    }
  }
  return out;
}

function globalSkillsDir() {
  return path.join(os.homedir(), '.config', 'opencode', 'skills');
}

function runSkill(args) {
  const sub = args[0] || 'list';
  if (sub === 'list') {
    const skills = findSkills();
    if (skills.length === 0) {
      console.error('找不到內附的 skill（缺 .opencode/skills/ 或 skills/）');
      process.exit(1);
    }
    for (const s of skills) console.log(`${s.name}\t${s.dir}`);
    return;
  }
  if (sub === 'path') {
    const name = args[1] || 'podcast-knowledge';
    console.log(path.join(globalSkillsDir(), name, 'SKILL.md'));
    return;
  }
  if (sub === 'install') {
    // playlist-admin skill install [name] [--dir X]（無 name = 全部）
    const dirFlag = args.find((a) => a.startsWith('--dir='));
    const dirIdx = args.indexOf('--dir');
    const dirVal =
      dirFlag?.slice('--dir='.length) ||
      (dirIdx >= 0 && args[dirIdx + 1] ? args[dirIdx + 1] : null);
    const rest = args.slice(1).filter((a, i, arr) => {
      if (a.startsWith('--')) return false;
      const prev = arr[i - 1];
      if (prev === '--dir') return false; // --dir 的值不是 skill 名
      return true;
    });
    const targetBase = dirVal || globalSkillsDir();
    const skills = findSkills().filter((s) => rest.length === 0 || rest.includes(s.name));
    if (skills.length === 0) {
      console.error(`找不到 skill: ${rest.join(' ') || '(空)'}。先跑 playlist-admin skill list`);
      process.exit(1);
    }
    for (const s of skills) {
      const dest = path.join(targetBase, s.name);
      fs.mkdirSync(dest, { recursive: true });
      fs.cpSync(s.dir, dest, { recursive: true });
      console.log(`已安裝 ${s.name} -> ${path.join(dest, 'SKILL.md')}`);
    }
    console.log('opencode 重啟後生效（全域: ~/.config/opencode/skills/<name>/SKILL.md）');
    return;
  }
  console.error(`未知 skill 子命令: ${sub}\n用法: playlist-admin skill list | install | path`);
  process.exit(1);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.log(HELP);
    return;
  }
  if (args[0] === 'rag') {
    runRag(args.slice(1));
    return;
  }
  if (args[0] === 'study') {
    runStudy(args.slice(1));
    return;
  }
  if (args[0] === 'skill') {
    runSkill(args.slice(1));
    return;
  }

  const root = projectRoot();
  if (!root) {
    console.error('找不到專案根目錄（pubspec.yaml）。請在專案內執行，或設定 PA_ROOT');
    process.exit(1);
  }
  const exe = exePath(root);
  if (!exe) {
    console.error(`找不到 build 好的 exe。
請先在專案內執行: flutter build windows --release
或設定 PA_ROOT=<專案根目錄>`);
    process.exit(1);
  }
  forward(exe, args);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
