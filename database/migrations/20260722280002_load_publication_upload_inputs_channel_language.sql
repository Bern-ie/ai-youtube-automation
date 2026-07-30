-- migrate:up

-- Step 12 fix, caught while wiring the "Upload Captions" step: nothing
-- upstream of load_publication_upload_inputs's return value carried the
-- channel's configured language, so the caption-language step ("Do not
-- guess when configuration already exists" -- see
-- docs/architecture/youtube-publication-pipeline.md#captions) had no
-- config-backed value to read. channels.language already exists and is
-- exactly that configuration -- just wasn't selected here.
CREATE OR REPLACE FUNCTION load_publication_upload_inputs(
  p_channel_id UUID,
  p_workflow_run_id UUID,
  p_content_project_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_run workflow_runs%ROWTYPE;
  v_project content_projects%ROWTYPE;
  v_channel channels%ROWTYPE;
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

  SELECT * INTO v_channel FROM channels WHERE id = p_channel_id;

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
      'content_project_id', v_project.id, 'topic', v_project.topic, 'channel_language', v_channel.language,
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

-- migrate:down

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
