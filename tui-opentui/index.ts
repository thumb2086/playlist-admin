/**
 * OpenTUI 版面 — opencode 風格：上=狀態列、左=指令清單、右=串流日誌、下=輸入列。
 * 只用 @opentui/core 的宣告式 API（不依賴 React），保持單檔可讀。
 */

import {
  BoxRenderable,
  TextRenderable,
  InputRenderable,
  ScrollBoxRenderable,
  createCliRenderer,
} from "@opentui/core";
import {
  COMMANDS,
  exec,
  filtered,
  getState,
  hasExe,
  exePath,
  type Cmd,
} from "./core";

const W = { list: 34, pad: 1 };

function colorFor(line: string) {
  if (line.includes("❌") || line.includes("ERROR")) return "#ff6b6b";
  if (line.includes("✅") || line.includes("完成")) return "#4ade80";
  if (line.startsWith("$") || line.startsWith("—")) return "#7dd3fc";
  return "#94a3b8";
}

const renderer = await createCliRenderer({
  exitOnCtrlC: true,
  targetFps: 30,
});

const root = new BoxRenderable(renderer, {
  flexDirection: "column",
  width: "100%",
  height: "100%",
  backgroundColor: "#0b1220",
});

// ---- 狀態列
const statusBar = new TextRenderable(renderer, {
  content: "",
  fg: "#7dd3fc",
  height: 1,
  paddingLeft: W.pad,
});

// ---- 主體：左清單 + 右日誌
const body = new BoxRenderable(renderer, {
  flexDirection: "row",
  flexGrow: 1,
  minHeight: 0,
});

const listBox = new BoxRenderable(renderer, {
  width: W.list,
  flexDirection: "column",
  border: ["left"],
  borderStyle: "single",
  borderColor: "#1e293b",
});

const listTitle = new TextRenderable(renderer, {
  content: "指令  (Tab 切換 / ↑↓ 選 / Enter 執行)",
  fg: "#64748b",
  height: 1,
  paddingLeft: W.pad,
});

const listScroll = new ScrollBoxRenderable(renderer, {
  flexGrow: 1,
  minHeight: 0,
  contentOptions: { flexDirection: "column" },
});

const logBox = new BoxRenderable(renderer, {
  flexGrow: 1,
  flexDirection: "column",
  border: ["right"],
  borderStyle: "single",
  borderColor: "#1e293b",
});

const logTitle = new TextRenderable(renderer, {
  content: "輸出",
  fg: "#64748b",
  height: 1,
  paddingLeft: W.pad,
});

const logScroll = new ScrollBoxRenderable(renderer, {
  flexGrow: 1,
  minHeight: 0,
  contentOptions: { flexDirection: "column" },
});

// ---- 輸入列（指令篩選）
const input = new InputRenderable(renderer, {
  placeholder: "搜尋指令…（Esc 清空）",
  width: "100%",
  height: 1,
  backgroundColor: "#111827",
  focusedBackgroundColor: "#1f2937",
  textColor: "#e2e8f0",
});

listBox.add(listTitle);
listBox.add(listScroll);
logBox.add(logTitle);
logBox.add(logScroll);
body.add(listBox);
body.add(logBox);
root.add(statusBar);
root.add(body);
root.add(input);
renderer.root = root;

// ---- 清單渲染
let rowNodes: TextRenderable[] = [];

function renderList() {
  for (const r of rowNodes) r.destroyRecursively();
  listScroll.getChildren().forEach((c) => c.destroyRecursively());
  rowNodes = [];

  const items = filtered();
  if (!items.length) {
    rowNodes.push(
      new TextRenderable(renderer, {
        content: "  無符合指令",
        fg: "#64748b",
        height: 1,
        paddingLeft: W.pad,
      }),
    );
  }
  items.forEach((c, i) => {
    const sel = i === getState().selected;
    rowNodes.push(
      new TextRenderable(renderer, {
        content: `${sel ? "›" : " "} ${c.label}`,
        fg: sel ? "#4ade80" : "#cbd5e1",
        bg: sel ? "#1f2937" : undefined,
        height: 1,
        paddingLeft: W.pad,
      }),
    );
  });
  for (const r of rowNodes) listScroll.add(r);
}

// ---- 日誌渲染（只重繪尾端 400 行，避免每次 append 全清）
function renderLogs() {
  logScroll.getChildren().forEach((c) => c.destroyRecursively());
  const tail = getState().logs.slice(-400);
  for (const l of tail) {
    logScroll.add(
      new TextRenderable(renderer, {
        content: l.length > 400 ? l.slice(0, 400) + "…" : l,
        fg: colorFor(l),
        height: 1,
        paddingLeft: W.pad,
      }),
    );
  }
  logScroll.scrollTo(0, Math.max(0, tail.length - 1));
}

function refresh() {
  const s = getState();
  const exe = hasExe() ? exePath() : "找不到 exe";
  statusBar.content =
    `playlist-admin TUI  |  ${s.status}  |  ${s.running ? "● 執行中" : "○ 待機"}  |  ${exe}`;
  renderList();
  renderLogs();
  renderer.requestRender();
}

// ---- 鍵盤
let focus: "list" | "input" = "list";

renderer.on("key", async (k) => {
  const s = getState();

  if (k.name === "f10" || (k.ctrl && k.name === "c")) {
    renderer.destroy();
    process.exit(0);
  }

  // Tab 在 list / input 之間切換
  if (k.name === "tab") {
    focus = focus === "list" ? "input" : "list";
    if (focus === "input") input.focus();
    else input.blur();
    refresh();
    return;
  }

  if (focus === "input") {
    if (k.name === "escape") {
      input.setText("");
      s.query = "";
      s.selected = 0;
      input.blur();
      focus = "list";
      refresh();
    }
    return; // 其餘交給 InputRenderable
  }

  if (k.name === "up") {
    s.selected = Math.max(0, s.selected - 1);
    refresh();
  } else if (k.name === "down") {
    const n = filtered().length;
    s.selected = Math.min(Math.max(0, n - 1), s.selected + 1);
    refresh();
  } else if (k.name === "return" || k.name === "enter") {
    const cmd: Cmd | undefined = filtered()[s.selected];
    if (cmd) await exec(cmd);
    refresh();
  }
});

input.on("changed", (e: any) => {
  const s = getState();
  s.query = String(e?.text ?? input.plainText ?? "");
  s.selected = 0;
  renderList();
  renderer.requestRender();
});

// ---- 初始
renderList();
renderLogs();
refresh();

// 背景：執行中每 400ms 重繪日誌（串流感）
setInterval(() => {
  if (getState().running) refresh();
}, 400);