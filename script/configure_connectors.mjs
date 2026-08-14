#!/usr/bin/env node

import { access, copyFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, join, resolve } from "node:path";

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const workspace = option("--workspace");
const runner = option("--mcp-runner");
const skill = option("--skill");

if (!workspace || !runner || !skill) {
  console.error("usage: configure_connectors.mjs --workspace <path> --mcp-runner <path> --skill <SKILL.md>");
  process.exit(2);
}

const root = resolve(workspace);
const runnerPath = resolve(runner);
const skillPath = resolve(skill);
const controllerCandidates = [join(root, "scripts", "rig2.sh"), join(root, "scripts", "qa-rig.sh")];

async function exists(path) {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

if (!(await Promise.any(controllerCandidates.map(async (path) => {
  if (await exists(path)) return path;
  throw new Error("missing");
})).catch(() => null))) {
  throw new Error(`Workspace does not contain scripts/rig2.sh or scripts/qa-rig.sh: ${root}`);
}
if (!(await exists(runnerPath))) throw new Error(`MCP runner is missing: ${runnerPath}`);
if (!(await exists(skillPath))) throw new Error(`Rig skill is missing: ${skillPath}`);

const mcpConfigPath = join(root, ".mcp.json");
let config = {};
if (await exists(mcpConfigPath)) {
  const text = await readFile(mcpConfigPath, "utf8");
  config = JSON.parse(text);
}
if (!config || Array.isArray(config) || typeof config !== "object") config = {};
if (!config.mcpServers || Array.isArray(config.mcpServers) || typeof config.mcpServers !== "object") {
  config.mcpServers = {};
}
config.mcpServers["local-rig"] = {
  type: "stdio",
  command: runnerPath,
  args: [],
  env: { LOCAL_RIG_WORKSPACE_ROOT: root },
};

await mkdir(dirname(mcpConfigPath), { recursive: true });
const temporaryConfig = `${mcpConfigPath}.local-rig-installing`;
await writeFile(temporaryConfig, `${JSON.stringify(config, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
await rename(temporaryConfig, mcpConfigPath);

const skillDestinations = [
  join(root, ".claude", "skills", "rig", "SKILL.md"),
  join(root, ".agents", "skills", "rig", "SKILL.md"),
];
for (const destination of skillDestinations) {
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(skillPath, destination);
}

console.log(JSON.stringify({
  workspace: root,
  mcp_config: mcpConfigPath,
  mcp_runner: runnerPath,
  skills: skillDestinations,
}, null, 2));
