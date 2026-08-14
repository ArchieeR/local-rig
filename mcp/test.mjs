import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const testArtifacts = await mkdtemp(join(tmpdir(), "local-rig-mcp-test-"));
const childEnv = Object.fromEntries(Object.entries(process.env).filter(([, value]) => value !== undefined));
childEnv.LOCAL_RIG_MCP_DASHBOARD_ROOT = testArtifacts;
childEnv.LOCAL_RIG_WORKSPACE_ROOT = root;
const transport = new StdioClientTransport({ command: join(here, "run.sh"), args: [], env: childEnv });
const client = new Client({ name: "local-rig-smoke-test", version: "0.1.0" });
let cleanupRig = null;
let cleanupSession = null;

try {
  await client.connect(transport);
  const listed = await client.listTools();
  const names = listed.tools.map((tool) => tool.name);
  const banned = ["reset", "seed", "point", "shell", "firebase", "firestore"];
  assert(names.includes("local_rig_list"));
  assert(names.includes("local_rig_create_handoff"));
  assert(names.includes("local_rig_bind"));
  assert(names.includes("local_rig_unbind"));
  for (const name of names) assert(!banned.some((word) => name.includes(word)), `unsafe tool exposed: ${name}`);
  for (const tool of listed.tools) {
    assert.equal(tool.annotations?.openWorldHint, false, `${tool.name} must be closed-world`);
    assert.equal(typeof tool.annotations?.readOnlyHint, "boolean", `${tool.name} lacks readOnlyHint`);
  }

  const context = await client.callTool({ name: "local_rig_get_context", arguments: {} });
  assert.equal(context.isError, undefined);
  assert.equal(context.structuredContent.workspace, root);
  assert.equal(context.structuredContent.safety.firestore_access, false);

  const rigs = await client.callTool({ name: "local_rig_list", arguments: {} });
  assert.equal(rigs.structuredContent.rigs.length, 5);
  const sharedRig = rigs.structuredContent.rigs.find((rig) => rig.rig > 1 && rig.mode === "shared");
  assert(sharedRig, "expected at least one shared rig in the local contract fixture");
  assert.equal(sharedRig.log_paths.emulator, join(root, ".rig2", "1", "emu.log"));

  const resources = await client.listResources();
  assert(resources.resources.some((resource) => resource.uri === "rig://current"));
  const current = await client.readResource({ uri: "rig://current" });
  assert(current.contents[0].text.includes('"rigs"'));

  const controlRig = [...rigs.structuredContent.rigs].reverse().find((rig) => {
    const defaultRepo = join(root, rig.rig === 1 ? "wt-qa-rig" : `wt-rig${rig.rig}`);
    return rig.rig > 1
      && !rig.holder
      && !rig.dev.running
      && (rig.mode === "shared" || !rig.emulator.healthy)
      && rig.repo === defaultRepo
      && rig.backend.repo === join(root, "rheos-backend");
  });
  assert(controlRig, "a free, stopped, default-bound rig is required for the control smoke test");

  const handoff = await client.callTool({
    name: "local_rig_create_handoff",
    arguments: { rig: controlRig.rig, summary: "MCP smoke test; no service processes were started.", next_step: "Inspect the listed rig state.", include_logs: false },
  });
  assert.equal(handoff.structuredContent.success, true);

  const session = `mcp-smoke-${process.pid}`;
  cleanupRig = controlRig.rig;
  cleanupSession = session;
  const claim = await client.callTool({ name: "local_rig_claim", arguments: { rig: controlRig.rig, session } });
  assert.equal(claim.structuredContent.success, true, JSON.stringify(claim.structuredContent));
  const bind = await client.callTool({
    name: "local_rig_bind",
    arguments: { rig: controlRig.rig, session, dashboard_path: controlRig.repo, backend_path: join(root, "rheos-backend") },
  });
  assert.equal(bind.structuredContent.success, true, JSON.stringify(bind.structuredContent));
  const bound = await client.callTool({ name: "local_rig_get", arguments: { rig: controlRig.rig } });
  assert.equal(bound.structuredContent.repo, controlRig.repo);
  assert.equal(bound.structuredContent.backend.repo, join(root, "rheos-backend"));
  const wrongRelease = await client.callTool({ name: "local_rig_release", arguments: { rig: controlRig.rig, session: "wrong-owner" } });
  assert.equal(wrongRelease.isError, true, "a different session must not release the claim");
  const wrongUnbind = await client.callTool({ name: "local_rig_unbind", arguments: { rig: controlRig.rig, session: "wrong-owner" } });
  assert.equal(wrongUnbind.isError, true, "a different session must not change worktree bindings");
  const unbind = await client.callTool({ name: "local_rig_unbind", arguments: { rig: controlRig.rig, session } });
  assert.equal(unbind.structuredContent.success, true, JSON.stringify(unbind.structuredContent));
  const release = await client.callTool({ name: "local_rig_release", arguments: { rig: controlRig.rig, session } });
  assert.equal(release.structuredContent.success, true, JSON.stringify(release.structuredContent));
  cleanupRig = null;
  cleanupSession = null;

  console.log(`ok - ${names.length} tools, ${resources.resources.length} resources, read/write/control smoke test passed`);
} finally {
  if (cleanupRig && cleanupSession) {
    try { await client.callTool({ name: "local_rig_unbind", arguments: { rig: cleanupRig, session: cleanupSession } }); } catch {}
    try { await client.callTool({ name: "local_rig_release", arguments: { rig: cleanupRig, session: cleanupSession } }); } catch {}
  }
  await client.close();
  await rm(testArtifacts, { recursive: true, force: true });
}
