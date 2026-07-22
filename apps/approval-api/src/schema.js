import { z } from 'zod';

// Strict: unknown fields are rejected rather than silently dropped, so a
// caller sending an unexpected shape gets an explicit validation error
// instead of quietly losing data.
export const testEchoSchema = z
  .object({
    channel_id: z.string().uuid(),
    content_project_id: z.string().uuid(),
    workflow_run_id: z.string().uuid(),
    correlation_id: z.string().uuid().optional(),
  })
  .strict();
