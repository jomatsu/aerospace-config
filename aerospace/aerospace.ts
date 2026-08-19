import { parse } from "@std/toml";

interface WorkspaceDefinition {
  name: string;
  shortcut: string;
}

// Workspace definitions (single source of truth).
// These are examples — edit to match your own setup.
const WORKSPACES = {
  ghostty: { name: "Ghostty", shortcut: "1" },
  chrome: { name: "Chrome", shortcut: "2" },
  chatgpt: { name: "ChatGPT", shortcut: "3" },
  codex: { name: "Codex", shortcut: "4" },
  other: { name: "Other", shortcut: "q" },
  obsidian: { name: "Obsidian", shortcut: "w" },
  claude: { name: "Claude", shortcut: "e" },
  slack: { name: "Slack", shortcut: "r" },
} as const satisfies Record<string, WorkspaceDefinition>;
const WORKSPACE_ORDER: readonly string[] = Object.values(WORKSPACES).map(
  ({ name }) => name,
);

type WorkspaceId = keyof typeof WORKSPACES;

interface WindowConditions {
  "app-id"?: string;
  "app-name-regex-substring"?: string;
  "window-title-regex-substring"?: string;
  workspace?: string;
}

interface AppAssignment {
  conditions: WindowConditions;
  workspace: WorkspaceId;
  postMoveCommands?: readonly string[];
}

interface Window {
  id: string;
  appId: string;
  appName: string;
  title: string;
  workspace: string;
}

interface AppRule {
  conditions: WindowConditions;
  workspace: string;
  postMoveCommands: readonly string[];
}

// Resolve the repository root from this file's location:
//   <repo>/aerospace/aerospace.ts  →  <repo>
const REPO_ROOT = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const SCRIPTS_DIR = `${REPO_ROOT}/scripts`;
const HOME = Deno.env.get("HOME")!;
const SOURCE = `${REPO_ROOT}/aerospace/.aerospace.toml`;
const TARGET = `${HOME}/.aerospace.toml`;
const EVICT_TO = WORKSPACES.other.name;
const WINDOW_FIELD_SEPARATOR = "\u001f";
const SNAPSHOT_REQUEST_COMMAND =
  `exec-and-forget ${SCRIPTS_DIR}/aerospace-workspace-snapshot-request.sh window-detected`;
const SUMMON_BINDINGS_MARKER = "    # @workspace-summon-bindings";
const MOVE_BINDINGS_MARKER = "    # @workspace-move-bindings";
const APP_ASSIGNMENTS_MARKER = "# @app-workspace-assignments";
const REPO_ROOT_MARKER = "@REPO_ROOT@";

const APP_ASSIGNMENTS: readonly AppAssignment[] = [
  {
    conditions: { "app-id": "com.mitchellh.ghostty" },
    workspace: "ghostty",
  },
  // Example: pin a custom app and run post-move layout commands.
  // {
  //   conditions: { "app-id": "com.example.my-app" },
  //   workspace: "ghostty",
  //   postMoveCommands: ["layout tiling", "move left", "resize width 280"],
  // },
  // Example: separate Chrome profiles (window title suffix) into workspaces.
  // Replace "Work"/"Personal" with your own profile names.
  {
    conditions: {
      "app-id": "com.google.Chrome",
      "window-title-regex-substring":
        "Google Chrome - Work \\(work\\.example\\.com\\)$",
    },
    workspace: "chrome",
  },
  {
    conditions: {
      "app-id": "com.google.Chrome",
      "window-title-regex-substring": "Google Chrome - Personal$",
    },
    workspace: "chatgpt",
  },
  {
    conditions: { "app-id": "com.google.Chrome" },
    workspace: "chrome",
  },
  {
    conditions: { "app-id": "com.openai.chat" },
    workspace: "chatgpt",
  },
  {
    conditions: { "app-id": "com.openai.codex" },
    workspace: "codex",
  },
  {
    conditions: { "app-id": "com.todesktop.230313mzl4w4u92" },
    workspace: "claude",
  },
  {
    conditions: { "app-id": "md.obsidian" },
    workspace: "obsidian",
  },
  {
    conditions: { "app-id": "com.tinyspeck.slackmacgap" },
    workspace: "slack",
  },
];

function tomlString(value: string): string {
  return JSON.stringify(value);
}

function tomlStringArray(values: readonly string[]): string {
  return `[${values.map(tomlString).join(", ")}]`;
}

function replaceTemplateMarker(
  template: string,
  marker: string,
  replacement: string,
): string {
  const parts = template.split(marker);
  if (parts.length !== 2) {
    throw new Error(`Expected exactly one template marker: ${marker.trim()}`);
  }
  return parts.join(replacement);
}

function injectRepoRoot(template: string): string {
  const occurrences = template.split(REPO_ROOT_MARKER).length - 1;
  if (occurrences === 0) {
    throw new Error(`Expected at least one ${REPO_ROOT_MARKER} marker`);
  }
  return template.split(REPO_ROOT_MARKER).join(REPO_ROOT);
}

function renderWorkspaceBindings(
  keyPrefix: string,
  command: "summon-workspace" | "move-node-to-workspace",
): string {
  return Object.values(WORKSPACES)
    .map(({ name, shortcut }) =>
      `    ${keyPrefix}${shortcut} = ${tomlString(`${command} ${name}`)}`
    )
    .join("\n");
}

function renderWindowRule(
  conditions: WindowConditions,
  commands: readonly string[],
): string {
  const conditionLines = Object.entries(conditions).map(
    ([key, value]) => `if.${key} = ${tomlString(value)}`,
  );
  return [
    "[[on-window-detected]]",
    ...conditionLines,
    "check-further-callbacks = false",
    `run = ${tomlStringArray(commands)}`,
  ].join("\n");
}

function renderAppAssignments(): string {
  return APP_ASSIGNMENTS.map((assignment) => {
    const workspace = WORKSPACES[assignment.workspace].name;
    return renderWindowRule(
      assignment.conditions,
      [
        `move-node-to-workspace ${workspace}`,
        ...(assignment.postMoveCommands ?? []),
        SNAPSHOT_REQUEST_COMMAND,
      ],
    );
  }).join("\n\n");
}

function renderConfigTemplate(template: string): string {
  let source = replaceTemplateMarker(
    template,
    SUMMON_BINDINGS_MARKER,
    renderWorkspaceBindings("alt-", "summon-workspace"),
  );
  source = replaceTemplateMarker(
    source,
    MOVE_BINDINGS_MARKER,
    renderWorkspaceBindings("alt-shift-", "move-node-to-workspace"),
  );
  return replaceTemplateMarker(
    source,
    APP_ASSIGNMENTS_MARKER,
    renderAppAssignments(),
  );
}

function buildAppRules(): AppRule[] {
  return APP_ASSIGNMENTS.map((assignment) => ({
    conditions: assignment.conditions,
    workspace: WORKSPACES[assignment.workspace].name,
    postMoveCommands: assignment.postMoveCommands ?? [],
  }));
}

function regexSubstringMatches(pattern: string, value: string): boolean {
  return new RegExp(pattern, "i").test(value);
}

function ruleMatchesWindow(rule: AppRule, window: Window): boolean {
  const conditions = rule.conditions;
  if (conditions["app-id"] && conditions["app-id"] !== window.appId) {
    return false;
  }
  if (
    conditions["app-name-regex-substring"] &&
    !regexSubstringMatches(
      conditions["app-name-regex-substring"],
      window.appName,
    )
  ) {
    return false;
  }
  if (
    conditions["window-title-regex-substring"] &&
    !regexSubstringMatches(
      conditions["window-title-regex-substring"],
      window.title,
    )
  ) {
    return false;
  }
  if (conditions.workspace && conditions.workspace !== window.workspace) {
    return false;
  }
  return true;
}

function findMatchingRule(
  window: Window,
  rules: readonly AppRule[],
): AppRule | undefined {
  return rules.find((rule) => ruleMatchesWindow(rule, window));
}

interface ConfigResult {
  rules: AppRule[];
  allowed: Set<string>;
}

async function generateConfig(): Promise<ConfigResult> {
  const template = await Deno.readTextFile(SOURCE);
  const source = injectRepoRoot(renderConfigTemplate(template));
  const rules = buildAppRules();
  const allowed = new Set(WORKSPACE_ORDER);
  const reserved = new Set(
    rules.map((r) => r.workspace).filter((ws) => ws !== EVICT_TO),
  );
  const nonReserved = [...allowed].filter(
    (ws) => !reserved.has(ws) && ws !== EVICT_TO,
  );

  const generatedRules = [
    "# Auto-generated (do not edit; regenerated by `deno task setup`)",
    ...[...reserved].map((workspace) =>
      renderWindowRule(
        { workspace },
        [`move-node-to-workspace ${EVICT_TO}`, SNAPSHOT_REQUEST_COMMAND],
      )
    ),
    ...nonReserved.map((workspace) =>
      renderWindowRule(
        { workspace },
        [`move-node-to-workspace ${workspace}`, SNAPSHOT_REQUEST_COMMAND],
      )
    ),
    renderWindowRule(
      {},
      [`move-node-to-workspace ${EVICT_TO}`, SNAPSHOT_REQUEST_COMMAND],
    ),
  ].join("\n\n");
  const output = `${source.trimEnd()}\n\n${generatedRules}\n`;

  parse(output);
  await Deno.writeTextFile(TARGET, output);
  return { rules, allowed };
}

async function aerospace(...args: string[]): Promise<string> {
  const cmd = new Deno.Command("aerospace", {
    args,
    stdout: "piped",
    stderr: "piped",
  });
  const { stdout } = await cmd.output();
  return new TextDecoder().decode(stdout);
}

async function listWindows(): Promise<Window[]> {
  const output = await aerospace(
    "list-windows",
    "--all",
    "--format",
    [
      "%{window-id}",
      "%{app-bundle-id}",
      "%{app-name}",
      "%{workspace}",
      "%{window-title}",
    ].join(WINDOW_FIELD_SEPARATOR),
  );
  return output
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [id = "", appId = "", appName = "", workspace = "", title = ""] =
        line.split(
          WINDOW_FIELD_SEPARATOR,
        );
      return { id, appId, appName, workspace, title };
    });
}

async function setup() {
  await generateConfig();
  console.log(`Aerospace configuration generated: ${TARGET}`);
}

async function refresh() {
  const { rules, allowed } = await generateConfig();
  await aerospace("reload-config");

  // Reverse map: workspace → designated rules
  const wsRules = new Map<string, AppRule[]>();
  for (const rule of rules) {
    if (!wsRules.has(rule.workspace)) wsRules.set(rule.workspace, []);
    wsRules.get(rule.workspace)!.push(rule);
  }

  // First pass: move designated apps to their workspaces
  const windows = await listWindows();
  await Promise.all(
    windows
      .map((window) => ({ window, rule: findMatchingRule(window, rules) }))
      .filter(({ window, rule }) => rule && rule.workspace !== window.workspace)
      .map(({ window, rule }) =>
        aerospace(
          "move-node-to-workspace",
          "--window-id",
          window.id,
          rule!.workspace,
        )
      ),
  );

  // Second pass: apply post-move layout commands (move left, resize, etc.)
  const afterMove = await listWindows();
  for (const w of afterMove) {
    const rule = findMatchingRule(w, rules);
    if (!rule || rule.postMoveCommands.length === 0) continue;
    for (const cmd of rule.postMoveCommands) {
      const parts = cmd.split(/\s+/);
      await aerospace(...parts, "--window-id", w.id);
    }
  }

  // Third pass: evict from reserved workspaces + non-allowed workspaces
  const fresh = await listWindows();
  await Promise.all(
    fresh
      .filter((w) => {
        if (findMatchingRule(w, rules)) return false; // already handled
        if (!allowed.has(w.workspace)) return true;
        const designated = wsRules.get(w.workspace);
        return designated
          ? !designated.some((rule) => ruleMatchesWindow(rule, w))
          : false;
      })
      .map((w) =>
        aerospace("move-node-to-workspace", "--window-id", w.id, EVICT_TO)
      ),
  );

  // Fourth pass: replace non-allowed workspaces on monitors with allowed ones
  const visibleOutput = await aerospace(
    "list-workspaces",
    "--monitor",
    "all",
    "--visible",
    "--format",
    "%{workspace}|%{monitor-name}",
  );
  const visibleWorkspaces = new Set<string>();
  const monitorsToFix: string[] = [];
  for (const line of visibleOutput.trim().split("\n").filter(Boolean)) {
    const [ws, monitor] = line.split("|");
    visibleWorkspaces.add(ws);
    if (!allowed.has(ws)) monitorsToFix.push(monitor);
  }

  // Move an allowed workspace (not visible on any monitor) to each broken monitor
  const available = [...allowed].filter((ws) => !visibleWorkspaces.has(ws));
  for (const monitor of monitorsToFix) {
    const ws = available.shift();
    if (ws) {
      const pattern = `^${monitor.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`;
      await aerospace("move-workspace-to-monitor", "--workspace", ws, pattern);
    }
  }

  // Push any remaining non-allowed workspaces to main (empty ones dissolve)
  const allWorkspaces = (await aerospace("list-workspaces", "--all"))
    .trim()
    .split("\n");
  for (const ws of allWorkspaces) {
    if (!allowed.has(ws)) {
      await aerospace("move-workspace-to-monitor", "--workspace", ws, "main");
    }
  }
}

switch (Deno.args[0]) {
  case "setup":
    await setup();
    break;
  case "refresh":
    await refresh();
    break;
  default:
    console.error("Usage: aerospace.ts <setup|refresh>");
    Deno.exit(1);
}