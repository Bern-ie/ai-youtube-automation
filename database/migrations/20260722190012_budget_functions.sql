-- migrate:up

-- Budget figures are always computed live from cost_events — never a
-- cached application-side total — per
-- docs/architecture/database-architecture.md#cost-accounting.

CREATE OR REPLACE FUNCTION project_spend_usd(p_content_project_id UUID) RETURNS NUMERIC AS $$
  SELECT COALESCE(SUM(total_cost_usd), 0)
  FROM cost_events
  WHERE content_project_id = p_content_project_id;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION channel_month_spend_usd(
  p_channel_id UUID,
  p_month DATE DEFAULT date_trunc('month', now())::date
) RETURNS NUMERIC AS $$
  SELECT COALESCE(SUM(total_cost_usd), 0)
  FROM cost_events
  WHERE channel_id = p_channel_id
    AND occurred_at >= date_trunc('month', p_month)
    AND occurred_at < date_trunc('month', p_month) + INTERVAL '1 month';
$$ LANGUAGE sql STABLE;

-- Returns NULL when no per_video limit is configured for the channel
-- (distinct from 0, which would mean "no budget at all").
CREATE OR REPLACE FUNCTION project_budget_remaining_usd(p_content_project_id UUID) RETURNS NUMERIC AS $$
DECLARE
  v_channel_id UUID;
  v_limit NUMERIC;
BEGIN
  SELECT channel_id INTO v_channel_id FROM content_projects WHERE id = p_content_project_id;
  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION 'no content_project found with id %', p_content_project_id;
  END IF;

  SELECT amount_usd INTO v_limit FROM channel_budget_limits
    WHERE channel_id = v_channel_id AND limit_type = 'per_video' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;

  IF v_limit IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_limit - project_spend_usd(p_content_project_id);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION channel_month_budget_remaining_usd(
  p_channel_id UUID,
  p_month DATE DEFAULT date_trunc('month', now())::date
) RETURNS NUMERIC AS $$
DECLARE
  v_limit NUMERIC;
BEGIN
  SELECT amount_usd INTO v_limit FROM channel_budget_limits
    WHERE channel_id = p_channel_id AND limit_type = 'monthly_channel' AND enabled = true
    ORDER BY effective_from DESC LIMIT 1;

  IF v_limit IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_limit - channel_month_spend_usd(p_channel_id, p_month);
END;
$$ LANGUAGE plpgsql STABLE;

-- migrate:down

DROP FUNCTION IF EXISTS channel_month_budget_remaining_usd(UUID, DATE);
DROP FUNCTION IF EXISTS project_budget_remaining_usd(UUID);
DROP FUNCTION IF EXISTS channel_month_spend_usd(UUID, DATE);
DROP FUNCTION IF EXISTS project_spend_usd(UUID);
