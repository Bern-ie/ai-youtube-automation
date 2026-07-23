#!/usr/bin/env node
// Imports n8n/workflows/*.json into the running n8n instance, resolving
// two things that are always instance-specific and can never be baked
// into a portable export: credential IDs (nodes reference credentials by
// {id, name} — the id only exists on the instance that created it) and
// sub-workflow IDs (the "Step4 Config Loader Test" orchestrator calls the
// five reusable workflows by ID via Execute Workflow nodes). Both are
// resolved here by NAME, against whatever this instance actually has —
// see docs/architecture/workflow-runtime.md#n8n-credential-setup for the
// manual-UI alternative this automates away.
//
// Zero npm dependencies on purpose (uses Node's built-in fetch) so this
// can run standalone: `node scripts/n8n-import-workflows.mjs`.
//
// Safe to re-run: a workflow whose name already exists on the instance is
// updated in place (PUT) rather than duplicated.

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..');

function loadEnv() {
  const envPath = join(REPO_ROOT, '.env');
  const env = { ...process.env };
  let text;
  try {
    text = readFileSync(envPath, 'utf8');
  } catch {
    return env;
  }
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (!(key in env)) env[key] = value;
  }
  return env;
}

const env = loadEnv();
const N8N_URL = `http://127.0.0.1:${env.N8N_PORT || 5678}`;
const API_KEY = env.N8N_API_KEY;

if (!API_KEY || API_KEY === 'CHANGE_ME') {
  console.error('N8N_API_KEY is not set — run scripts/n8n-setup-dev.sh first.');
  process.exit(1);
}

async function api(path, options = {}) {
  const res = await fetch(`${N8N_URL}/api/v1${path}`, {
    ...options,
    headers: { 'X-N8N-API-KEY': API_KEY, 'Content-Type': 'application/json', ...options.headers },
  });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { raw: text };
  }
  if (!res.ok) {
    throw new Error(`${options.method || 'GET'} ${path} -> ${res.status}: ${JSON.stringify(body)}`);
  }
  return body;
}

// Import order matters: the orchestrator's Execute Workflow nodes
// reference the five reusable workflows by ID, so they must exist first.
const IMPORT_ORDER = [
  'initialize-workflow-run.json',
  'load-channel-configuration.json',
  'mark-workflow-step.json',
  'complete-workflow-run.json',
  'fail-workflow-run.json',
  'step4-config-loader-test.json',
  'validate-manual-topic.json',
  'check-manual-topic-duplicate.json',
  'check-manual-topic-capacity-and-budget.json',
  'create-manual-topic-project.json',
  'get-workflow-run-steps.json',
  'manual-topic-intake.json',
  'step5-manual-topic-intake-test.json',
];

async function main() {
  console.log(`Importing into ${N8N_URL}...`);

  const credentials = (await api('/credentials')).data;
  const credentialIdByName = Object.fromEntries(credentials.map((c) => [c.name, c.id]));

  const existingWorkflows = (await api('/workflows')).data;
  const workflowIdByName = Object.fromEntries(existingWorkflows.map((w) => [w.name, w.id]));

  const workflowsDir = join(REPO_ROOT, 'n8n', 'workflows');
  const available = new Set(readdirSync(workflowsDir).filter((f) => f.endsWith('.json')));

  for (const file of IMPORT_ORDER) {
    if (!available.has(file)) {
      console.warn(`skip: ${file} not found in n8n/workflows/`);
      continue;
    }
    const def = JSON.parse(readFileSync(join(workflowsDir, file), 'utf8'));

    for (const node of def.nodes) {
      if (node.credentials) {
        for (const [credType, ref] of Object.entries(node.credentials)) {
          const resolvedId = credentialIdByName[ref.name];
          if (!resolvedId) {
            throw new Error(
              `Node "${node.name}" in ${file} references credential "${ref.name}" (type ${credType}), ` +
                `which does not exist on this n8n instance. Run scripts/n8n-setup-dev.sh first.`,
            );
          }
          ref.id = resolvedId;
        }
      }
      if (node.type === 'n8n-nodes-base.executeWorkflow') {
        // The exported JSON only carries the *old* instance's workflow ID
        // in `value` — resolve it by looking up the file this node
        // is meant to call, then that file's freshly-imported ID.
        const sourceFile = EXECUTE_WORKFLOW_TARGETS[node.name];
        if (sourceFile) {
          const targetId = workflowIdByName[FILE_TO_WORKFLOW_NAME[sourceFile]];
          if (!targetId) {
            throw new Error(`Node "${node.name}" in ${file} needs "${sourceFile}" imported first.`);
          }
          node.parameters.workflowId.value = targetId;
        }
      }
    }

    const payload = { name: def.name, nodes: def.nodes, connections: def.connections, settings: def.settings || {} };
    let workflowId = workflowIdByName[def.name];
    if (workflowId) {
      await api(`/workflows/${workflowId}`, { method: 'PUT', body: JSON.stringify(payload) });
      console.log(`updated: ${def.name} (${workflowId})`);
    } else {
      const created = await api('/workflows', { method: 'POST', body: JSON.stringify(payload) });
      workflowId = created.id;
      workflowIdByName[def.name] = workflowId;
      console.log(`created: ${def.name} (${workflowId})`);
    }

    await api(`/workflows/${workflowId}/activate`, { method: 'POST' });
    console.log(`published: ${def.name}`);
  }

  console.log('\nAll workflows imported and published.');
}

// Maps each Execute Workflow node (by its node name in the orchestrator)
// to the file it's meant to call — used to resolve that sub-workflow's
// freshly-imported ID on this instance.
const EXECUTE_WORKFLOW_TARGETS = {
  'Initialize Workflow Run': 'initialize-workflow-run.json',
  'Mark Step Running': 'mark-workflow-step.json',
  'Load Channel Configuration': 'load-channel-configuration.json',
  'Mark Step Succeeded': 'mark-workflow-step.json',
  'Complete Workflow Run': 'complete-workflow-run.json',
  'Mark Step Failed': 'mark-workflow-step.json',
  'Fail Workflow Run': 'fail-workflow-run.json',
  // Step 5 — "Manual Topic Intake" reusable orchestrator.
  'Mark Step Running (load_config)': 'mark-workflow-step.json',
  'Mark Step Succeeded (load_config)': 'mark-workflow-step.json',
  'Get Workflow Run Steps': 'get-workflow-run-steps.json',
  'Mark Step Running: validate_topic': 'mark-workflow-step.json',
  'Call: validate_topic': 'validate-manual-topic.json',
  'Mark Step Succeeded: validate_topic': 'mark-workflow-step.json',
  'Mark Step Running: check_duplicate': 'mark-workflow-step.json',
  'Call: check_duplicate': 'check-manual-topic-duplicate.json',
  'Mark Step Succeeded: check_duplicate': 'mark-workflow-step.json',
  'Mark Step Running: check_budget_and_capacity': 'mark-workflow-step.json',
  'Call: check_budget_and_capacity': 'check-manual-topic-capacity-and-budget.json',
  'Mark Step Succeeded: check_budget_and_capacity': 'mark-workflow-step.json',
  'Mark Step Running: create_content_project': 'mark-workflow-step.json',
  'Call: create_content_project': 'create-manual-topic-project.json',
  'Mark Step Succeeded: create_content_project': 'mark-workflow-step.json',
  // Step 5 — "Step5 Manual Topic Intake Test" dev webhook.
  'Manual Topic Intake': 'manual-topic-intake.json',
};
const FILE_TO_WORKFLOW_NAME = {
  'initialize-workflow-run.json': 'Initialize Workflow Run',
  'load-channel-configuration.json': 'Load Channel Configuration',
  'mark-workflow-step.json': 'Mark Workflow Step',
  'complete-workflow-run.json': 'Complete Workflow Run',
  'fail-workflow-run.json': 'Fail Workflow Run',
  'validate-manual-topic.json': 'Validate Manual Topic',
  'check-manual-topic-duplicate.json': 'Check Manual Topic Duplicate',
  'check-manual-topic-capacity-and-budget.json': 'Check Manual Topic Capacity And Budget',
  'create-manual-topic-project.json': 'Create Manual Topic Project',
  'get-workflow-run-steps.json': 'Get Workflow Run Steps',
  'manual-topic-intake.json': 'Manual Topic Intake',
};

main().catch((err) => {
  console.error('Import failed:', err.message);
  process.exit(1);
});
