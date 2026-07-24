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
  // Step 6 — research pipeline. Leaf SQL wrappers first, then the
  // composite provider-calling sub-workflows, then the orchestrator and
  // everything that references it.
  'get-channel-prompt.json',
  'get-project-sources.json',
  'get-project-claims.json',
  'get-current-research-package.json',
  'load-content-project-for-research.json',
  'research-budget-preflight.json',
  'upsert-research-plan.json',
  'collect-research-sources-sql.json',
  'create-research-claims-batch-sql.json',
  'verify-research-claims.json',
  'build-research-package-sql.json',
  'research-quality-control.json',
  'create-research-approval.json',
  'resolve-research-approval.json',
  'record-provider-usage-event.json',
  'record-cost-event.json',
  'build-research-plan.json',
  'collect-research-sources.json',
  'extract-research-claims.json',
  'build-research-package-and-qc.json',
  'research-project.json',
  'resolve-research-approval-workflow.json',
  'step6-research-project-test.json',
  'dev-list-pending-research-approvals.json',
  'dev-get-research-approval-package.json',
  'dev-decide-research-approval.json',
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
  // Step 6 — composite provider-calling sub-workflows (shared node names
  // across build-research-plan.json / collect-research-sources.json /
  // extract-research-claims.json / build-research-package-and-qc.json —
  // every occurrence resolves to the same target, so one flat entry
  // covers all of them).
  'Get Channel Prompt': 'get-channel-prompt.json',
  'Get Project Sources': 'get-project-sources.json',
  'Get Project Claims': 'get-project-claims.json',
  'Record Usage: Input Tokens': 'record-provider-usage-event.json',
  'Record Usage: Output Tokens': 'record-provider-usage-event.json',
  'Record Cost Event': 'record-cost-event.json',
  'Record Search Usage': 'record-provider-usage-event.json',
  'Record Search Cost': 'record-cost-event.json',
  'Upsert Research Plan': 'upsert-research-plan.json',
  'Collect Research Sources SQL': 'collect-research-sources-sql.json',
  'Create Research Claims Batch SQL': 'create-research-claims-batch-sql.json',
  'Verify Research Claims': 'verify-research-claims.json',
  // build-research-package-and-qc.json's three attempt blocks (initial /
  // retry_1 / retry_2) namespace every node name with a "(label)" suffix
  // to stay unique within that one workflow.
  'Record Usage: Input Tokens (initial)': 'record-provider-usage-event.json',
  'Record Usage: Output Tokens (initial)': 'record-provider-usage-event.json',
  'Record Cost Event (initial)': 'record-cost-event.json',
  'Build Research Package SQL (initial)': 'build-research-package-sql.json',
  'Research Quality Control (initial)': 'research-quality-control.json',
  'Record Usage: Input Tokens (retry_1)': 'record-provider-usage-event.json',
  'Record Usage: Output Tokens (retry_1)': 'record-provider-usage-event.json',
  'Record Cost Event (retry_1)': 'record-cost-event.json',
  'Build Research Package SQL (retry_1)': 'build-research-package-sql.json',
  'Research Quality Control (retry_1)': 'research-quality-control.json',
  'Record Usage: Input Tokens (retry_2)': 'record-provider-usage-event.json',
  'Record Usage: Output Tokens (retry_2)': 'record-provider-usage-event.json',
  'Record Cost Event (retry_2)': 'record-cost-event.json',
  'Build Research Package SQL (retry_2)': 'build-research-package-sql.json',
  'Research Quality Control (retry_2)': 'research-quality-control.json',
  // Step 6 — "Research Project" reusable orchestrator (8 unrolled steps,
  // each with its own Mark Running / Call / Mark Failed / Fail Workflow
  // Run / Mark Succeeded cluster, same pattern as "Manual Topic Intake").
  'Mark Step Running: load_channel_configuration': 'mark-workflow-step.json',
  'Call: load_channel_configuration': 'load-channel-configuration.json',
  'Mark Step Failed: load_channel_configuration': 'mark-workflow-step.json',
  'Fail Workflow Run: load_channel_configuration': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_channel_configuration': 'mark-workflow-step.json',
  'Mark Step Running: load_content_project': 'mark-workflow-step.json',
  'Call: load_content_project': 'load-content-project-for-research.json',
  'Mark Step Failed: load_content_project': 'mark-workflow-step.json',
  'Fail Workflow Run: load_content_project': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_content_project': 'mark-workflow-step.json',
  'Mark Step Running: budget_preflight': 'mark-workflow-step.json',
  'Call: budget_preflight': 'research-budget-preflight.json',
  'Mark Step Failed: budget_preflight': 'mark-workflow-step.json',
  'Fail Workflow Run: budget_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: budget_preflight': 'mark-workflow-step.json',
  'Mark Step Running: build_research_plan': 'mark-workflow-step.json',
  'Call: build_research_plan': 'build-research-plan.json',
  'Mark Step Failed: build_research_plan': 'mark-workflow-step.json',
  'Fail Workflow Run: build_research_plan': 'fail-workflow-run.json',
  'Mark Step Succeeded: build_research_plan': 'mark-workflow-step.json',
  'Mark Step Running: collect_sources': 'mark-workflow-step.json',
  'Call: collect_sources': 'collect-research-sources.json',
  'Mark Step Failed: collect_sources': 'mark-workflow-step.json',
  'Fail Workflow Run: collect_sources': 'fail-workflow-run.json',
  'Mark Step Succeeded: collect_sources': 'mark-workflow-step.json',
  'Mark Step Running: extract_claims': 'mark-workflow-step.json',
  'Call: extract_claims': 'extract-research-claims.json',
  'Mark Step Failed: extract_claims': 'mark-workflow-step.json',
  'Fail Workflow Run: extract_claims': 'fail-workflow-run.json',
  'Mark Step Succeeded: extract_claims': 'mark-workflow-step.json',
  'Mark Step Running: build_package_and_qc': 'mark-workflow-step.json',
  'Call: build_package_and_qc': 'build-research-package-and-qc.json',
  'Mark Step Failed: build_package_and_qc': 'mark-workflow-step.json',
  'Fail Workflow Run: build_package_and_qc': 'fail-workflow-run.json',
  'Mark Step Succeeded: build_package_and_qc': 'mark-workflow-step.json',
  'Mark Step Running: create_research_approval': 'mark-workflow-step.json',
  'Call: create_research_approval': 'create-research-approval.json',
  'Mark Step Failed: create_research_approval': 'mark-workflow-step.json',
  'Fail Workflow Run: create_research_approval': 'fail-workflow-run.json',
  'Mark Step Succeeded: create_research_approval': 'mark-workflow-step.json',
  // Step 6 — "Resolve Research Approval" orchestrator + dev webhooks.
  'Resolve Research Approval SQL': 'resolve-research-approval.json',
  'Resume: Research Project': 'research-project.json',
  'Resolve Research Approval': 'resolve-research-approval-workflow.json',
  'Research Project': 'research-project.json',
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
  // Step 6 — research pipeline.
  'get-channel-prompt.json': 'Get Channel Prompt',
  'get-project-sources.json': 'Get Project Sources',
  'get-project-claims.json': 'Get Project Claims',
  'get-current-research-package.json': 'Get Current Research Package',
  'load-content-project-for-research.json': 'Load Content Project For Research',
  'research-budget-preflight.json': 'Research Budget Preflight',
  'upsert-research-plan.json': 'Upsert Research Plan',
  'collect-research-sources-sql.json': 'Collect Research Sources SQL',
  'create-research-claims-batch-sql.json': 'Create Research Claims Batch SQL',
  'verify-research-claims.json': 'Verify Research Claims',
  'build-research-package-sql.json': 'Build Research Package SQL',
  'research-quality-control.json': 'Research Quality Control',
  'create-research-approval.json': 'Create Research Approval',
  'resolve-research-approval.json': 'Resolve Research Approval SQL',
  'record-provider-usage-event.json': 'Record Provider Usage Event',
  'record-cost-event.json': 'Record Cost Event',
  'build-research-plan.json': 'Build Research Plan',
  'collect-research-sources.json': 'Collect Research Sources',
  'extract-research-claims.json': 'Extract Research Claims',
  'build-research-package-and-qc.json': 'Build Research Package And QC',
  'research-project.json': 'Research Project',
  'resolve-research-approval-workflow.json': 'Resolve Research Approval',
};

main().catch((err) => {
  console.error('Import failed:', err.message);
  process.exit(1);
});
