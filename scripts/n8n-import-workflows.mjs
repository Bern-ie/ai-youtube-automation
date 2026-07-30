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
  // Step 7 — script pipeline. Leaf SQL wrappers first (get-channel-prompt.json
  // is reused from Step 6), then the composite provider-calling
  // sub-workflows, then the self-contained retry loop, the orchestrator,
  // and everything that references it.
  'load-approved-research-for-script.json',
  'script-budget-preflight.json',
  'create-script-version.json',
  'get-current-script-version.json',
  'script-deterministic-qc.json',
  'script-quality-control.json',
  'create-script-approval.json',
  'resolve-script-approval.json',
  'get-script-approval-package.json',
  'get-flattened-script-narration.json',
  'generate-script.json',
  'revise-script.json',
  'review-script.json',
  'generate-review-and-revise-script.json',
  'script-project.json',
  'resolve-script-approval-workflow.json',
  'step7-script-project-test.json',
  'dev-list-pending-script-approvals.json',
  'dev-get-script-approval-package.json',
  'dev-decide-script-approval.json',
  // Step 8 — voiceover pipeline. Leaf SQL wrappers first, then the
  // composite provider-calling sub-workflows (generate-all-voiceover-chunks.json
  // calls itself -- see the self-reference handling in main() below --
  // so it only needs its own prerequisites imported first, not itself),
  // then the orchestrator and everything that references it.
  'load-approved-script-for-voiceover.json',
  'voiceover-budget-preflight.json',
  'get-or-create-voiceover.json',
  'prepare-voiceover-chunks-sql.json',
  'claim-next-pending-voiceover-chunk.json',
  'persist-voiceover-chunk-success.json',
  'mark-voiceover-chunk-failed.json',
  'get-voiceover-chunk-generation-summary.json',
  'get-completed-voiceover-chunks-in-order.json',
  'record-assembled-voiceover.json',
  'set-voiceover-subtitle-paths.json',
  'voiceover-quality-control-sql.json',
  'create-voiceover-approval.json',
  'resolve-voiceover-approval.json',
  'get-voiceover-approval-package.json',
  'get-current-voiceover.json',
  'prepare-voiceover-chunks.json',
  'generate-voiceover-chunk.json',
  'generate-all-voiceover-chunks.json',
  'assemble-voiceover.json',
  'voiceover-project.json',
  'resolve-voiceover-approval-workflow.json',
  'step8-voiceover-project-test.json',
  'dev-list-pending-voiceover-approvals.json',
  'dev-get-voiceover-approval-package.json',
  'dev-decide-voiceover-approval.json',
  // Step 9 — visual asset pipeline. Leaf SQL wrappers first, then the
  // composite provider-calling sub-workflows (generate-all-visual-shots.json
  // and resolve-visual-requirement.json each call themselves -- see the
  // self-reference handling in main() -- so they only need their own
  // prerequisites imported first, not themselves), then the orchestrator
  // and everything that references it.
  'load-visual-inputs.json',
  'visual-budget-preflight.json',
  'get-or-create-visual-shot-list.json',
  'persist-generated-shots.json',
  'claim-next-pending-visual-shot.json',
  'find-reusable-asset.json',
  'persist-resolved-asset.json',
  'mark-visual-shot-failed.json',
  'get-visual-shot-resolution-summary.json',
  'get-resolved-shots-in-order.json',
  'finalize-asset-assignments.json',
  'visual-quality-control-sql.json',
  'create-visual-approval.json',
  'resolve-visual-approval.json',
  'get-visual-approval-package.json',
  'list-pending-visual-approvals.json',
  'get-current-visual-shot-list.json',
  'create-visual-revision.json',
  'generate-shot-list.json',
  'search-stock-media.json',
  'generate-image-asset.json',
  'resolve-visual-requirement.json',
  'generate-all-visual-shots.json',
  'visual-project.json',
  'resolve-visual-approval-workflow.json',
  'step9-visual-project-test.json',
  'dev-list-pending-visual-approvals.json',
  'dev-get-visual-approval-package.json',
  'dev-decide-visual-approval.json',
  // Step 10 — video render pipeline. Leaf SQL wrappers first, then the
  // composite HTTP-calling sub-workflows (render-and-validate.json calls
  // submit-render-job.json and poll-render-job.json; poll-render-job.json
  // calls itself -- see the self-reference handling in main() -- so it
  // only needs its own prerequisites imported first, not itself), then
  // the orchestrator and everything that references it. Rendering makes
  // zero external API calls (local FFmpeg only), so there is no new
  // provider/credential config to wire up here.
  'load-render-inputs.json',
  'render-budget-preflight.json',
  'build-scene-manifest.json',
  'validate-scene-manifest.json',
  'get-current-scene-manifest.json',
  'get-or-create-render-job.json',
  'update-render-job-progress.json',
  'persist-render-job-success.json',
  'mark-render-job-failed.json',
  'render-quality-control-sql.json',
  'create-final-video-approval.json',
  'resolve-final-video-approval.json',
  'get-final-video-approval-package.json',
  'list-pending-final-video-approvals.json',
  'get-current-final-video.json',
  'create-render-revision.json',
  'invalidate-stale-render.json',
  'submit-render-job.json',
  'poll-render-job.json',
  'render-and-validate.json',
  'video-render-project.json',
  'resolve-final-video-approval-workflow.json',
  'step10-render-project-test.json',
  'dev-list-pending-final-video-approvals.json',
  'dev-get-final-video-approval-package.json',
  'dev-decide-final-video-approval.json',
  // Step 11 — publication package pipeline (thumbnails, YouTube metadata,
  // chapters, attribution). Leaf SQL wrappers first, then the composite
  // LLM/renderer-calling sub-workflows (render-thumbnail-variants.json
  // calls itself -- see the self-reference handling in main() -- so it
  // only needs its own prerequisites imported first, not itself), then
  // the orchestrator and everything that references it.
  'load-publication-inputs.json',
  'publication-budget-preflight.json',
  'get-or-create-publication-package.json',
  'persist-thumbnail-concepts.json',
  'claim-next-pending-thumbnail-concept.json',
  'get-or-create-thumbnail.json',
  'persist-thumbnail-success.json',
  'mark-thumbnail-failed.json',
  'get-publication-batch-status.json',
  'persist-metadata-variants.json',
  'record-metadata-grounding-result.json',
  'score-title-thumbnail-pairs-sql.json',
  'validate-publication-package.json',
  'create-publication-approval.json',
  'resolve-publication-approval.json',
  'get-publication-approval-package.json',
  'list-pending-publication-approvals.json',
  'get-current-publication-package.json',
  'create-publication-revision.json',
  'invalidate-stale-publication-package.json',
  'generate-thumbnail-concepts.json',
  'render-thumbnail-variants.json',
  'generate-metadata.json',
  'score-title-thumbnail-pairs.json',
  'publication-package-project.json',
  'resolve-publication-approval-workflow.json',
  'step11-publication-project-test.json',
  'dev-list-pending-publication-approvals.json',
  'dev-get-publication-approval-package.json',
  'dev-decide-publication-approval.json',
  // Step 12 -- YouTube publication pipeline. Leaf SQL wrappers first, then
  // the HTTP-calling composites (upload-video-chunks.json calls itself --
  // see the self-reference handling in main() -- so it only needs its own
  // prerequisites imported first, not itself), then the orchestrator and
  // everything that references it.
  'load-publication-upload-inputs.json',
  'resolve-youtube-credential.json',
  'compute-final-video-checksum.json',
  'youtube-publication-preflight.json',
  'get-existing-upload-by-identity.json',
  'get-or-create-publication-record.json',
  'youtube-quota-preflight.json',
  'resume-publication-state.json',
  'mark-upload-initialized.json',
  'initialize-youtube-upload.json',
  'update-upload-progress.json',
  'record-youtube-video-id.json',
  'upload-video-chunks.json',
  'mark-metadata-applied.json',
  'apply-youtube-metadata.json',
  'mark-thumbnail-applied.json',
  'upload-youtube-thumbnail.json',
  'mark-captions-applied.json',
  'upload-youtube-captions.json',
  'mark-playlist-applied.json',
  'assign-youtube-playlist.json',
  'poll-youtube-processing.json',
  'mark-scheduled.json',
  'mark-publication-complete.json',
  'mark-publication-failed.json',
  'resolve-publishing-failure.json',
  'create-public-publish-confirmation.json',
  'get-public-publish-confirmation-package.json',
  'list-pending-public-publish-confirmations.json',
  'resolve-public-publish-confirmation.json',
  'get-current-published-video.json',
  'youtube-publish-project.json',
  'step12-youtube-publish-project-test.json',
  'dev-list-pending-public-publish-confirmations.json',
  'dev-get-public-publish-confirmation-package.json',
  'dev-decide-public-publish-confirmation.json',
];

// n8n paginates list endpoints (a cursor-based `nextCursor` field, default
// page size 100) -- fetching only the first page silently truncates the
// result once the instance has more than ~100 workflows. That truncation
// previously caused workflowIdByName lookups to miss already-existing
// workflows past the first page, which made the importer treat them as
// new and POST-create name-duplicate workflows instead of PUT-updating
// the real one (surfaced as a 409 webhook-path conflict once a duplicate
// with an active webhook-triggered name collided with the original on
// activation -- see the Step 10 completion notes). Every list call must
// page through to exhaustion.
async function apiPaginated(path) {
  let all = [];
  let cursor;
  for (;;) {
    const qs = cursor ? `${path.includes('?') ? '&' : '?'}cursor=${encodeURIComponent(cursor)}` : '';
    const page = await api(`${path}${qs}`);
    all = all.concat(page.data);
    cursor = page.nextCursor;
    if (!cursor) break;
  }
  return all;
}

async function main() {
  console.log(`Importing into ${N8N_URL}...`);

  const credentials = await apiPaginated('/credentials');
  const credentialIdByName = Object.fromEntries(credentials.map((c) => [c.name, c.id]));

  const existingWorkflows = await apiPaginated('/workflows');
  const workflowIdByName = Object.fromEntries(existingWorkflows.map((w) => [w.name, w.id]));

  const workflowsDir = join(REPO_ROOT, 'n8n', 'workflows');
  const available = new Set(readdirSync(workflowsDir).filter((f) => f.endsWith('.json')));

  for (const file of IMPORT_ORDER) {
    if (!available.has(file)) {
      console.warn(`skip: ${file} not found in n8n/workflows/`);
      continue;
    }
    const def = JSON.parse(readFileSync(join(workflowsDir, file), 'utf8'));

    // A workflow that calls itself (generate-all-voiceover-chunks.json's
    // bounded recursive claim-loop, see docs/architecture/voiceover-pipeline.md#chunk-generation-loop)
    // can't resolve its own ID on a first-ever creation -- it doesn't
    // exist yet. Those nodes are deferred and patched in a second PUT
    // once this workflow has an ID of its own. On every subsequent
    // re-import (an update, not a create) the ID is already known
    // up front — n8n validates sub-workflow references at save time,
    // not just at activation, so on updates the self-reference must be
    // resolved in this same first pass or the PUT itself is rejected.
    const knownWorkflowId = workflowIdByName[def.name];
    const selfRefNodes = [];

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
          if (sourceFile === file) {
            if (knownWorkflowId) {
              node.parameters.workflowId.value = knownWorkflowId;
            } else {
              selfRefNodes.push(node);
            }
            continue;
          }
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

    if (selfRefNodes.length > 0) {
      for (const node of selfRefNodes) node.parameters.workflowId.value = workflowId;
      await api(`/workflows/${workflowId}`, { method: 'PUT', body: JSON.stringify(payload) });
      console.log(`patched self-reference: ${def.name}`);
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
  // Step 7 — script pipeline. "Get Channel Prompt", "Record Usage: Input
  // Tokens", "Record Usage: Output Tokens", "Record Cost Event" reuse the
  // Step 6 entries above (same target files).
  'Create Script Version': 'create-script-version.json',
  'Script Deterministic QC': 'script-deterministic-qc.json',
  'Script Quality Control': 'script-quality-control.json',
  'Generate Script': 'generate-script.json',
  'Review Script (initial)': 'review-script.json',
  'Revise Script (retry_1)': 'revise-script.json',
  'Review Script (retry_1)': 'review-script.json',
  'Revise Script (retry_2)': 'revise-script.json',
  'Review Script (retry_2)': 'review-script.json',
  'Revise Script (retry_3)': 'revise-script.json',
  'Review Script (retry_3)': 'review-script.json',
  // "Script Project" orchestrator (5 unrolled resumable steps, same
  // Mark Running/Call/Mark Failed/Fail Workflow Run/Mark Succeeded
  // cluster pattern as "Research Project"). "Mark Step Running/Failed/
  // Succeeded: load_channel_configuration", "Call: load_channel_configuration",
  // and "Fail Workflow Run: load_channel_configuration" reuse the Step 6
  // entries above.
  'Mark Step Running: load_approved_research': 'mark-workflow-step.json',
  'Call: load_approved_research': 'load-approved-research-for-script.json',
  'Mark Step Failed: load_approved_research': 'mark-workflow-step.json',
  'Fail Workflow Run: load_approved_research': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_approved_research': 'mark-workflow-step.json',
  'Mark Step Running: script_budget_preflight': 'mark-workflow-step.json',
  'Call: script_budget_preflight': 'script-budget-preflight.json',
  'Mark Step Failed: script_budget_preflight': 'mark-workflow-step.json',
  'Fail Workflow Run: script_budget_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: script_budget_preflight': 'mark-workflow-step.json',
  'Mark Step Running: generate_review_and_revise_script': 'mark-workflow-step.json',
  'Call: generate_review_and_revise_script': 'generate-review-and-revise-script.json',
  'Mark Step Failed: generate_review_and_revise_script': 'mark-workflow-step.json',
  'Fail Workflow Run: generate_review_and_revise_script': 'fail-workflow-run.json',
  'Mark Step Succeeded: generate_review_and_revise_script': 'mark-workflow-step.json',
  'Mark Step Running: create_script_approval': 'mark-workflow-step.json',
  'Call: create_script_approval': 'create-script-approval.json',
  'Mark Step Failed: create_script_approval': 'mark-workflow-step.json',
  'Fail Workflow Run: create_script_approval': 'fail-workflow-run.json',
  'Mark Step Succeeded: create_script_approval': 'mark-workflow-step.json',
  // Step 7 — "Resolve Script Approval" orchestrator + dev webhooks.
  'Resolve Script Approval SQL': 'resolve-script-approval.json',
  'Resume: Script Project': 'script-project.json',
  'Resolve Script Approval': 'resolve-script-approval-workflow.json',
  'Script Project': 'script-project.json',
  // Step 8 — voiceover pipeline. "Prepare Voiceover Chunks" composite.
  'Get Or Create Voiceover': 'get-or-create-voiceover.json',
  'Prepare Voiceover Chunks SQL': 'prepare-voiceover-chunks-sql.json',
  // "Generate Voiceover Chunk" composite.
  'Mark Voiceover Chunk Failed (TTS)': 'mark-voiceover-chunk-failed.json',
  'Mark Voiceover Chunk Failed (Invalid)': 'mark-voiceover-chunk-failed.json',
  'Record Usage: Characters': 'record-provider-usage-event.json',
  'Persist Voiceover Chunk Success': 'persist-voiceover-chunk-success.json',
  // "Generate All Voiceover Chunks" composite -- the last entry is a
  // genuine self-reference, resolved by the two-pass patch in main().
  'Claim Next Pending Voiceover Chunk': 'claim-next-pending-voiceover-chunk.json',
  'Get Voiceover Chunk Generation Summary': 'get-voiceover-chunk-generation-summary.json',
  'Generate Voiceover Chunk': 'generate-voiceover-chunk.json',
  'Generate All Voiceover Chunks (Recurse)': 'generate-all-voiceover-chunks.json',
  // "Assemble Voiceover" composite.
  'Get Completed Voiceover Chunks In Order': 'get-completed-voiceover-chunks-in-order.json',
  'Record Assembled Voiceover': 'record-assembled-voiceover.json',
  'Set Voiceover Subtitle Paths': 'set-voiceover-subtitle-paths.json',
  // "Voiceover Project" orchestrator (7 unrolled resumable steps plus a
  // manually-wired voiceover_quality_control/create_voiceover_approval
  // tail, same Mark Running/Call/Mark Failed/Fail Workflow Run/Mark
  // Succeeded cluster pattern as "Research Project"/"Script Project").
  // "Mark Step Running/Failed/Succeeded: load_channel_configuration",
  // "Call: load_channel_configuration", and "Fail Workflow Run:
  // load_channel_configuration" reuse the Step 6 entries above.
  'Mark Step Running: load_approved_script': 'mark-workflow-step.json',
  'Call: load_approved_script': 'load-approved-script-for-voiceover.json',
  'Mark Step Failed: load_approved_script': 'mark-workflow-step.json',
  'Fail Workflow Run: load_approved_script': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_approved_script': 'mark-workflow-step.json',
  'Mark Step Running: voiceover_budget_preflight': 'mark-workflow-step.json',
  'Call: voiceover_budget_preflight': 'voiceover-budget-preflight.json',
  'Mark Step Failed: voiceover_budget_preflight': 'mark-workflow-step.json',
  'Fail Workflow Run: voiceover_budget_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: voiceover_budget_preflight': 'mark-workflow-step.json',
  'Mark Step Running: prepare_voiceover_chunks': 'mark-workflow-step.json',
  'Call: prepare_voiceover_chunks': 'prepare-voiceover-chunks.json',
  'Mark Step Failed: prepare_voiceover_chunks': 'mark-workflow-step.json',
  'Fail Workflow Run: prepare_voiceover_chunks': 'fail-workflow-run.json',
  'Mark Step Succeeded: prepare_voiceover_chunks': 'mark-workflow-step.json',
  'Mark Step Running: generate_voiceover_chunks': 'mark-workflow-step.json',
  'Call: generate_voiceover_chunks': 'generate-all-voiceover-chunks.json',
  'Mark Step Failed: generate_voiceover_chunks': 'mark-workflow-step.json',
  'Fail Workflow Run: generate_voiceover_chunks': 'fail-workflow-run.json',
  'Mark Step Succeeded: generate_voiceover_chunks': 'mark-workflow-step.json',
  'Mark Step Running: assemble_voiceover': 'mark-workflow-step.json',
  'Call: assemble_voiceover': 'assemble-voiceover.json',
  'Mark Step Failed: assemble_voiceover': 'mark-workflow-step.json',
  'Fail Workflow Run: assemble_voiceover': 'fail-workflow-run.json',
  'Mark Step Succeeded: assemble_voiceover': 'mark-workflow-step.json',
  'Mark Step Running: voiceover_quality_control': 'mark-workflow-step.json',
  'Call: voiceover_quality_control': 'voiceover-quality-control-sql.json',
  'Mark Step Failed: voiceover_quality_control': 'mark-workflow-step.json',
  'Fail Workflow Run: voiceover_quality_control': 'fail-workflow-run.json',
  'Mark Step Succeeded: voiceover_quality_control': 'mark-workflow-step.json',
  'Mark Step Running: create_voiceover_approval': 'mark-workflow-step.json',
  'Call: create_voiceover_approval': 'create-voiceover-approval.json',
  'Mark Step Failed: create_voiceover_approval': 'mark-workflow-step.json',
  'Fail Workflow Run: create_voiceover_approval': 'fail-workflow-run.json',
  'Mark Step Succeeded: create_voiceover_approval': 'mark-workflow-step.json',
  // Step 8 — "Resolve Voiceover Approval" orchestrator + dev webhooks.
  'Resolve Voiceover Approval SQL': 'resolve-voiceover-approval.json',
  'Resume: Voiceover Project': 'voiceover-project.json',
  'Resolve Voiceover Approval': 'resolve-voiceover-approval-workflow.json',
  'Voiceover Project': 'voiceover-project.json',
  // Step 9 — visual asset pipeline. "Mark Step Running/Failed/Succeeded:
  // load_channel_configuration", "Call: load_channel_configuration", and
  // "Fail Workflow Run: load_channel_configuration" reuse the Step 6
  // entries above (same node names, same target files). "Get Channel
  // Prompt", "Record Usage: Input/Output Tokens", and "Record Cost Event"
  // reuse the Step 6 entries too.
  'Mark Step Running: load_visual_inputs': 'mark-workflow-step.json',
  'Call: load_visual_inputs': 'load-visual-inputs.json',
  'Mark Step Failed: load_visual_inputs': 'mark-workflow-step.json',
  'Fail Workflow Run: load_visual_inputs': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_visual_inputs': 'mark-workflow-step.json',
  'Mark Step Running: visual_budget_preflight': 'mark-workflow-step.json',
  'Call: visual_budget_preflight': 'visual-budget-preflight.json',
  'Mark Step Failed: visual_budget_preflight': 'mark-workflow-step.json',
  'Fail Workflow Run: visual_budget_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: visual_budget_preflight': 'mark-workflow-step.json',
  'Mark Step Running: get_or_create_visual_shot_list': 'mark-workflow-step.json',
  'Call: get_or_create_visual_shot_list': 'get-or-create-visual-shot-list.json',
  'Mark Step Failed: get_or_create_visual_shot_list': 'mark-workflow-step.json',
  'Fail Workflow Run: get_or_create_visual_shot_list': 'fail-workflow-run.json',
  'Mark Step Succeeded: get_or_create_visual_shot_list': 'mark-workflow-step.json',
  'Mark Step Running: generate_shot_list': 'mark-workflow-step.json',
  'Call: generate_shot_list': 'generate-shot-list.json',
  'Mark Step Failed: generate_shot_list': 'mark-workflow-step.json',
  'Fail Workflow Run: generate_shot_list': 'fail-workflow-run.json',
  'Mark Step Succeeded: generate_shot_list': 'mark-workflow-step.json',
  'Mark Step Running: generate_all_visual_shots': 'mark-workflow-step.json',
  'Call: generate_all_visual_shots': 'generate-all-visual-shots.json',
  'Mark Step Failed: generate_all_visual_shots': 'mark-workflow-step.json',
  'Fail Workflow Run: generate_all_visual_shots': 'fail-workflow-run.json',
  'Mark Step Succeeded: generate_all_visual_shots': 'mark-workflow-step.json',
  'Mark Step Running: finalize_asset_assignments': 'mark-workflow-step.json',
  'Call: finalize_asset_assignments': 'finalize-asset-assignments.json',
  'Mark Step Failed: finalize_asset_assignments': 'mark-workflow-step.json',
  'Fail Workflow Run: finalize_asset_assignments': 'fail-workflow-run.json',
  'Mark Step Succeeded: finalize_asset_assignments': 'mark-workflow-step.json',
  'Mark Step Running: visual_quality_control': 'mark-workflow-step.json',
  'Call: visual_quality_control': 'visual-quality-control-sql.json',
  'Mark Step Failed: visual_quality_control': 'mark-workflow-step.json',
  'Fail Workflow Run: visual_quality_control': 'fail-workflow-run.json',
  'Mark Step Succeeded: visual_quality_control': 'mark-workflow-step.json',
  'Mark Step Running: create_visual_approval': 'mark-workflow-step.json',
  'Call: create_visual_approval': 'create-visual-approval.json',
  'Mark Step Failed: create_visual_approval': 'mark-workflow-step.json',
  'Fail Workflow Run: create_visual_approval': 'fail-workflow-run.json',
  'Mark Step Succeeded: create_visual_approval': 'mark-workflow-step.json',
  // "Generate Shot List" composite.
  'Persist Generated Shots': 'persist-generated-shots.json',
  // "Resolve Visual Requirement" composite -- the four "(Recurse: ...)"
  // nodes are genuine self-references, resolved by the two-pass patch in
  // main().
  'Mark Visual Shot Failed (Exhausted)': 'mark-visual-shot-failed.json',
  'Find Reusable Asset': 'find-reusable-asset.json',
  'Persist Resolved Asset (Reuse)': 'persist-resolved-asset.json',
  'Search Stock Media': 'search-stock-media.json',
  'Persist Resolved Asset (Stock)': 'persist-resolved-asset.json',
  'Generate Image Asset': 'generate-image-asset.json',
  'Persist Resolved Asset (Generated)': 'persist-resolved-asset.json',
  'Persist Resolved Asset (Spec-Only)': 'persist-resolved-asset.json',
  'Resolve Visual Requirement (Recurse: Stock)': 'resolve-visual-requirement.json',
  'Resolve Visual Requirement (Recurse: Stock No Candidate)': 'resolve-visual-requirement.json',
  'Resolve Visual Requirement (Recurse: Image Gen Failed)': 'resolve-visual-requirement.json',
  'Resolve Visual Requirement (Recurse: Image Invalid)': 'resolve-visual-requirement.json',
  // "Generate All Visual Shots" composite -- the last entry is a genuine
  // self-reference, resolved by the two-pass patch in main().
  'Claim Next Pending Visual Shot': 'claim-next-pending-visual-shot.json',
  'Get Visual Shot Resolution Summary': 'get-visual-shot-resolution-summary.json',
  'Resolve Visual Requirement': 'resolve-visual-requirement.json',
  'Generate All Visual Shots (Recurse)': 'generate-all-visual-shots.json',
  // "Visual Project" orchestrator.
  'Visual Project': 'visual-project.json',
  // "Resolve Visual Approval" orchestrator + dev webhooks.
  'Resolve Visual Approval SQL': 'resolve-visual-approval.json',
  'Initialize Revision Workflow Run': 'initialize-workflow-run.json',
  'Create Visual Revision': 'create-visual-revision.json',
  'Resume: Visual Project': 'visual-project.json',
  'Resolve Visual Approval': 'resolve-visual-approval-workflow.json',
  // Step 10 — video render pipeline. "Mark Step Running/Failed/Succeeded:
  // load_channel_configuration", "Call: load_channel_configuration", and
  // "Fail Workflow Run: load_channel_configuration" reuse the Step 6
  // entries above (same node names, same target files).
  'Mark Step Running: load_render_inputs': 'mark-workflow-step.json',
  'Call: load_render_inputs': 'load-render-inputs.json',
  'Mark Step Failed: load_render_inputs': 'mark-workflow-step.json',
  'Fail Workflow Run: load_render_inputs': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_render_inputs': 'mark-workflow-step.json',
  'Mark Step Running: render_budget_preflight': 'mark-workflow-step.json',
  'Call: render_budget_preflight': 'render-budget-preflight.json',
  'Mark Step Failed: render_budget_preflight': 'mark-workflow-step.json',
  'Fail Workflow Run: render_budget_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: render_budget_preflight': 'mark-workflow-step.json',
  'Mark Step Running: build_scene_manifest': 'mark-workflow-step.json',
  'Call: build_scene_manifest': 'build-scene-manifest.json',
  'Mark Step Failed: build_scene_manifest': 'mark-workflow-step.json',
  'Fail Workflow Run: build_scene_manifest': 'fail-workflow-run.json',
  'Mark Step Succeeded: build_scene_manifest': 'mark-workflow-step.json',
  'Mark Step Running: validate_scene_manifest': 'mark-workflow-step.json',
  'Call: validate_scene_manifest': 'validate-scene-manifest.json',
  'Mark Step Failed: validate_scene_manifest': 'mark-workflow-step.json',
  'Fail Workflow Run: validate_scene_manifest': 'fail-workflow-run.json',
  'Mark Step Succeeded: validate_scene_manifest': 'mark-workflow-step.json',
  'Mark Step Running: render_preview': 'mark-workflow-step.json',
  'Call: render_preview': 'render-and-validate.json',
  'Mark Step Failed: render_preview': 'mark-workflow-step.json',
  'Fail Workflow Run: render_preview': 'fail-workflow-run.json',
  'Mark Step Succeeded: render_preview': 'mark-workflow-step.json',
  'Mark Step Running: render_final': 'mark-workflow-step.json',
  'Call: render_final': 'render-and-validate.json',
  'Mark Step Failed: render_final': 'mark-workflow-step.json',
  'Fail Workflow Run: render_final': 'fail-workflow-run.json',
  'Mark Step Succeeded: render_final': 'mark-workflow-step.json',
  'Mark Step Running: create_final_video_approval': 'mark-workflow-step.json',
  'Call: create_final_video_approval': 'create-final-video-approval.json',
  'Mark Step Failed: create_final_video_approval': 'mark-workflow-step.json',
  'Fail Workflow Run: create_final_video_approval': 'fail-workflow-run.json',
  'Mark Step Succeeded: create_final_video_approval': 'mark-workflow-step.json',
  // "Submit Render Job" composite.
  'Call: Get Or Create Render Job': 'get-or-create-render-job.json',
  'Call: Get Current Scene Manifest': 'get-current-scene-manifest.json',
  // "Poll Render Job" composite -- the last entry is a genuine
  // self-reference, resolved by the two-pass patch in main().
  'Call: Mark Render Job Failed (Timeout)': 'mark-render-job-failed.json',
  'Call: Update Render Job Progress': 'update-render-job-progress.json',
  'Call: Persist Render Job Success': 'persist-render-job-success.json',
  'Call: Mark Render Job Failed (Job Failure)': 'mark-render-job-failed.json',
  'Poll Render Job (Recurse)': 'poll-render-job.json',
  // "Render And Validate" composite (shared by both "Call: render_preview"
  // and "Call: render_final" above).
  'Call: Submit Render Job': 'submit-render-job.json',
  'Call: Poll Render Job': 'poll-render-job.json',
  'Call: Render Quality Control SQL': 'render-quality-control-sql.json',
  // "Video Render Project" orchestrator.
  'Video Render Project': 'video-render-project.json',
  // "Resolve Final Video Approval" orchestrator + dev webhooks.
  'Resolve Final Video Approval SQL': 'resolve-final-video-approval.json',
  'Create Render Revision': 'create-render-revision.json',
  'Resume: Video Render Project': 'video-render-project.json',
  'Resolve Final Video Approval': 'resolve-final-video-approval-workflow.json',
  // Step 11 — publication package pipeline. "Get Channel Prompt",
  // "Record Usage: Input/Output Tokens", "Record Cost Event",
  // "Initialize Workflow Run"/"Initialize Revision Workflow Run",
  // "Get Workflow Run Steps", and "Generate Image Asset" reuse the
  // earlier steps' entries above (same node names, same target files).
  'Persist Thumbnail Concepts': 'persist-thumbnail-concepts.json',
  'Claim Next Pending Thumbnail Concept': 'claim-next-pending-thumbnail-concept.json',
  'Get Publication Batch Status': 'get-publication-batch-status.json',
  'Get Or Create Thumbnail': 'get-or-create-thumbnail.json',
  'Persist Thumbnail Success': 'persist-thumbnail-success.json',
  'Mark Thumbnail Failed': 'mark-thumbnail-failed.json',
  'Render Thumbnail Variants (Recurse)': 'render-thumbnail-variants.json',
  'Get Current Research Package': 'get-current-research-package.json',
  'Persist Metadata Variants': 'persist-metadata-variants.json',
  'Score Title Thumbnail Pairs SQL': 'score-title-thumbnail-pairs-sql.json',
  // "Publication Package Project" orchestrator -- 10 unrolled steps, each
  // with its own Mark Running / Call / Mark Failed / Fail Workflow Run /
  // Mark Succeeded cluster, same pattern as every other step's orchestrator.
  'Mark Step Running: load_channel_configuration': 'mark-workflow-step.json',
  'Call: load_channel_configuration': 'load-channel-configuration.json',
  'Mark Step Failed: load_channel_configuration': 'mark-workflow-step.json',
  'Fail Workflow Run: load_channel_configuration': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_channel_configuration': 'mark-workflow-step.json',
  'Mark Step Running: load_publication_inputs': 'mark-workflow-step.json',
  'Call: load_publication_inputs': 'load-publication-inputs.json',
  'Mark Step Failed: load_publication_inputs': 'mark-workflow-step.json',
  'Fail Workflow Run: load_publication_inputs': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_publication_inputs': 'mark-workflow-step.json',
  'Mark Step Running: publication_budget_preflight': 'mark-workflow-step.json',
  'Call: publication_budget_preflight': 'publication-budget-preflight.json',
  'Mark Step Failed: publication_budget_preflight': 'mark-workflow-step.json',
  'Fail Workflow Run: publication_budget_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: publication_budget_preflight': 'mark-workflow-step.json',
  'Mark Step Running: get_or_create_publication_package': 'mark-workflow-step.json',
  'Call: get_or_create_publication_package': 'get-or-create-publication-package.json',
  'Mark Step Failed: get_or_create_publication_package': 'mark-workflow-step.json',
  'Fail Workflow Run: get_or_create_publication_package': 'fail-workflow-run.json',
  'Mark Step Succeeded: get_or_create_publication_package': 'mark-workflow-step.json',
  'Mark Step Running: generate_thumbnail_concepts': 'mark-workflow-step.json',
  'Call: generate_thumbnail_concepts': 'generate-thumbnail-concepts.json',
  'Mark Step Failed: generate_thumbnail_concepts': 'mark-workflow-step.json',
  'Fail Workflow Run: generate_thumbnail_concepts': 'fail-workflow-run.json',
  'Mark Step Succeeded: generate_thumbnail_concepts': 'mark-workflow-step.json',
  'Mark Step Running: render_thumbnail_variants': 'mark-workflow-step.json',
  'Call: render_thumbnail_variants': 'render-thumbnail-variants.json',
  'Mark Step Failed: render_thumbnail_variants': 'mark-workflow-step.json',
  'Fail Workflow Run: render_thumbnail_variants': 'fail-workflow-run.json',
  'Mark Step Succeeded: render_thumbnail_variants': 'mark-workflow-step.json',
  'Mark Step Running: generate_metadata': 'mark-workflow-step.json',
  'Call: generate_metadata': 'generate-metadata.json',
  'Mark Step Failed: generate_metadata': 'mark-workflow-step.json',
  'Fail Workflow Run: generate_metadata': 'fail-workflow-run.json',
  'Mark Step Succeeded: generate_metadata': 'mark-workflow-step.json',
  'Mark Step Running: score_title_thumbnail_pairs': 'mark-workflow-step.json',
  'Call: score_title_thumbnail_pairs': 'score-title-thumbnail-pairs.json',
  'Mark Step Failed: score_title_thumbnail_pairs': 'mark-workflow-step.json',
  'Fail Workflow Run: score_title_thumbnail_pairs': 'fail-workflow-run.json',
  'Mark Step Succeeded: score_title_thumbnail_pairs': 'mark-workflow-step.json',
  'Mark Step Running: validate_publication_package': 'mark-workflow-step.json',
  'Call: validate_publication_package': 'validate-publication-package.json',
  'Mark Step Failed: validate_publication_package': 'mark-workflow-step.json',
  'Fail Workflow Run: validate_publication_package': 'fail-workflow-run.json',
  'Mark Step Succeeded: validate_publication_package': 'mark-workflow-step.json',
  'Mark Step Running: create_publication_approval': 'mark-workflow-step.json',
  'Call: create_publication_approval': 'create-publication-approval.json',
  'Mark Step Failed: create_publication_approval': 'mark-workflow-step.json',
  'Fail Workflow Run: create_publication_approval': 'fail-workflow-run.json',
  'Mark Step Succeeded: create_publication_approval': 'mark-workflow-step.json',
  // "Resolve Publication Approval" orchestrator + dev webhooks.
  'Resolve Publication Approval SQL': 'resolve-publication-approval.json',
  'Create Publication Revision': 'create-publication-revision.json',
  'Resume: Publication Package Project': 'publication-package-project.json',
  'Publication Package Project': 'publication-package-project.json',
  'Resolve Publication Approval': 'resolve-publication-approval-workflow.json',
  // Step 12 -- YouTube publication pipeline orchestrator ("YouTube
  // Publish Project") -- 17 unrolled resumable steps, same Mark
  // Running/Call/Mark Failed/Resolve Publishing Failure/Fail Workflow
  // Run/Mark Succeeded cluster pattern as every other orchestrator, plus
  // the composite HTTP-calling sub-workflows' own internal DB-wrapper
  // calls (upload-video-chunks.json's chunk-loop self-reference is
  // resolved by the two-pass patch in main(), same as poll-render-job.json).
  'Mark Step Running: load_publication_package': 'mark-workflow-step.json',
  'Call: load_publication_package': 'load-publication-upload-inputs.json',
  'Mark Step Failed: load_publication_package': 'mark-workflow-step.json',
  'Resolve Publishing Failure: load_publication_package': 'resolve-publishing-failure.json',
  'Fail Workflow Run: load_publication_package': 'fail-workflow-run.json',
  'Mark Step Succeeded: load_publication_package': 'mark-workflow-step.json',
  'Mark Step Running: resolve_youtube_credential': 'mark-workflow-step.json',
  'Call: resolve_youtube_credential': 'resolve-youtube-credential.json',
  'Mark Step Failed: resolve_youtube_credential': 'mark-workflow-step.json',
  'Resolve Publishing Failure: resolve_youtube_credential': 'resolve-publishing-failure.json',
  'Fail Workflow Run: resolve_youtube_credential': 'fail-workflow-run.json',
  'Mark Step Succeeded: resolve_youtube_credential': 'mark-workflow-step.json',
  'Mark Step Running: verify_final_video_checksum': 'mark-workflow-step.json',
  'Call: verify_final_video_checksum': 'compute-final-video-checksum.json',
  'Mark Step Failed: verify_final_video_checksum': 'mark-workflow-step.json',
  'Resolve Publishing Failure: verify_final_video_checksum': 'resolve-publishing-failure.json',
  'Fail Workflow Run: verify_final_video_checksum': 'fail-workflow-run.json',
  'Mark Step Succeeded: verify_final_video_checksum': 'mark-workflow-step.json',
  'Mark Step Running: publication_preflight': 'mark-workflow-step.json',
  'Call: publication_preflight': 'youtube-publication-preflight.json',
  'Mark Step Failed: publication_preflight': 'mark-workflow-step.json',
  'Resolve Publishing Failure: publication_preflight': 'resolve-publishing-failure.json',
  'Fail Workflow Run: publication_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: publication_preflight': 'mark-workflow-step.json',
  'Mark Step Running: get_or_create_publication_record': 'mark-workflow-step.json',
  'Call: get_or_create_publication_record': 'get-or-create-publication-record.json',
  'Mark Step Failed: get_or_create_publication_record': 'mark-workflow-step.json',
  'Resolve Publishing Failure: get_or_create_publication_record': 'resolve-publishing-failure.json',
  'Fail Workflow Run: get_or_create_publication_record': 'fail-workflow-run.json',
  'Mark Step Succeeded: get_or_create_publication_record': 'mark-workflow-step.json',
  'Mark Step Running: youtube_quota_preflight': 'mark-workflow-step.json',
  'Call: youtube_quota_preflight': 'youtube-quota-preflight.json',
  'Mark Step Failed: youtube_quota_preflight': 'mark-workflow-step.json',
  'Resolve Publishing Failure: youtube_quota_preflight': 'resolve-publishing-failure.json',
  'Fail Workflow Run: youtube_quota_preflight': 'fail-workflow-run.json',
  'Mark Step Succeeded: youtube_quota_preflight': 'mark-workflow-step.json',
  'Mark Step Running: resume_publication_state': 'mark-workflow-step.json',
  'Call: resume_publication_state': 'resume-publication-state.json',
  'Mark Step Failed: resume_publication_state': 'mark-workflow-step.json',
  'Resolve Publishing Failure: resume_publication_state': 'resolve-publishing-failure.json',
  'Fail Workflow Run: resume_publication_state': 'fail-workflow-run.json',
  'Mark Step Succeeded: resume_publication_state': 'mark-workflow-step.json',
  'Mark Step Running: initialize_resumable_upload': 'mark-workflow-step.json',
  'Call: initialize_resumable_upload': 'initialize-youtube-upload.json',
  'Mark Step Failed: initialize_resumable_upload': 'mark-workflow-step.json',
  'Resolve Publishing Failure: initialize_resumable_upload': 'resolve-publishing-failure.json',
  'Fail Workflow Run: initialize_resumable_upload': 'fail-workflow-run.json',
  'Mark Step Succeeded: initialize_resumable_upload': 'mark-workflow-step.json',
  'Mark Step Running: upload_video': 'mark-workflow-step.json',
  'Call: upload_video': 'upload-video-chunks.json',
  'Mark Step Failed: upload_video': 'mark-workflow-step.json',
  'Resolve Publishing Failure: upload_video': 'resolve-publishing-failure.json',
  'Fail Workflow Run: upload_video': 'fail-workflow-run.json',
  'Mark Step Succeeded: upload_video': 'mark-workflow-step.json',
  'Mark Step Running: apply_metadata': 'mark-workflow-step.json',
  'Call: apply_metadata': 'apply-youtube-metadata.json',
  'Mark Step Failed: apply_metadata': 'mark-workflow-step.json',
  'Resolve Publishing Failure: apply_metadata': 'resolve-publishing-failure.json',
  'Fail Workflow Run: apply_metadata': 'fail-workflow-run.json',
  'Mark Step Succeeded: apply_metadata': 'mark-workflow-step.json',
  'Mark Step Running: upload_thumbnail': 'mark-workflow-step.json',
  'Call: upload_thumbnail': 'upload-youtube-thumbnail.json',
  'Mark Step Failed: upload_thumbnail': 'mark-workflow-step.json',
  'Resolve Publishing Failure: upload_thumbnail': 'resolve-publishing-failure.json',
  'Fail Workflow Run: upload_thumbnail': 'fail-workflow-run.json',
  'Mark Step Succeeded: upload_thumbnail': 'mark-workflow-step.json',
  'Mark Step Running: upload_captions': 'mark-workflow-step.json',
  'Call: upload_captions': 'upload-youtube-captions.json',
  'Mark Step Failed: upload_captions': 'mark-workflow-step.json',
  'Resolve Publishing Failure: upload_captions': 'resolve-publishing-failure.json',
  'Fail Workflow Run: upload_captions': 'fail-workflow-run.json',
  'Mark Step Succeeded: upload_captions': 'mark-workflow-step.json',
  'Mark Step Running: assign_playlist': 'mark-workflow-step.json',
  'Call: assign_playlist': 'assign-youtube-playlist.json',
  'Mark Step Failed: assign_playlist': 'mark-workflow-step.json',
  'Resolve Publishing Failure: assign_playlist': 'resolve-publishing-failure.json',
  'Fail Workflow Run: assign_playlist': 'fail-workflow-run.json',
  'Mark Step Succeeded: assign_playlist': 'mark-workflow-step.json',
  'Mark Step Running: poll_processing': 'mark-workflow-step.json',
  'Call: poll_processing': 'poll-youtube-processing.json',
  'Mark Step Failed: poll_processing': 'mark-workflow-step.json',
  'Resolve Publishing Failure: poll_processing': 'resolve-publishing-failure.json',
  'Fail Workflow Run: poll_processing': 'fail-workflow-run.json',
  'Mark Step Succeeded: poll_processing': 'mark-workflow-step.json',
  'Mark Step Running: finalize_publication_record': 'mark-workflow-step.json',
  'Call: finalize_publication_record': 'mark-publication-complete.json',
  'Mark Step Failed: finalize_publication_record': 'mark-workflow-step.json',
  'Resolve Publishing Failure: finalize_publication_record': 'resolve-publishing-failure.json',
  'Fail Workflow Run: finalize_publication_record': 'fail-workflow-run.json',
  'Mark Step Succeeded: finalize_publication_record': 'mark-workflow-step.json',
  'Mark Step Running: mark_scheduled_if_requested': 'mark-workflow-step.json',
  'Call: mark_scheduled_if_requested': 'mark-scheduled.json',
  'Mark Step Failed: mark_scheduled_if_requested': 'mark-workflow-step.json',
  'Resolve Publishing Failure: mark_scheduled_if_requested': 'resolve-publishing-failure.json',
  'Fail Workflow Run: mark_scheduled_if_requested': 'fail-workflow-run.json',
  'Mark Step Succeeded: mark_scheduled_if_requested': 'mark-workflow-step.json',
  'Mark Step Running: create_public_publish_confirmation': 'mark-workflow-step.json',
  'Call: create_public_publish_confirmation': 'create-public-publish-confirmation.json',
  'Mark Step Failed: create_public_publish_confirmation': 'mark-workflow-step.json',
  'Resolve Publishing Failure: create_public_publish_confirmation': 'resolve-publishing-failure.json',
  'Fail Workflow Run: create_public_publish_confirmation': 'fail-workflow-run.json',
  'Mark Step Succeeded: create_public_publish_confirmation': 'mark-workflow-step.json',
  'Mark Upload Initialized': 'mark-upload-initialized.json',
  'Mark Metadata Applied': 'mark-metadata-applied.json',
  'Mark Thumbnail Applied': 'mark-thumbnail-applied.json',
  'Mark Captions Applied': 'mark-captions-applied.json',
  'Mark Playlist Applied': 'mark-playlist-applied.json',
  'Mark Publication Failed': 'mark-publication-failed.json',
  'Call: Update Upload Progress': 'update-upload-progress.json',
  'Call: Record YouTube Video Id': 'record-youtube-video-id.json',
  'Upload Video Chunks (Recurse)': 'upload-video-chunks.json',
  'Resolve Public Publish Confirmation': 'resolve-public-publish-confirmation.json',
  'YouTube Publish Project': 'youtube-publish-project.json',
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
  // Step 7 — script pipeline.
  'load-approved-research-for-script.json': 'Load Approved Research For Script',
  'script-budget-preflight.json': 'Script Budget Preflight',
  'create-script-version.json': 'Create Script Version',
  'get-current-script-version.json': 'Get Current Script Version',
  'script-deterministic-qc.json': 'Script Deterministic QC',
  'script-quality-control.json': 'Script Quality Control',
  'create-script-approval.json': 'Create Script Approval',
  'resolve-script-approval.json': 'Resolve Script Approval SQL',
  'get-script-approval-package.json': 'Get Script Approval Package',
  'get-flattened-script-narration.json': 'Get Flattened Script Narration',
  'generate-script.json': 'Generate Script',
  'revise-script.json': 'Revise Script',
  'review-script.json': 'Review Script',
  'generate-review-and-revise-script.json': 'Generate Review And Revise Script',
  'script-project.json': 'Script Project',
  'resolve-script-approval-workflow.json': 'Resolve Script Approval',
  // Step 8 — voiceover pipeline.
  'load-approved-script-for-voiceover.json': 'Load Approved Script For Voiceover',
  'voiceover-budget-preflight.json': 'Voiceover Budget Preflight',
  'get-or-create-voiceover.json': 'Get Or Create Voiceover',
  'prepare-voiceover-chunks-sql.json': 'Prepare Voiceover Chunks SQL',
  'claim-next-pending-voiceover-chunk.json': 'Claim Next Pending Voiceover Chunk',
  'persist-voiceover-chunk-success.json': 'Persist Voiceover Chunk Success',
  'mark-voiceover-chunk-failed.json': 'Mark Voiceover Chunk Failed',
  'get-voiceover-chunk-generation-summary.json': 'Get Voiceover Chunk Generation Summary',
  'get-completed-voiceover-chunks-in-order.json': 'Get Completed Voiceover Chunks In Order',
  'record-assembled-voiceover.json': 'Record Assembled Voiceover',
  'set-voiceover-subtitle-paths.json': 'Set Voiceover Subtitle Paths',
  'voiceover-quality-control-sql.json': 'Voiceover Quality Control SQL',
  'create-voiceover-approval.json': 'Create Voiceover Approval',
  'resolve-voiceover-approval.json': 'Resolve Voiceover Approval SQL',
  'get-voiceover-approval-package.json': 'Get Voiceover Approval Package',
  'get-current-voiceover.json': 'Get Current Voiceover',
  'prepare-voiceover-chunks.json': 'Prepare Voiceover Chunks',
  'generate-voiceover-chunk.json': 'Generate Voiceover Chunk',
  'generate-all-voiceover-chunks.json': 'Generate All Voiceover Chunks',
  'assemble-voiceover.json': 'Assemble Voiceover',
  'voiceover-project.json': 'Voiceover Project',
  'resolve-voiceover-approval-workflow.json': 'Resolve Voiceover Approval',
  // Step 9 — visual asset pipeline.
  'load-visual-inputs.json': 'Load Visual Inputs',
  'visual-budget-preflight.json': 'Visual Budget Preflight',
  'get-or-create-visual-shot-list.json': 'Get Or Create Visual Shot List',
  'persist-generated-shots.json': 'Persist Generated Shots',
  'claim-next-pending-visual-shot.json': 'Claim Next Pending Visual Shot',
  'find-reusable-asset.json': 'Find Reusable Asset',
  'persist-resolved-asset.json': 'Persist Resolved Asset',
  'mark-visual-shot-failed.json': 'Mark Visual Shot Failed',
  'get-visual-shot-resolution-summary.json': 'Get Visual Shot Resolution Summary',
  'get-resolved-shots-in-order.json': 'Get Resolved Shots In Order',
  'finalize-asset-assignments.json': 'Finalize Asset Assignments',
  'visual-quality-control-sql.json': 'Visual Quality Control SQL',
  'create-visual-approval.json': 'Create Visual Approval',
  'resolve-visual-approval.json': 'Resolve Visual Approval SQL',
  'get-visual-approval-package.json': 'Get Visual Approval Package',
  'list-pending-visual-approvals.json': 'List Pending Visual Approvals',
  'get-current-visual-shot-list.json': 'Get Current Visual Shot List',
  'create-visual-revision.json': 'Create Visual Revision',
  'generate-shot-list.json': 'Generate Shot List',
  'search-stock-media.json': 'Search Stock Media',
  'generate-image-asset.json': 'Generate Image Asset',
  'resolve-visual-requirement.json': 'Resolve Visual Requirement',
  'generate-all-visual-shots.json': 'Generate All Visual Shots',
  'visual-project.json': 'Visual Project',
  'resolve-visual-approval-workflow.json': 'Resolve Visual Approval',
  // Step 10 — video render pipeline.
  'load-render-inputs.json': 'Load Render Inputs',
  'render-budget-preflight.json': 'Render Budget Preflight',
  'build-scene-manifest.json': 'Build Scene Manifest',
  'validate-scene-manifest.json': 'Validate Scene Manifest',
  'get-current-scene-manifest.json': 'Get Current Scene Manifest',
  'get-or-create-render-job.json': 'Get Or Create Render Job',
  'update-render-job-progress.json': 'Update Render Job Progress',
  'persist-render-job-success.json': 'Persist Render Job Success',
  'mark-render-job-failed.json': 'Mark Render Job Failed',
  'render-quality-control-sql.json': 'Render Quality Control SQL',
  'create-final-video-approval.json': 'Create Final Video Approval',
  'resolve-final-video-approval.json': 'Resolve Final Video Approval SQL',
  'get-final-video-approval-package.json': 'Get Final Video Approval Package',
  'list-pending-final-video-approvals.json': 'List Pending Final Video Approvals',
  'get-current-final-video.json': 'Get Current Final Video',
  'create-render-revision.json': 'Create Render Revision',
  'invalidate-stale-render.json': 'Invalidate Stale Render',
  'submit-render-job.json': 'Submit Render Job',
  'poll-render-job.json': 'Poll Render Job',
  'render-and-validate.json': 'Render And Validate',
  'video-render-project.json': 'Video Render Project',
  'resolve-final-video-approval-workflow.json': 'Resolve Final Video Approval',
  // Step 11 — publication package pipeline.
  'load-publication-inputs.json': 'Load Publication Inputs',
  'publication-budget-preflight.json': 'Publication Budget Preflight',
  'get-or-create-publication-package.json': 'Get Or Create Publication Package',
  'persist-thumbnail-concepts.json': 'Persist Thumbnail Concepts',
  'claim-next-pending-thumbnail-concept.json': 'Claim Next Pending Thumbnail Concept',
  'get-or-create-thumbnail.json': 'Get Or Create Thumbnail',
  'persist-thumbnail-success.json': 'Persist Thumbnail Success',
  'mark-thumbnail-failed.json': 'Mark Thumbnail Failed',
  'get-publication-batch-status.json': 'Get Publication Batch Status',
  'persist-metadata-variants.json': 'Persist Metadata Variants',
  'record-metadata-grounding-result.json': 'Record Metadata Grounding Result',
  'score-title-thumbnail-pairs-sql.json': 'Score Title Thumbnail Pairs SQL',
  'validate-publication-package.json': 'Validate Publication Package',
  'create-publication-approval.json': 'Create Publication Approval',
  'resolve-publication-approval.json': 'Resolve Publication Approval SQL',
  'get-publication-approval-package.json': 'Get Publication Approval Package',
  'list-pending-publication-approvals.json': 'List Pending Publication Approvals',
  'get-current-publication-package.json': 'Get Current Publication Package',
  'create-publication-revision.json': 'Create Publication Revision',
  'invalidate-stale-publication-package.json': 'Invalidate Stale Publication Package',
  'generate-thumbnail-concepts.json': 'Generate Thumbnail Concepts',
  'render-thumbnail-variants.json': 'Render Thumbnail Variants',
  'generate-metadata.json': 'Generate Metadata',
  'score-title-thumbnail-pairs.json': 'Score Title Thumbnail Pairs',
  'publication-package-project.json': 'Publication Package Project',
  'resolve-publication-approval-workflow.json': 'Resolve Publication Approval',
  // Step 12 -- YouTube publication pipeline.
  'load-publication-upload-inputs.json': 'Load Publication Upload Inputs',
  'resolve-youtube-credential.json': 'Resolve YouTube Credential',
  'compute-final-video-checksum.json': 'Compute Final Video Checksum',
  'youtube-publication-preflight.json': 'Youtube Publication Preflight',
  'get-existing-upload-by-identity.json': 'Get Existing Upload By Identity',
  'get-or-create-publication-record.json': 'Get Or Create Publication Record',
  'youtube-quota-preflight.json': 'Youtube Quota Preflight',
  'resume-publication-state.json': 'Resume Publication State',
  'mark-upload-initialized.json': 'Mark Upload Initialized',
  'initialize-youtube-upload.json': 'Initialize YouTube Upload',
  'update-upload-progress.json': 'Update Upload Progress',
  'record-youtube-video-id.json': 'Record Youtube Video Id',
  'upload-video-chunks.json': 'Upload Video Chunks',
  'mark-metadata-applied.json': 'Mark Metadata Applied',
  'apply-youtube-metadata.json': 'Apply YouTube Metadata',
  'mark-thumbnail-applied.json': 'Mark Thumbnail Applied',
  'upload-youtube-thumbnail.json': 'Upload YouTube Thumbnail',
  'mark-captions-applied.json': 'Mark Captions Applied',
  'upload-youtube-captions.json': 'Upload YouTube Captions',
  'mark-playlist-applied.json': 'Mark Playlist Applied',
  'assign-youtube-playlist.json': 'Assign YouTube Playlist',
  'poll-youtube-processing.json': 'Poll YouTube Processing',
  'mark-scheduled.json': 'Mark Scheduled',
  'mark-publication-complete.json': 'Mark Publication Complete',
  'mark-publication-failed.json': 'Mark Publication Failed',
  'resolve-publishing-failure.json': 'Resolve Publishing Failure',
  'create-public-publish-confirmation.json': 'Create Public Publish Confirmation',
  'get-public-publish-confirmation-package.json': 'Get Public Publish Confirmation Package',
  'list-pending-public-publish-confirmations.json': 'List Pending Public Publish Confirmations',
  'resolve-public-publish-confirmation.json': 'Resolve Public Publish Confirmation SQL',
  'get-current-published-video.json': 'Get Current Published Video',
  'youtube-publish-project.json': 'YouTube Publish Project',
};

main().catch((err) => {
  console.error('Import failed:', err.message);
  process.exit(1);
});
