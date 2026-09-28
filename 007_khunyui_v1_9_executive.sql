-- =====================================================================
-- KHUNYUI DATABASE V1.9 — apply on top of V1.8
-- Executive (platform admin) layer: a separate, read-only view over every shop.
--  * platform_admins: who may open the executive page (SQL editor only; the app cannot edit it)
--  * get_admin_overview(): today's numbers + menu health for every shop
--  * get_admin_history(): daily closings across shops
--  * get_admin_audit(): who changed what and when (with the person's email)
-- Nothing here changes what the shop owner or customers can do.
-- =====================================================================
BEGIN;

CREATE TABLE public.platform_admins (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  note        text NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL PRIVILEGES ON TABLE public.platform_admins FROM anon, authenticated;
ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
-- No policies on purpose: only the SQL editor (or the SECURITY DEFINER functions below) can read or change it.

CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admins AS pa
    WHERE pa.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.get_admin_overview()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  SELECT COALESCE(jsonb_agg(t.x ORDER BY t.x->>'name'), '[]'::jsonb)
    INTO v
  FROM (
    SELECT jsonb_build_object(
      'store_id', s.id,
      'name', s.name,
      'branch_name', s.branch_name,
      'is_active', s.is_active,
      'is_accepting_orders', ps.is_accepting_orders,
      'closed_for_date', ps.closed_for_date,
      'promptpay_set', ps.promptpay_id IS NOT NULL,
      'business_date', public.khunyui_business_date(s.id),
      'today', public.khunyui_day_summary(s.id, public.khunyui_business_date(s.id)),
      'dishes_total', (SELECT COUNT(*) FROM public.menu_items AS mi WHERE mi.store_id = s.id AND NOT mi.is_archived),
      'dishes_with_photo', (SELECT COUNT(*) FROM public.menu_items AS mi WHERE mi.store_id = s.id AND NOT mi.is_archived AND mi.image_path IS NOT NULL),
      'dishes_unavailable', (SELECT COUNT(*) FROM public.menu_items AS mi WHERE mi.store_id = s.id AND NOT mi.is_archived AND NOT mi.is_available),
      'owners', (SELECT COUNT(*) FROM public.store_members AS sm WHERE sm.store_id = s.id AND sm.is_active),
      'orders_all_time', (SELECT COUNT(*) FROM public.orders AS o WHERE o.store_id = s.id AND o.status <> 'cancelled'),
      'last_order_at', (SELECT MAX(o.created_at) FROM public.orders AS o WHERE o.store_id = s.id),
      'last_closing', (
        SELECT jsonb_build_object('business_date', dc.business_date, 'revision', dc.revision, 'closed_at', dc.closed_at)
        FROM public.daily_closings AS dc
        WHERE dc.store_id = s.id
        ORDER BY dc.closed_at DESC
        LIMIT 1
      )
    ) AS x
    FROM public.stores AS s
    JOIN public.store_public_settings AS ps ON ps.store_id = s.id
  ) AS t;

  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_history(p_days integer DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v jsonb;
  v_days integer := LEAST(GREATEST(COALESCE(p_days, 30), 1), 366);
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'store_id', d.store_id,
             'store_name', d.store_name,
             'business_date', d.business_date,
             'revision', d.revision,
             'closed_at', d.closed_at,
             'orders_total', d.summary->'orders_total',
             'visits_total', d.summary->'visits_total',
             'received_cash_satang', d.summary->'received_cash_satang',
             'received_qr_satang', d.summary->'received_qr_satang',
             'net_satang', d.summary->'net_after_completed_refunds_satang'
           )
           ORDER BY d.business_date DESC, d.store_name
         ), '[]'::jsonb)
    INTO v
  FROM (
    SELECT DISTINCT ON (dc.store_id, dc.business_date)
           dc.store_id, dc.business_date, dc.revision, dc.closed_at, dc.summary, s.name AS store_name
    FROM public.daily_closings AS dc
    JOIN public.stores AS s ON s.id = dc.store_id
    WHERE dc.business_date >= (now() AT TIME ZONE 'Asia/Bangkok')::date - v_days
    ORDER BY dc.store_id, dc.business_date, dc.revision DESC
  ) AS d;

  RETURN v;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_admin_audit(p_store_id uuid DEFAULT NULL, p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'admin_required';
  END IF;

  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'at', a.created_at,
             'store_name', s.name,
             'actor', CASE
                        WHEN u.email IS NOT NULL THEN u.email
                        WHEN a.actor_user_id IS NULL THEN 'ระบบ'
                        ELSE 'ลูกค้า'
                      END,
             'role', sm.role,
             'action', a.action,
             'entity_type', a.entity_type,
             'before', a.before_data,
             'after', a.after_data
           )
           ORDER BY a.created_at DESC
         ), '[]'::jsonb)
    INTO v
  FROM (
    SELECT al.*
    FROM public.audit_logs AS al
    WHERE p_store_id IS NULL OR al.store_id = p_store_id
    ORDER BY al.created_at DESC
    LIMIT v_limit
  ) AS a
  JOIN public.stores AS s ON s.id = a.store_id
  LEFT JOIN auth.users AS u ON u.id = a.actor_user_id
  LEFT JOIN public.store_members AS sm ON sm.store_id = a.store_id AND sm.user_id = a.actor_user_id;

  RETURN v;
END;
$$;

REVOKE EXECUTE ON FUNCTION
  public.is_platform_admin(),
  public.get_admin_overview(),
  public.get_admin_history(integer),
  public.get_admin_audit(uuid, integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_history(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_audit(uuid, integer) TO authenticated;

COMMIT;

-- ---------------------------------------------------------------------
-- ให้บัญชีของผู้ดูแลระบบเข้าหน้าผู้บริหารได้ (รันแยกหลังสร้างบัญชีอีเมลแล้ว แก้อีเมลให้ตรง):
--   INSERT INTO public.platform_admins (user_id, note)
--   SELECT id, 'ผู้ดูแลระบบ' FROM auth.users WHERE email = 'อีเมลของคุณ@example.com';
-- ---------------------------------------------------------------------
