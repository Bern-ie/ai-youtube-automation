-- Step 12: YouTube OAuth, Resumable Upload, Scheduling, Captions,
-- Playlist Assignment, and Publication State -- SQL business logic
-- layer. Every duplicate-upload-prevention/idempotency decision lives
-- here; n8n owns all real HTTP calls to the YouTube Data API (using its
-- own OAuth credential store -- no token ever reaches this database).
-- See docs/architecture/youtube-publication-pipeline.md.

-- migrate:up

-- ============================================================
-- 1. load_publication_upload_inputs -- resumable step
--    "load_publication_upload_inputs". Validates the project has an
--    approved publication package and loads everything the upload
--    pipeline needs (final video, selected title/thumbnail/metadata,
--    channel publication/upload policy, the youtube_oauth credential
--    reference) -- never re-derives or re-requests any of it.
-- ============================================================
CREATE OR REPLACE FUNCTION load_publication_upload_inputs(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_package JSONB;
  v_thumbnail RECORD;
  v_voiceover JSONB;
  v_credential RECORD;
  v_branding RECORD;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_project FROM content_projects WHERE id = p_content_project_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('content_project %s does not exist', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;
  IF v_project.channel_id != p_channel_id THEN
    RETURN _runtime_error('PROJECT_CHANNEL_MISMATCH',
      format('content_project %s belongs to channel %s, not %s', p_content_project_id, v_project.channel_id, p_channel_id),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status NOT IN ('publication_approved', 'uploading') THEN
    RETURN _runtime_error('YOUTUBE_INVALID_PROJECT_STATE',
      format('content_project %s is in status %s, which cannot begin or resume YouTube publication', p_content_project_id, v_project.status),
      false, p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  IF v_project.status = 'publication_approved' THEN
    UPDATE content_projects SET status = 'uploading' WHERE id = p_content_project_id;
  END IF;

  v_package := get_current_publication_package(p_channel_id, p_content_project_id);
  IF v_package IS NULL THEN
    RETURN _runtime_error('YOUTUBE_PUBLICATION_NOT_APPROVED',
      format('content_project %s has no approved current publication package', p_content_project_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT t.id, t.storage_path, t.checksum, t.width_px, t.height_px, t.format INTO v_thumbnail
    FROM publication_packages pp JOIN thumbnails t ON t.id = pp.selected_thumbnail_id
    WHERE pp.id = (v_package->>'publication_package_id')::uuid;

  v_voiceover := get_current_voiceover(p_channel_id, p_content_project_id);

  SELECT * INTO v_credential FROM channel_credentials
    WHERE channel_id = p_channel_id AND credential_type = 'youtube_oauth' AND provider = 'youtube'
    ORDER BY updated_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_CREDENTIAL_NOT_CONFIGURED',
      format('channel %s has no youtube_oauth credential reference configured', p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id);
  END IF;

  SELECT publication_policy INTO v_branding FROM channel_branding WHERE channel_id = p_channel_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'content_project_id', v_project.id, 'topic', v_project.topic,
      'publication_package_id', v_package->'publication_package_id', 'final_video', v_package->'final_video',
      'title', v_package->'title', 'description', v_package->'description', 'chapters', v_package->'chapters',
      'tags', v_package->'tags', 'hashtags', v_package->'hashtags', 'pinned_comment', v_package->'pinned_comment',
      'community_post', v_package->'community_post', 'attribution_block', v_package->'attribution_block',
      'thumbnail', jsonb_build_object(
        'thumbnail_id', v_thumbnail.id, 'storage_path', v_thumbnail.storage_path, 'checksum', v_thumbnail.checksum,
        'width_px', v_thumbnail.width_px, 'height_px', v_thumbnail.height_px, 'format', v_thumbnail.format
      ),
      'caption_srt_path', v_voiceover->'subtitle_srt_path', 'caption_vtt_path', v_voiceover->'subtitle_vtt_path',
      'youtube_credential_reference', COALESCE(v_credential.n8n_credential_reference, v_credential.external_secret_reference),
      'youtube_credential_status', v_credential.status,
      'publication_policy', COALESCE(v_branding.publication_policy, '{}'::jsonb)
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 2. youtube_publication_preflight -- resumable step
--    "publication_preflight". Deterministic, defensive re-verification
--    of everything already validated upstream (Steps 10/11) plus the
--    facts only knowable at upload time (live file checksum, made-for-
--    kids policy, credential status).
-- ============================================================
CREATE OR REPLACE FUNCTION youtube_publication_preflight(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_actual_checksum TEXT,
  p_made_for_kids BOOLEAN DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_package RECORD;
  v_render_job RECORD;
  v_thumbnail RECORD;
  v_branding RECORD;
  v_credential RECORD;
  v_issues TEXT[] := ARRAY[]::TEXT[];
  v_made_for_kids_default TEXT;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT pp.* INTO v_package
    FROM publication_packages pp
    WHERE pp.channel_id = p_channel_id AND pp.content_project_id = p_content_project_id AND pp.is_current;
  IF NOT FOUND OR v_package.approved_at IS NULL THEN
    v_issues := array_append(v_issues, 'publication_package_not_approved');
  END IF;

  SELECT rj.* INTO v_render_job FROM render_jobs rj
    WHERE rj.id = v_package.final_video_render_job_id AND rj.channel_id = p_channel_id;
  IF NOT FOUND OR v_render_job.status != 'succeeded' OR v_render_job.qc_status = 'failed' THEN
    v_issues := array_append(v_issues, 'final_render_qc_not_passed');
  END IF;
  IF v_render_job.output_checksum IS DISTINCT FROM p_actual_checksum THEN
    v_issues := array_append(v_issues, 'checksum_mismatch');
  END IF;

  IF v_package.attribution_block IS NOT NULL AND COALESCE((v_package.attribution_block->'required')::boolean, false)
    AND jsonb_array_length(COALESCE(v_package.attribution_block->'lines', '[]'::jsonb)) = 0 THEN
    v_issues := array_append(v_issues, 'attribution_incomplete');
  END IF;

  IF v_package.selected_thumbnail_id IS NULL THEN
    v_issues := array_append(v_issues, 'no_thumbnail_selected');
  ELSE
    SELECT * INTO v_thumbnail FROM thumbnails WHERE id = v_package.selected_thumbnail_id AND channel_id = p_channel_id;
    IF NOT FOUND OR v_thumbnail.status != 'completed' THEN v_issues := array_append(v_issues, 'selected_thumbnail_invalid'); END IF;
  END IF;
  IF v_package.selected_metadata_variant_id IS NULL THEN
    v_issues := array_append(v_issues, 'no_title_selected');
  END IF;

  SELECT * INTO v_credential FROM channel_credentials
    WHERE channel_id = p_channel_id AND credential_type = 'youtube_oauth' AND provider = 'youtube'
    ORDER BY updated_at DESC LIMIT 1;
  IF NOT FOUND OR v_credential.status != 'active' THEN
    v_issues := array_append(v_issues, 'credential_not_active');
  END IF;

  SELECT publication_policy INTO v_branding FROM channel_branding WHERE channel_id = p_channel_id;
  v_made_for_kids_default := v_branding.publication_policy->>'made_for_kids_default';
  IF p_made_for_kids IS NULL AND v_made_for_kids_default IS NULL THEN
    v_issues := array_append(v_issues, 'made_for_kids_not_configured');
  END IF;

  IF array_length(v_issues, 1) IS NOT NULL THEN
    RETURN jsonb_set(
      _runtime_error('YOUTUBE_PREFLIGHT_FAILED', format('publication preflight failed for project %s: %s', p_content_project_id, array_to_string(v_issues, ', ')), false,
        p_channel_id, p_workflow_run_id, p_content_project_id, v_run.correlation_id),
      '{error,details}', jsonb_build_object('issues', to_jsonb(v_issues))
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'publication_package_id', v_package.id, 'final_render_job_id', v_render_job.id, 'final_render_checksum', v_render_job.output_checksum,
      'made_for_kids', COALESCE(p_made_for_kids, v_made_for_kids_default::boolean)
    ),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3. get_existing_upload_by_identity -- read-only defensive check the
--    workflow calls BEFORE deciding whether to initialize a new upload.
-- ============================================================
CREATE OR REPLACE FUNCTION get_existing_upload_by_identity(
  p_channel_id UUID,
  p_upload_identity_checksum TEXT
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'published_video_id', id, 'upload_status', upload_status, 'youtube_video_id', youtube_video_id,
    'youtube_url', youtube_url, 'bytes_uploaded', bytes_uploaded, 'total_bytes', total_bytes,
    'upload_session_uri', upload_session_uri, 'metadata_applied_at', metadata_applied_at,
    'thumbnail_applied_at', thumbnail_applied_at, 'captions_applied_at', captions_applied_at,
    'playlist_applied_at', playlist_applied_at
  )
  FROM published_videos WHERE channel_id = p_channel_id AND upload_identity_checksum = p_upload_identity_checksum;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 4. get_or_create_publication_record -- THE duplicate-upload-
--    prevention guarantee. Computes a strong upload-identity checksum
--    (channel + project + final render job + final render checksum +
--    publication package id + youtube credential reference + caller
--    idempotency key) and reuses any existing row with that exact
--    identity rather than ever creating a second video for the same
--    approved combination.
-- ============================================================
CREATE OR REPLACE FUNCTION get_or_create_publication_record(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_upload_idempotency_key TEXT,
  p_privacy_status TEXT DEFAULT 'private',
  p_made_for_kids BOOLEAN DEFAULT NULL,
  p_category_id TEXT DEFAULT NULL,
  p_requires_public_confirmation BOOLEAN DEFAULT true
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_package publication_packages%ROWTYPE;
  v_render_job render_jobs%ROWTYPE;
  v_credential RECORD;
  v_identity TEXT;
  v_existing published_videos%ROWTYPE;
  v_id UUID;
  v_created BOOLEAN := false;
BEGIN
  IF p_privacy_status NOT IN ('private', 'unlisted', 'public') THEN
    RETURN _runtime_error('INVALID_EXECUTION_CONTEXT', format('privacy_status must be private/unlisted/public, got %s', p_privacy_status), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  SELECT * INTO v_package FROM publication_packages WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND is_current;
  SELECT * INTO v_render_job FROM render_jobs WHERE id = v_package.final_video_render_job_id AND channel_id = p_channel_id;
  SELECT * INTO v_credential FROM channel_credentials
    WHERE channel_id = p_channel_id AND credential_type = 'youtube_oauth' AND provider = 'youtube'
    ORDER BY updated_at DESC LIMIT 1;

  v_identity := encode(sha256(convert_to(
    p_channel_id::text || '|' || p_content_project_id::text || '|' || COALESCE(v_render_job.id::text, '') || '|' ||
    COALESCE(v_render_job.output_checksum, '') || '|' || COALESCE(v_package.id::text, '') || '|' ||
    COALESCE(v_credential.n8n_credential_reference, v_credential.external_secret_reference, '') || '|' || p_upload_idempotency_key,
    'UTF8')), 'hex');

  SELECT * INTO v_existing FROM published_videos WHERE channel_id = p_channel_id AND upload_identity_checksum = v_identity;
  IF v_existing.id IS NOT NULL THEN
    v_id := v_existing.id;
  ELSE
    -- The video is ALWAYS uploaded as private/unlisted first when public
    -- confirmation is required, per "1. upload private" in the brief's
    -- Public Publish Confirmation steps -- a caller requesting
    -- privacy_status='public' with requires_public_confirmation=true
    -- gets 'private' stored here; only resolve_public_publish_confirmation's
    -- 'approved' branch ever sets privacy_status='public'. Storing the
    -- caller's literal request instead would make published_videos.privacy_status
    -- lie about what YouTube was actually told before confirmation.
    INSERT INTO published_videos (
      channel_id, content_project_id, publication_package_id, final_render_job_id, final_render_checksum,
      title, selected_thumbnail_id, metadata_variant_id, privacy_status, made_for_kids, category_id,
      upload_idempotency_key, upload_identity_checksum, youtube_credential_reference, requires_public_confirmation, upload_status
    ) VALUES (
      p_channel_id, p_content_project_id, v_package.id, v_render_job.id, v_render_job.output_checksum,
      COALESCE(v_package.title_override, (SELECT title FROM metadata_variants WHERE id = v_package.selected_metadata_variant_id)),
      v_package.selected_thumbnail_id, v_package.selected_metadata_variant_id,
      CASE WHEN p_requires_public_confirmation AND p_privacy_status = 'public' THEN 'private' ELSE p_privacy_status END,
      p_made_for_kids, p_category_id,
      p_upload_idempotency_key, v_identity, COALESCE(v_credential.n8n_credential_reference, v_credential.external_secret_reference),
      p_requires_public_confirmation, 'pending'
    ) RETURNING id INTO v_id;
    v_created := true;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('published_video_id', v_id, 'created', v_created, 'upload_identity_checksum', v_identity),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 5. mark_upload_initialized -- persists the resumable-upload session
--    URI immediately once YouTube grants one, before any bytes are
--    sent, so an interruption right after initialization still knows
--    where to resume.
-- ============================================================
CREATE OR REPLACE FUNCTION mark_upload_initialized(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_upload_session_uri TEXT,
  p_total_bytes BIGINT
) RETURNS JSONB AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    upload_status = 'uploading', upload_session_uri = p_upload_session_uri, total_bytes = p_total_bytes
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'upload_status', v_row.upload_status), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 6. update_upload_progress -- called after each resumable-upload
--    chunk. Never resets upload_attempt itself (the caller increments
--    it only when starting a genuinely new attempt after a failure).
-- ============================================================
CREATE OR REPLACE FUNCTION update_upload_progress(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_bytes_uploaded BIGINT,
  p_last_provider_response JSONB DEFAULT '{}'::jsonb,
  p_new_attempt BOOLEAN DEFAULT false
) RETURNS JSONB AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    bytes_uploaded = p_bytes_uploaded, last_provider_response = COALESCE(p_last_provider_response, '{}'::jsonb),
    upload_attempt = CASE WHEN p_new_attempt THEN upload_attempt + 1 ELSE upload_attempt END
    WHERE id = p_published_video_id AND channel_id = p_channel_id
    RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'bytes_uploaded', v_row.bytes_uploaded, 'total_bytes', v_row.total_bytes, 'upload_attempt', v_row.upload_attempt), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 7. record_youtube_video_id -- THE critical checkpoint: persisted the
--    instant YouTube confirms a video ID, before metadata/thumbnail/
--    captions/playlist run, so a later failure in any of those never
--    causes a second upload -- the whole point of duplicate-upload
--    prevention. Sets status 'processing' (upload done, YouTube itself
--    may still be transcoding).
-- ============================================================
CREATE OR REPLACE FUNCTION record_youtube_video_id(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_youtube_video_id TEXT,
  p_youtube_url TEXT,
  p_last_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 8-11. mark_metadata_applied / mark_thumbnail_applied /
--       mark_captions_applied / mark_playlist_applied -- one
--       completion marker per side effect, per the brief's "Persist
--       completion markers ... Do not infer completion only from
--       workflow-step state."
-- ============================================================
CREATE OR REPLACE FUNCTION mark_metadata_applied(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_last_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET metadata_applied_at = now(), last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'metadata_applied_at', v_row.metadata_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_thumbnail_applied(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_last_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET thumbnail_applied_at = now(), last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'thumbnail_applied_at', v_row.thumbnail_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_captions_applied(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_caption_language TEXT,
  p_caption_storage_path TEXT,
  p_last_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    captions_applied_at = now(), caption_language = p_caption_language, caption_storage_path = p_caption_storage_path,
    last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'captions_applied_at', v_row.captions_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION mark_playlist_applied(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_youtube_playlist_id TEXT,
  p_last_provider_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
  v_row published_videos%ROWTYPE;
BEGIN
  UPDATE published_videos SET
    playlist_applied_at = now(), youtube_playlist_id = p_youtube_playlist_id,
    last_provider_response = COALESCE(p_last_provider_response, last_provider_response)
    WHERE id = p_published_video_id AND channel_id = p_channel_id RETURNING * INTO v_row;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('published_video_id', v_row.id, 'playlist_applied_at', v_row.playlist_applied_at), 'error', null, 'runtime', jsonb_build_object('channel_id', p_channel_id));
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 12. mark_scheduled -- validates the requested publish time is in the
--     future before recording it. Never invents a publish time.
-- ============================================================
CREATE OR REPLACE FUNCTION mark_scheduled(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_scheduled_at TIMESTAMPTZ
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 13. mark_publication_complete -- resumable step
--     "finalize_publication_record". Every configured upload/metadata/
--     thumbnail/captions/playlist side effect has now succeeded.
--     content_projects.status moves to the Step-3-scaffolded terminal
--     'published' value regardless of the video's actual YouTube
--     privacy setting -- it marks "the Step 12 pipeline finished its
--     work", not "the video is literally public";
--     published_videos.privacy_status/scheduled_at/published_at carry
--     the real distinction. The ONLY gate on that transition is
--     requires_public_confirmation: when true, privacy_status is always
--     'private' at this point (get_or_create_publication_record never
--     lets it start as anything else) and the project deliberately
--     STAYS 'uploading' until resolve_public_publish_confirmation
--     itself sets 'published' -- otherwise the project would say
--     "published" while a human hasn't yet approved the video going
--     public at all. published_at is only set here for the immediate-
--     public, non-scheduled, non-confirmation-required case -- a
--     scheduled video's published_at is left for a later recheck (see
--     Known limitations).
-- ============================================================
CREATE OR REPLACE FUNCTION mark_publication_complete(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_published_video_id UUID
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 14. mark_publication_failed -- bounded retry lives in n8n; this
--     records a terminal failure of one attempt without touching
--     already-recorded side-effect markers (a partially-complete
--     upload's progress is never discarded by a later failure).
-- ============================================================
CREATE OR REPLACE FUNCTION mark_publication_failed(
  p_channel_id UUID,
  p_published_video_id UUID,
  p_workflow_run_id UUID,
  p_error_code TEXT,
  p_message TEXT,
  p_sanitized_details JSONB DEFAULT '{}'::jsonb,
  p_retryable BOOLEAN DEFAULT true
) RETURNS JSONB AS $$
DECLARE
  v_row published_videos%ROWTYPE;
  v_error_id UUID;
BEGIN
  SELECT * INTO v_row FROM published_videos WHERE id = p_published_video_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('YOUTUBE_PROJECT_NOT_FOUND', format('published_video %s not found for channel %s', p_published_video_id, p_channel_id), false, p_channel_id, NULL, NULL, NULL);
  END IF;

  INSERT INTO errors (channel_id, content_project_id, workflow_run_id, service, error_code, message, sanitized_details, retryable)
  VALUES (p_channel_id, v_row.content_project_id, p_workflow_run_id, 'n8n-youtube-publication-pipeline', p_error_code, p_message, p_sanitized_details, p_retryable)
  RETURNING id INTO v_error_id;

  UPDATE published_videos SET upload_status = CASE WHEN p_retryable THEN upload_status ELSE 'failed' END, error_id = v_error_id
    WHERE id = p_published_video_id;

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('published_video_id', p_published_video_id, 'error_id', v_error_id), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'content_project_id', v_row.content_project_id, 'workflow_run_id', p_workflow_run_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 15. create_public_publish_confirmation -- resumable step
--     "resolve_publishing_failure"'s sibling for the happy path: pauses
--     the run for an explicit human go-ahead before privacy ever
--     changes away from private/unlisted, per
--     require_public_publish_confirmation = true (the initial-rollout
--     default).
-- ============================================================
CREATE OR REPLACE FUNCTION create_public_publish_confirmation(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID,
  p_published_video_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_approval_id UUID;
BEGIN
  SELECT * INTO v_run FROM workflow_runs WHERE id = p_workflow_run_id AND channel_id = p_channel_id;
  IF NOT FOUND THEN
    RETURN _runtime_error('WORKFLOW_RUN_NOT_FOUND',
      format('workflow_run %s not found for channel %s', p_workflow_run_id, p_channel_id), false,
      p_channel_id, p_workflow_run_id, p_content_project_id, NULL);
  END IF;

  INSERT INTO approval_requests (channel_id, content_project_id, stage, subject_type, subject_id, correlation_id)
  VALUES (p_channel_id, p_content_project_id, 'public_publish_confirmation', 'published_video', p_published_video_id, v_run.correlation_id)
  RETURNING id INTO v_approval_id;

  UPDATE workflow_runs SET status = 'waiting' WHERE id = p_workflow_run_id AND status = 'running';

  RETURN jsonb_build_object(
    'success', true, 'data', jsonb_build_object('approval_request_id', v_approval_id, 'status', 'pending'), 'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id, 'workflow_run_id', p_workflow_run_id, 'content_project_id', p_content_project_id, 'correlation_id', v_run.correlation_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 16. resolve_public_publish_confirmation -- approved flips privacy to
--     public (or schedules it) and marks the project published;
--     rejected leaves the video private/unlisted, per the brief's "Do
--     not delete the video automatically." Either outcome completes
--     the Step 12 pipeline.
-- ============================================================
CREATE OR REPLACE FUNCTION resolve_public_publish_confirmation(
  p_channel_id UUID,
  p_approval_request_id UUID,
  p_decision TEXT,
  p_reviewer_reference TEXT DEFAULT NULL,
  p_scheduled_at TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB AS $$
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
$$ LANGUAGE plpgsql;

-- ============================================================
-- 17. get_public_publish_confirmation_package /
--     list_pending_public_publish_confirmations -- human-facing
--     approval package and pending list, mirroring every prior stage's
--     equivalents.
-- ============================================================
CREATE OR REPLACE FUNCTION get_public_publish_confirmation_package(
  p_channel_id UUID,
  p_approval_request_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'approval_request_id', ar.id, 'status', ar.status, 'content_project_id', ar.content_project_id,
    'topic', cp.topic,
    'published_video', jsonb_build_object(
      'published_video_id', pv.id, 'youtube_video_id', pv.youtube_video_id, 'youtube_url', pv.youtube_url,
      'title', pv.title, 'privacy_status', pv.privacy_status, 'upload_status', pv.upload_status,
      'metadata_applied_at', pv.metadata_applied_at, 'thumbnail_applied_at', pv.thumbnail_applied_at,
      'captions_applied_at', pv.captions_applied_at, 'playlist_applied_at', pv.playlist_applied_at
    ),
    'requested_at', ar.requested_at
  )
  FROM approval_requests ar
  JOIN content_projects cp ON cp.id = ar.content_project_id
  LEFT JOIN published_videos pv ON pv.id = ar.subject_id AND ar.subject_type = 'published_video'
  WHERE ar.id = p_approval_request_id AND ar.channel_id = p_channel_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION list_pending_public_publish_confirmations(
  p_channel_id UUID
) RETURNS JSONB AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('approval_request_id', ar.id, 'content_project_id', ar.content_project_id, 'topic', cp.topic, 'requested_at', ar.requested_at) ORDER BY ar.requested_at), '[]'::jsonb)
  FROM approval_requests ar JOIN content_projects cp ON cp.id = ar.content_project_id
  WHERE ar.channel_id = p_channel_id AND ar.stage = 'public_publish_confirmation' AND ar.status = 'pending';
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 18. resume_publication_state -- read-only. Tells a resumed workflow
--     run exactly which side effects are already done so it never
--     repeats a successful side-effecting operation, per the brief.
-- ============================================================
CREATE OR REPLACE FUNCTION resume_publication_state(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'published_video_id', id, 'upload_status', upload_status, 'youtube_video_id', youtube_video_id,
    'bytes_uploaded', bytes_uploaded, 'total_bytes', total_bytes, 'upload_session_uri', upload_session_uri,
    'upload_attempt', upload_attempt, 'metadata_applied', metadata_applied_at IS NOT NULL,
    'thumbnail_applied', thumbnail_applied_at IS NOT NULL, 'captions_applied', captions_applied_at IS NOT NULL,
    'playlist_applied', playlist_applied_at IS NOT NULL, 'privacy_status', privacy_status, 'scheduled_at', scheduled_at,
    'requires_public_confirmation', requires_public_confirmation, 'public_publish_confirmed_at', public_publish_confirmed_at
  )
  FROM published_videos
  WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id
  ORDER BY created_at DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

-- ============================================================
-- 19. youtube_quota_preflight -- soft, warning-only (per the brief's
--     "do not add complex quota management unless needed") check
--     against an optional channel-configured daily quota-unit budget.
--     Never hard-blocks -- Google's own quota enforcement is the real
--     backstop; this is advisory.
-- ============================================================
CREATE OR REPLACE FUNCTION youtube_quota_preflight(
  p_channel_id UUID,
  p_estimated_quota_units NUMERIC DEFAULT 1600
) RETURNS JSONB AS $$
DECLARE
  v_daily_budget NUMERIC;
  v_used_today NUMERIC;
  v_warnings TEXT[] := ARRAY[]::TEXT[];
BEGIN
  SELECT (publication_policy->>'youtube_daily_quota_budget_units')::numeric INTO v_daily_budget
    FROM channel_branding WHERE channel_id = p_channel_id;

  SELECT COALESCE(SUM(quantity), 0) INTO v_used_today FROM provider_usage_events
    WHERE channel_id = p_channel_id AND provider = 'youtube' AND unit = 'quota_units'
      AND occurred_at >= date_trunc('day', now());

  IF v_daily_budget IS NOT NULL AND (v_used_today + p_estimated_quota_units) >= v_daily_budget THEN
    v_warnings := array_append(v_warnings, format('estimated YouTube quota usage (%s used + %s estimated) is at or near the configured daily budget of %s units', v_used_today, p_estimated_quota_units, v_daily_budget));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object('used_today_units', v_used_today, 'daily_budget_units', v_daily_budget, 'warnings', to_jsonb(v_warnings)),
    'error', null,
    'runtime', jsonb_build_object('channel_id', p_channel_id)
  );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 20. get_current_published_video -- the Step 13 handoff point.
-- ============================================================
CREATE OR REPLACE FUNCTION get_current_published_video(
  p_channel_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
  SELECT jsonb_build_object(
    'published_video_id', id, 'youtube_video_id', youtube_video_id, 'youtube_url', youtube_url,
    'upload_status', upload_status, 'privacy_status', privacy_status, 'scheduled_at', scheduled_at, 'published_at', published_at,
    'title', title, 'selected_thumbnail_id', selected_thumbnail_id, 'metadata_variant_id', metadata_variant_id,
    'publication_package_id', publication_package_id, 'final_render_job_id', final_render_job_id,
    'youtube_playlist_id', youtube_playlist_id, 'caption_language', caption_language,
    'pinned_comment_status', pinned_comment_status, 'community_post_status', community_post_status
  )
  FROM published_videos
  WHERE channel_id = p_channel_id AND content_project_id = p_content_project_id AND upload_status = 'complete'
  ORDER BY created_at DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

GRANT EXECUTE ON FUNCTION load_publication_upload_inputs(UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION youtube_publication_preflight(UUID, UUID, UUID, TEXT, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_existing_upload_by_identity(UUID, TEXT) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_or_create_publication_record(UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_upload_initialized(UUID, UUID, TEXT, BIGINT) TO app_runtime;
GRANT EXECUTE ON FUNCTION update_upload_progress(UUID, UUID, BIGINT, JSONB, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION record_youtube_video_id(UUID, UUID, TEXT, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_metadata_applied(UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_thumbnail_applied(UUID, UUID, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_captions_applied(UUID, UUID, TEXT, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_playlist_applied(UUID, UUID, TEXT, JSONB) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_scheduled(UUID, UUID, TIMESTAMPTZ) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_publication_complete(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION mark_publication_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN) TO app_runtime;
GRANT EXECUTE ON FUNCTION create_public_publish_confirmation(UUID, UUID, UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resolve_public_publish_confirmation(UUID, UUID, TEXT, TEXT, TIMESTAMPTZ) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_public_publish_confirmation_package(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION list_pending_public_publish_confirmations(UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION resume_publication_state(UUID, UUID) TO app_runtime;
GRANT EXECUTE ON FUNCTION youtube_quota_preflight(UUID, NUMERIC) TO app_runtime;
GRANT EXECUTE ON FUNCTION get_current_published_video(UUID, UUID) TO app_runtime;

-- migrate:down

DROP FUNCTION get_current_published_video(UUID, UUID);
DROP FUNCTION youtube_quota_preflight(UUID, NUMERIC);
DROP FUNCTION resume_publication_state(UUID, UUID);
DROP FUNCTION list_pending_public_publish_confirmations(UUID);
DROP FUNCTION get_public_publish_confirmation_package(UUID, UUID);
DROP FUNCTION resolve_public_publish_confirmation(UUID, UUID, TEXT, TEXT, TIMESTAMPTZ);
DROP FUNCTION create_public_publish_confirmation(UUID, UUID, UUID, UUID);
DROP FUNCTION mark_publication_failed(UUID, UUID, UUID, TEXT, TEXT, JSONB, BOOLEAN);
DROP FUNCTION mark_publication_complete(UUID, UUID, UUID, UUID);
DROP FUNCTION mark_scheduled(UUID, UUID, TIMESTAMPTZ);
DROP FUNCTION mark_playlist_applied(UUID, UUID, TEXT, JSONB);
DROP FUNCTION mark_captions_applied(UUID, UUID, TEXT, TEXT, JSONB);
DROP FUNCTION mark_thumbnail_applied(UUID, UUID, JSONB);
DROP FUNCTION mark_metadata_applied(UUID, UUID, JSONB);
DROP FUNCTION record_youtube_video_id(UUID, UUID, TEXT, TEXT, JSONB);
DROP FUNCTION update_upload_progress(UUID, UUID, BIGINT, JSONB, BOOLEAN);
DROP FUNCTION mark_upload_initialized(UUID, UUID, TEXT, BIGINT);
DROP FUNCTION get_or_create_publication_record(UUID, UUID, UUID, TEXT, TEXT, BOOLEAN, TEXT, BOOLEAN);
DROP FUNCTION get_existing_upload_by_identity(UUID, TEXT);
DROP FUNCTION youtube_publication_preflight(UUID, UUID, UUID, TEXT, BOOLEAN);
DROP FUNCTION load_publication_upload_inputs(UUID, UUID, UUID);
