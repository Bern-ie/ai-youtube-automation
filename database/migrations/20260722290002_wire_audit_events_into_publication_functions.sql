-- Step 13: wire the new record_audit_log() writer into the Step 12
-- publication functions whose actions are on the "meaningful action"
-- allowlist. Each function body below is copied verbatim from
-- database/schema.sql (not retyped from memory) with exactly one
-- `PERFORM record_audit_log(...)` call added at the point the
-- corresponding state change is committed -- no other behavior changes.

-- migrate:up

CREATE OR REPLACE FUNCTION public.record_youtube_video_id(p_channel_id uuid, p_published_video_id uuid, p_youtube_video_id text, p_youtube_url text, p_last_provider_response jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'processing', youtube_video_id = p_youtube_video_id, youtube_url = p_youtube_url,
    last_provider_response = COALESCE(p_last_provider_response, '{}'::jsonb)
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  PERFORM record_audit_log(p_channel_id, 'service', 'youtube_upload_initialized', 'published_video', v_row.id,
    'youtube-publication-pipeline', 'workflow', NULL, jsonb_build_object('youtube_video_id', v_row.youtube_video_id, 'upload_status', v_row.upload_status), NULL, NULL);

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'youtube_video_id', v_row.youtube_video_id, 'youtube_url', v_row.youtube_url), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_row.content_project_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_publication_complete(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_published_video_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'complete',
    published_at = CASE WHEN privacy_status = 'public' AND scheduled_at IS NULL THEN now() ELSE published_at END
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  IF NOT v_row.requires_public_confirmation THEN
    UPDATE content_projects SET status = 'published' WHERE id = p_content_project_id;
  END IF;

  PERFORM record_audit_log(p_channel_id, 'service', 'youtube_upload_completed', 'published_video', v_row.id,
    'youtube-publication-pipeline', 'workflow', NULL,
    jsonb_build_object('upload_status', v_row.upload_status, 'privacy_status', v_row.privacy_status, 'youtube_video_id', v_row.youtube_video_id),
    NULL, p_workflow_run_id);

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('published_video_id', v_row.id, 'upload_status', v_row.upload_status, 'privacy_status', v_row.privacy_status, 'youtube_video_id', v_row.youtube_video_id, 'youtube_url', v_row.youtube_url),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_scheduled(p_channel_id uuid, p_published_video_id uuid, p_scheduled_at timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_before_privacy TEXT;
  v_row published_videos%ROWTYPE;
BEGIN
  IF p_scheduled_at IS NULL OR p_scheduled_at <= now() THEN
    RETURN _runtime_error('YOUTUBE_SCHEDULE_INVALID', format('scheduled_at must be a future timestamp, got %s', p_scheduled_at), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT privacy_status INTO v_before_privacy FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;

  UPDATE published_videos SET scheduled_at = p_scheduled_at, privacy_status = 'private'
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  IF v_before_privacy IS DISTINCT FROM v_row.privacy_status THEN
    PERFORM record_audit_log(p_channel_id, 'service', 'publication_privacy_changed', 'published_video', v_row.id,
      'youtube-publication-pipeline', 'workflow', jsonb_build_object('privacy_status', v_before_privacy),
      jsonb_build_object('privacy_status', v_row.privacy_status, 'scheduled_at', v_row.scheduled_at), NULL, NULL);
  END IF;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'scheduled_at', v_row.scheduled_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_public_publish_confirmation(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_scheduled_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_approval approval_requests%ROWTYPE;
  v_video published_videos%ROWTYPE;
  v_workflow_run_id UUID;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('decision must be approved/rejected, got %s', p_decision), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT * INTO v_approval FROM approval_requests WHERE id = p_approval_request_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'public_publish_confirmation' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not public_publish_confirmation', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('YOUTUBE_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF p_decision = 'approved' AND p_scheduled_at IS NOT NULL AND p_scheduled_at <= now() THEN
    RETURN _runtime_error('YOUTUBE_SCHEDULE_INVALID', format('scheduled_at must be a future timestamp, got %s', p_scheduled_at), false, p_channel_id, NULL, v_approval.content_project_id, NULL);
  END IF;

  UPDATE approval_requests SET status = p_decision, decision = p_decision, decided_at = now(), reviewer_reference = p_reviewer_reference
    WHERE id = p_approval_request_id;

  IF p_decision = 'approved' THEN
    UPDATE published_videos SET
      privacy_status = CASE WHEN p_scheduled_at IS NOT NULL THEN 'private' ELSE 'public' END,
      scheduled_at = p_scheduled_at, public_publish_confirmed_at = now(),
      published_at = CASE WHEN p_scheduled_at IS NULL THEN now() ELSE published_at END
      WHERE id = v_approval.subject_id AND v_approval.subject_type = 'published_video'
      RETURNING * INTO v_video;
  ELSE
    SELECT * INTO v_video FROM published_videos WHERE id = v_approval.subject_id;
  END IF;

  UPDATE content_projects SET status = 'published' WHERE id = v_approval.content_project_id;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  IF v_approval.subject_type = 'published_video' THEN
    PERFORM record_audit_log(p_channel_id, CASE WHEN p_reviewer_reference IS NOT NULL THEN 'user' ELSE 'system' END,
      CASE WHEN p_decision = 'approved' THEN 'public_publish_confirmed' ELSE 'public_publish_rejected' END,
      'published_video', v_approval.subject_id, p_reviewer_reference, 'human_reviewer', NULL,
      jsonb_build_object('decision', p_decision, 'privacy_status', v_video.privacy_status, 'scheduled_at', v_video.scheduled_at),
      v_approval.correlation_id, v_workflow_run_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision, 'content_project_id', v_approval.content_project_id,
      'workflow_run_id', v_workflow_run_id, 'published_video_id', v_approval.subject_id,
      'privacy_status', v_video.privacy_status, 'scheduled_at', v_video.scheduled_at
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', v_workflow_run_id, 'content_project_id', v_approval.content_project_id, 'correlation_id', v_approval.correlation_id)
  );
END;
$$;

-- migrate:down

-- Restores each function to its exact Step 12 body (no audit call).

CREATE OR REPLACE FUNCTION public.record_youtube_video_id(p_channel_id uuid, p_published_video_id uuid, p_youtube_video_id text, p_youtube_url text, p_last_provider_response jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'processing', youtube_video_id = p_youtube_video_id, youtube_url = p_youtube_url,
    last_provider_response = COALESCE(p_last_provider_response, '{}'::jsonb)
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'youtube_video_id', v_row.youtube_video_id, 'youtube_url', v_row.youtube_url), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_row.content_project_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_publication_complete(p_channel_id uuid, p_workflow_run_id uuid, p_content_project_id uuid, p_published_video_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'complete',
    published_at = CASE WHEN privacy_status = 'public' AND scheduled_at IS NULL THEN now() ELSE published_at END
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  IF NOT v_row.requires_public_confirmation THEN
    UPDATE content_projects SET status = 'published' WHERE id = p_content_project_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('published_video_id', v_row.id, 'upload_status', v_row.upload_status, 'privacy_status', v_row.privacy_status, 'youtube_video_id', v_row.youtube_video_id, 'youtube_url', v_row.youtube_url),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_scheduled(p_channel_id uuid, p_published_video_id uuid, p_scheduled_at timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  IF p_scheduled_at IS NULL OR p_scheduled_at <= now() THEN
    RETURN _runtime_error('YOUTUBE_SCHEDULE_INVALID', format('scheduled_at must be a future timestamp, got %s', p_scheduled_at), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  UPDATE published_videos SET scheduled_at = p_scheduled_at, privacy_status = 'private'
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'scheduled_at', v_row.scheduled_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_public_publish_confirmation(p_channel_id uuid, p_approval_request_id uuid, p_decision text, p_reviewer_reference text DEFAULT NULL::text, p_scheduled_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_approval approval_requests%ROWTYPE;
  v_video published_videos%ROWTYPE;
  v_workflow_run_id UUID;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('decision must be approved/rejected, got %s', p_decision), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  SELECT * INTO v_approval FROM approval_requests WHERE id = p_approval_request_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('approval_request %s not found for channel %s', p_approval_request_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  IF v_approval.stage != 'public_publish_confirmation' THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('approval_request %s is stage %s, not public_publish_confirmation', p_approval_request_id, v_approval.stage), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF v_approval.status != 'pending' THEN
    RETURN _runtime_error('YOUTUBE_INVALID_PROJECT_STATE', format('approval_request %s is already %s, not pending', p_approval_request_id, v_approval.status), false,
      p_channel_id, NULL, v_approval.content_project_id, v_approval.correlation_id);
  END IF;
  IF p_decision = 'approved' AND p_scheduled_at IS NOT NULL AND p_scheduled_at <= now() THEN
    RETURN _runtime_error('YOUTUBE_SCHEDULE_INVALID', format('scheduled_at must be a future timestamp, got %s', p_scheduled_at), false, p_channel_id, NULL, v_approval.content_project_id, NULL);
  END IF;

  UPDATE approval_requests SET status = p_decision, decision = p_decision, decided_at = now(), reviewer_reference = p_reviewer_reference
    WHERE id = p_approval_request_id;

  IF p_decision = 'approved' THEN
    UPDATE published_videos SET
      privacy_status = CASE WHEN p_scheduled_at IS NOT NULL THEN 'private' ELSE 'public' END,
      scheduled_at = p_scheduled_at, public_publish_confirmed_at = now(),
      published_at = CASE WHEN p_scheduled_at IS NULL THEN now() ELSE published_at END
      WHERE id = v_approval.subject_id AND v_approval.subject_type = 'published_video'
      RETURNING * INTO v_video;
  ELSE
    SELECT * INTO v_video FROM published_videos WHERE id = v_approval.subject_id;
  END IF;

  UPDATE content_projects SET status = 'published' WHERE id = v_approval.content_project_id;

  SELECT id INTO v_workflow_run_id FROM workflow_runs
    WHERE content_project_id = v_approval.content_project_id AND correlation_id = v_approval.correlation_id AND status = 'waiting'
    ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'approval_request_id', p_approval_request_id, 'decision', p_decision, 'content_project_id', v_approval.content_project_id,
      'workflow_run_id', v_workflow_run_id, 'published_video_id', v_approval.subject_id,
      'privacy_status', v_video.privacy_status, 'scheduled_at', v_video.scheduled_at
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', v_workflow_run_id, 'content_project_id', v_approval.content_project_id, 'correlation_id', v_approval.correlation_id)
  );
END;
$$;
