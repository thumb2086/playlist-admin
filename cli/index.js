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

  Runs the same engine as the GUI app (shared Dart code).

Usage:
  playlist-admin -v | --version | version   Show CLI + GUI 版本，並檢查有沒有新版
  playlist-admin -h | --help | help         顯示這份說明
  playlist-admin update| upgrade             更新 CLI（npm）並提示 GUI 更新方式
  playlist-admin where                      顯示根目錄 / exe / 資料夾位置
  playlist-admin doctor [--fast] [--verbose] [--no-stt]
                                         音訊庫健康檢查（覆蓋率/損毀/品質/語言/額度）

  playlist-admin pipeline [--step N]     Run full pipeline (or from step N)
  playlist-admin podcast                 Run podcast pipeline
  playlist-admin status                  Show status
  playlist-admin play <歌曲名>             播放（本機庫優先，找不到走串流）
  playlist-admin organize                  歌單外歌曲移入「未分類」資料夾
  playlist-admin artwork backfill          全庫 mp3 內嵌封面（有圖跳過）
  playlist-admin metadata enrich           補 album/date/title/artist（只讀本地快取）
  playlist-admin metadata artists          ID3 英文歌手名轉中文（對照表內）
  playlist-admin favorite list           List favorite songs
  playlist-admin favorite toggle <song>  Toggle favorite (我的最愛)
  playlist-admin rag build [--reset]     Build podcast RAG vector DB
  playlist-admin rag query "問題" [--topk N] [--show 節目] [--json]
  playlist-admin study build [--reset]   Build study RAG (PDF + 課程)
  playlist-admin study query "問題" [--topk N] [--category X] [--json]
  playlist-admin skill list              List bundled opencode skills
  playlist-admin skill install [name] [--dir X] Install skill(s) to opencode (~/.config/opencode/skills)
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
    if (parent === dir) break;
    dir = parent;
  }
  // 從 npm 全域包呼叫時 cwd 向上找不到 pubspec.yaml（npm 包不含 Dart 引擎），
  // 這時要找 GUI 的安裝目錄——它才是真正持有 playlist-admin.exe 的地方。
  // 沒有這段 fallback 的話，使用者每次都得手動設 PA_ROOT 才能跑任何命令。
  return installedRoot();
}

/// GUI 安裝目錄候選（依序找第一個真的持有 exe 的）。
///
/// 安裝版（Inno Setup）的 exe 在**目錄根層**，開發版在 build/windows/...，
/// 兩種都要認，否則只有開發者能從 npm 呼叫 CLI。
function installedRoot() {
  const home = process.env.USERPROFILE || process.env.HOME || '';
  const localAppData = process.env.LOCALAPPDATA || '';
  const programFiles = process.env.ProgramFiles || 'C:\\Program Files';
  const programFilesX86 =
    process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
  const dirs = [];
  if (localAppData) {
    dirs.push(path.join(localAppData, 'Programs', 'playlist-admin'));
    dirs.push(path.join(localAppData, 'playlist-admin'));
  }
  if (home) {
    dirs.push(path.join(home, 'playlist-admin'));
    dirs.push(path.join(home, 'Desktop', 'playlist-admin'));
  }
  dirs.push(path.join(programFiles, 'playlist-admin'));
  dirs.push(path.join(programFilesX86, 'playlist-admin'));
  for (const d of dirs) {
    if (exePath(d)) return d;
  }
  return null;
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
  if (!root) return null;
  const candidates = [
    // 安裝版（Inno Setup 打包）：exe 直接在安裝目錄根層
    path.join(root, 'playlist-admin.exe'),
    // 開發版：flutter build windows --release 的輸出
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

/// npm 包自身的版本（package.json）。CI 由 git tag 填入。
function packageVersion() {
  try {
    const pkg = path.join(packageRoot() || '', 'package.json');
    return JSON.parse(fs.readFileSync(pkg, 'utf8')).version || '?';
  } catch {
    return '?';
  }
}

/// GUI 引擎（playlist-admin.exe）的版本。
/// exe 的 Windows VersionInfo 沒被 CI 改（仍是 pubspec 的 3.0.0-beta.1），
/// 所以直接問引擎自己——它知道 build 時注入的 APP_VERSION。
function guiVersion(exe) {
  if (!exe || !fs.existsSync(exe)) return null;
  const r = spawnSync(exe, [], {
    env: { ...process.env, PA_CLI_ARGS: '["version"]' },
    encoding: 'utf8',
    windowsHide: true,
    timeout: 30000,
  });
  const out = (r.stdout || '').trim();
  const m = out.match(/Engine\s+(\S+)/);
  if (m) return m[1];
  // 引擎起不來就退回修改時間，至少讓使用者看得出新舊
  try {
    const mt = fs.statSync(exe).mtime.toISOString().slice(0, 16).replace('T', ' ');
    return `(exe 最後修改 ${mt})`;
  } catch {
    return null;
  }
}

function cmdVersion() {
  const cli = packageVersion();
  const root = installedRoot() || projectRoot();
  const exe = exePath(root);
  const gv = guiVersion(exe);
  console.log(`CLI ${cli}`);
  console.log(gv ? `GUI ${gv}  (${exe})` : 'GUI （找不到安裝中的 GUI）');
  if (gv && !gv.startsWith('(') && gv !== cli) {
    console.log('⚠️  CLI 與 GUI 版本不一致 → 先更新 GUI 再用 CLI');
  }
  const latest = runQuiet('npm', ['view', 'playlist-admin', 'version']);
  if (latest && latest !== cli) {
    console.log(`最新 ${latest}  →  npm i -g playlist-admin@latest`);
  }
}

function runQuiet(cmd, cmdArgs) {
  try {
    const r = spawnSync(cmd, cmdArgs, { encoding: 'utf8', windowsHide: true });
    return (r.stdout || '').trim().split('\n').pop();
  } catch {
    return null;
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.log(HELP);
    return;
  }
  // 標準旗標
  if (args[0] === '-h' || args[0] === '--help' || args[0] === 'help') {
    console.log(HELP);
    return;
  }
  if (args[0] === '-v' || args[0] === '--version' || args[0] === 'version') {
    cmdVersion();
    return;
  }
  if (args[0] === '--doctor') {
    args[0] = 'doctor';
  }
  if (args[0] === 'update' || args[0] === 'upgrade') {
    cmdUpdate();
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
  if (args[0] === 'where' || args[0] === 'doctor-env') {
    const root = installedRoot() || projectRoot();
    console.log(`根目錄: ${root || '(找不到)'}`);
    console.log(`exe    : ${exePath(root) || '(找不到)'}`);
    console.log(`資料   : ${path.join(root || '?', 'data')}`);
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

/// 更新 CLI 與 GUI。
function cmdUpdate() {
  console.log('更新 CLI (npm)...');
  const r = spawnSync('npm', ['install', '-g', 'playlist-admin@latest'], {
    stdio: 'inherit',
    windowsHide: true,
  });
  if (r.status !== 0) {
    console.error('npm 更新失敗，試試用系統管理員權限重跑');
    process.exit(1);
  }
  console.log('');
  console.log('更新 GUI...');
  console.log('GUI 是獨立安裝檔，請下載最新的 Setup 執行檔：');
  console.log('  https://github.com/thumb2086/playlist-admin/releases/latest');
  console.log('（或直接在 app 設定頁按「檢查更新」）');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
