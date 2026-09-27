-- ============================================================================
-- KHUNYUI DATABASE + SYSTEM LOGIC MASTER
-- Migration: 001_khunyui_core_v1_4.sql
-- Target: Supabase / PostgreSQL
-- Status: TESTED BASE V1.3 + V1.4 finance/refund corrections; rerun full test suite before production
--
-- SECURITY INTENT
--   1) Browser clients may SELECT only what RLS + explicit GRANT allow.
--   2) Browser clients do NOT INSERT/UPDATE/DELETE business tables directly.
--   3) All business writes go through whitelisted SECURITY DEFINER functions.
--   4) Anonymous Supabase Auth users are still PostgreSQL role authenticated.
--   5) store_members is admin-SQL-only: no browser write function is provided.
--   6) Realtime is receive-only for browser clients; database triggers publish.
--
-- MANUAL PROJECT SETTINGS (not configurable by this SQL migration)
--   - Enable Anonymous Sign-ins in Supabase Auth.
--   - Enable CAPTCHA (Cloudflare Turnstile or hCaptcha) for Anonymous Sign-in.
--   - Realtime: disable "Allow public access to channels".
--   - Client channels must use config.private = true.
--
-- V1 POLICY CHOICES
--   - Customer cancellation: only own order while status = 'new'.
--   - Owner cancellation: 'new', 'preparing', or 'ready'; cancel_reason required.
--   - Option price deltas cannot be negative in V1.
--   - Anonymous identity is intentionally device/browser-bound; if the identity
--     is lost, previous order-tracking access cannot be recovered automatically.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 01. EXTENSIONS
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- 02. DEFAULT PRIVILEGES — MUST PRECEDE OBJECT CREATION
-- Supabase projects may auto-grant new public objects to Data API roles.
-- Make exposure opt-in for objects created by role postgres in schema public.
-- ============================================================================

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE USAGE, SELECT ON SEQUENCES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

-- ============================================================================
-- 03. TABLES + CONSTRAINTS
-- ============================================================================

CREATE TABLE public.stores (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL CHECK (btrim(name) <> ''),
  branch_name   text NOT NULL CHECK (btrim(branch_name) <> ''),
  timezone      text NOT NULL DEFAULT 'Asia/Bangkok' CHECK (btrim(timezone) <> ''),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.store_members (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id      uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role          text NOT NULL CHECK (role IN ('owner', 'staff')),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, user_id)
);

CREATE TABLE public.store_public_settings (
  store_id                       uuid PRIMARY KEY REFERENCES public.stores(id) ON DELETE CASCADE,
  is_accepting_orders            boolean NOT NULL DEFAULT true,
  queue_prefix                   text NOT NULL DEFAULT 'A'
                                 CHECK (queue_prefix ~ '^[A-Z]{1,3}$'),
  max_new_orders_per_customer    integer NOT NULL DEFAULT 3
                                 CHECK (max_new_orders_per_customer BETWEEN 1 AND 20),
  max_order_lines                integer NOT NULL DEFAULT 30
                                 CHECK (max_order_lines BETWEEN 1 AND 100),
  max_quantity_per_item          integer NOT NULL DEFAULT 20
                                 CHECK (max_quantity_per_item BETWEEN 1 AND 100),
  max_total_quantity             integer NOT NULL DEFAULT 50
                                 CHECK (max_total_quantity BETWEEN 1 AND 500),
  updated_at                     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.store_owner_settings (
  store_id               uuid PRIMARY KEY REFERENCES public.stores(id) ON DELETE CASCADE,
  notify_new_order       boolean NOT NULL DEFAULT true,
  sound_new_order        boolean NOT NULL DEFAULT true,
  qr_confirmation_mode   text NOT NULL DEFAULT 'manual'
                          CHECK (qr_confirmation_mode IN ('manual', 'provider')),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.menu_categories (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id      uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  code          text NOT NULL CHECK (btrim(code) <> ''),
  name          text NOT NULL CHECK (btrim(name) <> ''),
  sort_order    integer NOT NULL DEFAULT 0,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, code)
);

CREATE TABLE public.menu_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id          uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  category_id       uuid NOT NULL REFERENCES public.menu_categories(id) ON DELETE RESTRICT,
  sku               text NOT NULL CHECK (btrim(sku) <> ''),
  name              text NOT NULL CHECK (btrim(name) <> ''),
  description       text NULL CHECK (description IS NULL OR char_length(description) <= 1000),
  price_satang      bigint NOT NULL CHECK (price_satang >= 0),
  image_path        text NULL CHECK (image_path IS NULL OR btrim(image_path) <> ''),
  is_available      boolean NOT NULL DEFAULT true,
  is_archived       boolean NOT NULL DEFAULT false,
  sort_order        integer NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, sku)
);

CREATE TABLE public.menu_option_groups (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id        uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  code            text NOT NULL CHECK (btrim(code) <> ''),
  name            text NOT NULL CHECK (btrim(name) <> ''),
  selection_type  text NOT NULL CHECK (selection_type IN ('single', 'multiple')),
  min_select      integer NOT NULL DEFAULT 0 CHECK (min_select >= 0),
  max_select      integer NOT NULL CHECK (max_select >= 1),
  is_active       boolean NOT NULL DEFAULT true,
  sort_order      integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, code),
  CHECK (max_select >= min_select),
  CHECK (selection_type <> 'single' OR max_select = 1)
);

CREATE TABLE public.menu_option_values (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  option_group_id     uuid NOT NULL REFERENCES public.menu_option_groups(id) ON DELETE CASCADE,
  code                text NOT NULL CHECK (btrim(code) <> ''),
  name                text NOT NULL CHECK (btrim(name) <> ''),
  price_delta_satang  bigint NOT NULL DEFAULT 0 CHECK (price_delta_satang >= 0),
  is_available        boolean NOT NULL DEFAULT true,
  sort_order          integer NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (option_group_id, code)
);

CREATE TABLE public.menu_item_option_groups (
  menu_item_id      uuid NOT NULL REFERENCES public.menu_items(id) ON DELETE CASCADE,
  option_group_id   uuid NOT NULL REFERENCES public.menu_option_groups(id) ON DELETE CASCADE,
  sort_order        integer NOT NULL DEFAULT 0,
  PRIMARY KEY (menu_item_id, option_group_id)
);

CREATE TABLE public.daily_queue_counters (
  store_id        uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  business_date   date NOT NULL,
  last_value      integer NOT NULL CHECK (last_value >= 1),
  PRIMARY KEY (store_id, business_date)
);

CREATE TABLE public.orders (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id              uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,

  -- Intentionally NOT NULL. It is the current auth.uid(), including Anonymous
  -- Supabase Auth identities. It is intentionally not FK-bound to auth.users so
  -- historical orders survive if an anonymous auth identity is later deleted.
  customer_user_id      uuid NOT NULL,

  client_request_id     uuid NOT NULL,
  business_date         date NOT NULL,
  queue_number          integer NOT NULL CHECK (queue_number >= 1),
  queue_code            text NOT NULL CHECK (btrim(queue_code) <> ''),

  fulfillment_type      text NOT NULL
                        CHECK (fulfillment_type IN ('dine_in', 'takeaway')),
  status                text NOT NULL DEFAULT 'new'
                        CHECK (status IN ('new', 'preparing', 'ready', 'completed', 'cancelled')),

  subtotal_satang       bigint NOT NULL CHECK (subtotal_satang >= 0),
  total_satang          bigint NOT NULL CHECK (total_satang >= 0),
  currency              text NOT NULL DEFAULT 'THB' CHECK (currency = 'THB'),

  customer_note         text NULL CHECK (customer_note IS NULL OR char_length(customer_note) <= 500),

  created_at            timestamptz NOT NULL DEFAULT now(),
  accepted_at           timestamptz NULL,
  ready_at              timestamptz NULL,
  completed_at          timestamptz NULL,

  cancelled_at          timestamptz NULL,
  cancelled_by          uuid NULL,
  cancel_source         text NULL
                        CHECK (cancel_source IS NULL OR cancel_source IN ('customer', 'owner', 'system')),
  cancel_reason         text NULL CHECK (cancel_reason IS NULL OR char_length(cancel_reason) <= 500),

  UNIQUE (store_id, business_date, queue_number),
  UNIQUE (store_id, customer_user_id, client_request_id),

  -- Owner-initiated cancellation must always include a nonblank reason.
  CHECK (
    cancel_source IS DISTINCT FROM 'owner'
    OR (cancel_reason IS NOT NULL AND btrim(cancel_reason) <> '')
  ),

  -- Cancellation metadata is coherent with status.
  CHECK (
    (status = 'cancelled' AND cancelled_at IS NOT NULL AND cancel_source IS NOT NULL)
    OR
    (status <> 'cancelled' AND cancelled_at IS NULL AND cancel_source IS NULL AND cancel_reason IS NULL)
  )
);

CREATE TABLE public.order_items (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id              uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  menu_item_id          uuid NOT NULL REFERENCES public.menu_items(id) ON DELETE RESTRICT,

  menu_sku_snapshot     text NOT NULL CHECK (btrim(menu_sku_snapshot) <> ''),
  menu_name_snapshot    text NOT NULL CHECK (btrim(menu_name_snapshot) <> ''),
  unit_price_satang     bigint NOT NULL CHECK (unit_price_satang >= 0),
  quantity              integer NOT NULL CHECK (quantity > 0),
  line_total_satang     bigint NOT NULL CHECK (line_total_satang >= 0),
  customer_note         text NULL CHECK (customer_note IS NULL OR char_length(customer_note) <= 300),
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.order_item_options (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id         uuid NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
  option_value_id       uuid NOT NULL REFERENCES public.menu_option_values(id) ON DELETE RESTRICT,
  option_name_snapshot  text NOT NULL CHECK (btrim(option_name_snapshot) <> ''),
  price_delta_satang    bigint NOT NULL DEFAULT 0 CHECK (price_delta_satang >= 0),
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_item_id, option_value_id)
);

CREATE TABLE public.payments (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id              uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  method                text NOT NULL CHECK (method IN ('cash', 'promptpay_qr', 'gateway')),
  status                text NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'confirmed', 'failed', 'void')),
  amount_satang         bigint NOT NULL CHECK (amount_satang >= 0),
  confirmation_mode     text NOT NULL
                        CHECK (confirmation_mode IN ('manual', 'provider')),
  provider              text NULL,
  provider_reference    text NULL,
  confirmed_by          uuid NULL,
  confirmed_at          timestamptz NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (status = 'confirmed' AND confirmed_at IS NOT NULL)
    OR status <> 'confirmed'
  )
);

CREATE UNIQUE INDEX payments_provider_reference_uniq
  ON public.payments (provider, provider_reference)
  WHERE provider_reference IS NOT NULL;

CREATE TABLE public.payment_refunds (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id            uuid NOT NULL REFERENCES public.payments(id) ON DELETE RESTRICT,
  amount_satang         bigint NOT NULL CHECK (amount_satang > 0),
  status                text NOT NULL DEFAULT 'required'
                        CHECK (status IN ('required', 'processing', 'completed', 'failed')),
  reason                text NOT NULL CHECK (btrim(reason) <> ''),
  handled_by            uuid NULL,
  provider_reference    text NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  completed_at          timestamptz NULL,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (status = 'completed' AND completed_at IS NOT NULL)
    OR status <> 'completed'
  )
);

CREATE TABLE public.order_status_history (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  from_status     text NULL
                  CHECK (from_status IS NULL OR from_status IN ('new', 'preparing', 'ready', 'completed', 'cancelled')),
  to_status       text NOT NULL
                  CHECK (to_status IN ('new', 'preparing', 'ready', 'completed', 'cancelled')),
  changed_by      uuid NULL,
  change_source   text NOT NULL
                  CHECK (change_source IN ('customer', 'owner_app', 'system')),
  note            text NULL CHECK (note IS NULL OR char_length(note) <= 500),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.audit_logs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id        uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  actor_user_id   uuid NULL,
  action          text NOT NULL CHECK (btrim(action) <> ''),
  entity_type     text NOT NULL CHECK (btrim(entity_type) <> ''),
  entity_id       uuid NULL,
  before_data     jsonb NULL,
  after_data      jsonb NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- 04. INDEXES
-- Unique constraints above already create their own indexes.
-- ============================================================================

CREATE INDEX store_members_user_store_idx
  ON public.store_members (user_id, store_id)
  WHERE is_active = true;

CREATE INDEX menu_items_store_category_idx
  ON public.menu_items (store_id, category_id, sort_order);

CREATE INDEX menu_items_store_availability_idx
  ON public.menu_items (store_id, is_available, is_archived, sort_order);

CREATE INDEX menu_option_groups_store_idx
  ON public.menu_option_groups (store_id, is_active, sort_order);

CREATE INDEX menu_option_values_group_idx
  ON public.menu_option_values (option_group_id, is_available, sort_order);

CREATE INDEX orders_store_date_created_idx
  ON public.orders (store_id, business_date, created_at DESC);

CREATE INDEX orders_store_status_created_idx
  ON public.orders (store_id, status, created_at DESC);

CREATE INDEX orders_customer_created_idx
  ON public.orders (customer_user_id, created_at DESC);

CREATE INDEX order_items_order_idx
  ON public.order_items (order_id);

CREATE INDEX order_item_options_order_item_idx
  ON public.order_item_options (order_item_id);

CREATE INDEX payments_order_status_idx
  ON public.payments (order_id, status);

CREATE INDEX refunds_payment_status_idx
  ON public.payment_refunds (payment_id, status);

CREATE INDEX order_history_order_created_idx
  ON public.order_status_history (order_id, created_at);

CREATE INDEX audit_logs_store_created_idx
  ON public.audit_logs (store_id, created_at DESC);

-- ============================================================================
-- 05. LOCK DOWN TABLE PRIVILEGES, THEN RE-GRANT READ ONLY WHERE NEEDED
-- Browser write access is intentionally absent on every business table.
-- ============================================================================

REVOKE ALL PRIVILEGES ON TABLE
  public.stores,
  public.store_members,
  public.store_public_settings,
  public.store_owner_settings,
  public.menu_categories,
  public.menu_items,
  public.menu_option_groups,
  public.menu_option_values,
  public.menu_item_option_groups,
  public.daily_queue_counters,
  public.orders,
  public.order_items,
  public.order_item_options,
  public.payments,
  public.payment_refunds,
  public.order_status_history,
  public.audit_logs
FROM anon, authenticated;

-- Read paths are explicit. No INSERT / UPDATE / DELETE grants are issued.
GRANT SELECT ON TABLE public.stores TO authenticated;
GRANT SELECT ON TABLE public.store_members TO authenticated;
GRANT SELECT ON TABLE public.store_public_settings TO authenticated;
GRANT SELECT ON TABLE public.store_owner_settings TO authenticated;
GRANT SELECT ON TABLE public.menu_categories TO authenticated;
GRANT SELECT ON TABLE public.menu_items TO authenticated;
GRANT SELECT ON TABLE public.menu_option_groups TO authenticated;
GRANT SELECT ON TABLE public.menu_option_values TO authenticated;
GRANT SELECT ON TABLE public.menu_item_option_groups TO authenticated;
GRANT SELECT ON TABLE public.orders TO authenticated;
GRANT SELECT ON TABLE public.order_items TO authenticated;
GRANT SELECT ON TABLE public.order_item_options TO authenticated;
GRANT SELECT ON TABLE public.order_status_history TO authenticated;

-- Payments expose only safe browser columns. Provider references and confirmer IDs
-- remain server-side/internal.
GRANT SELECT (
  id, order_id, method, status, amount_satang, confirmation_mode,
  confirmed_at, created_at, updated_at
) ON public.payments TO authenticated;

GRANT SELECT (
  id, payment_id, amount_satang, status, reason,
  created_at, completed_at, updated_at
) ON public.payment_refunds TO authenticated;

-- Intentionally NO browser privileges for:
--   daily_queue_counters, audit_logs
-- store_members is SELECT-own-only via RLS and has no browser write path.

-- ============================================================================
-- 06. ROW LEVEL SECURITY
-- ============================================================================

ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_public_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_owner_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_option_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_option_values ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_item_option_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_queue_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- store_members: authenticated users can only read their own membership rows.
-- No INSERT/UPDATE/DELETE policy exists.
CREATE POLICY khunyui_store_members_select_self
ON public.store_members
FOR SELECT TO authenticated
USING (user_id = (select auth.uid()));

-- Active stores are readable to customers. A member can also read their own store
-- even if it is temporarily inactive for maintenance/admin purposes.
CREATE POLICY khunyui_stores_select
ON public.stores
FOR SELECT TO authenticated
USING (
  is_active = true
  OR EXISTS (
    SELECT 1
    FROM public.store_members sm
    WHERE sm.store_id = stores.id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_store_public_settings_select
ON public.store_public_settings
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = store_public_settings.store_id
      AND s.is_active = true
  )
  OR EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = store_public_settings.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_store_owner_settings_select_member
ON public.store_owner_settings
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = store_owner_settings.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_menu_categories_select
ON public.menu_categories
FOR SELECT TO authenticated
USING (
  (
    is_active = true
    AND EXISTS (
      SELECT 1 FROM public.stores s
      WHERE s.id = menu_categories.store_id
        AND s.is_active = true
    )
  )
  OR EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = menu_categories.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_menu_items_select
ON public.menu_items
FOR SELECT TO authenticated
USING (
  (
    is_archived = false
    AND EXISTS (
      SELECT 1 FROM public.stores s
      WHERE s.id = menu_items.store_id
        AND s.is_active = true
    )
  )
  OR EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = menu_items.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_menu_option_groups_select
ON public.menu_option_groups
FOR SELECT TO authenticated
USING (
  (
    is_active = true
    AND EXISTS (
      SELECT 1 FROM public.stores s
      WHERE s.id = menu_option_groups.store_id
        AND s.is_active = true
    )
  )
  OR EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = menu_option_groups.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_menu_option_values_select
ON public.menu_option_values
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.menu_option_groups g
    JOIN public.stores s ON s.id = g.store_id
    WHERE g.id = menu_option_values.option_group_id
      AND g.is_active = true
      AND s.is_active = true
  )
  OR EXISTS (
    SELECT 1
    FROM public.menu_option_groups g
    JOIN public.store_members sm ON sm.store_id = g.store_id
    WHERE g.id = menu_option_values.option_group_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_menu_item_option_groups_select
ON public.menu_item_option_groups
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.menu_items mi
    JOIN public.stores s ON s.id = mi.store_id
    WHERE mi.id = menu_item_option_groups.menu_item_id
      AND mi.is_archived = false
      AND s.is_active = true
  )
  OR EXISTS (
    SELECT 1
    FROM public.menu_items mi
    JOIN public.store_members sm ON sm.store_id = mi.store_id
    WHERE mi.id = menu_item_option_groups.menu_item_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_orders_select_owner_or_customer
ON public.orders
FOR SELECT TO authenticated
USING (
  customer_user_id = (select auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = orders.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_order_items_select_parent_order
ON public.order_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_items.order_id
      AND (
        o.customer_user_id = (select auth.uid())
        OR EXISTS (
          SELECT 1 FROM public.store_members sm
          WHERE sm.store_id = o.store_id
            AND sm.user_id = (select auth.uid())
            AND sm.is_active = true
        )
      )
  )
);

CREATE POLICY khunyui_order_item_options_select_parent_order
ON public.order_item_options
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    WHERE oi.id = order_item_options.order_item_id
      AND (
        o.customer_user_id = (select auth.uid())
        OR EXISTS (
          SELECT 1 FROM public.store_members sm
          WHERE sm.store_id = o.store_id
            AND sm.user_id = (select auth.uid())
            AND sm.is_active = true
        )
      )
  )
);

CREATE POLICY khunyui_payments_select_parent_order
ON public.payments
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = payments.order_id
      AND (
        o.customer_user_id = (select auth.uid())
        OR EXISTS (
          SELECT 1 FROM public.store_members sm
          WHERE sm.store_id = o.store_id
            AND sm.user_id = (select auth.uid())
            AND sm.is_active = true
        )
      )
  )
);

CREATE POLICY khunyui_refunds_select_parent_order
ON public.payment_refunds
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.payments p
    JOIN public.orders o ON o.id = p.order_id
    WHERE p.id = payment_refunds.payment_id
      AND (
        o.customer_user_id = (select auth.uid())
        OR EXISTS (
          SELECT 1 FROM public.store_members sm
          WHERE sm.store_id = o.store_id
            AND sm.user_id = (select auth.uid())
            AND sm.is_active = true
        )
      )
  )
);

CREATE POLICY khunyui_order_history_select_parent_order
ON public.order_status_history
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_status_history.order_id
      AND (
        o.customer_user_id = (select auth.uid())
        OR EXISTS (
          SELECT 1 FROM public.store_members sm
          WHERE sm.store_id = o.store_id
            AND sm.user_id = (select auth.uid())
            AND sm.is_active = true
        )
      )
  )
);

-- No policies intentionally created for daily_queue_counters or audit_logs.
-- No write policies intentionally created on ANY public business table.

-- ============================================================================
-- 07. FUNCTIONS + TRIGGERS
-- ============================================================================

-- Generic updated_at helper. Trigger-only; no browser EXECUTE grant.
CREATE OR REPLACE FUNCTION public.khunyui_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER stores_set_updated_at
BEFORE UPDATE ON public.stores
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER store_public_settings_set_updated_at
BEFORE UPDATE ON public.store_public_settings
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER store_owner_settings_set_updated_at
BEFORE UPDATE ON public.store_owner_settings
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER menu_categories_set_updated_at
BEFORE UPDATE ON public.menu_categories
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER menu_items_set_updated_at
BEFORE UPDATE ON public.menu_items
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER menu_option_groups_set_updated_at
BEFORE UPDATE ON public.menu_option_groups
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER menu_option_values_set_updated_at
BEFORE UPDATE ON public.menu_option_values
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER payments_set_updated_at
BEFORE UPDATE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

CREATE TRIGGER payment_refunds_set_updated_at
BEFORE UPDATE ON public.payment_refunds
FOR EACH ROW EXECUTE FUNCTION public.khunyui_set_updated_at();

-- Audit helper: callable only by other SECURITY DEFINER functions.
CREATE OR REPLACE FUNCTION public.khunyui_write_audit_log(
  p_store_id uuid,
  p_actor_user_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_before_data jsonb,
  p_after_data jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.audit_logs (
    store_id, actor_user_id, action, entity_type, entity_id, before_data, after_data
  ) VALUES (
    p_store_id, p_actor_user_id, p_action, p_entity_type, p_entity_id, p_before_data, p_after_data
  );
END;
$$;

-- Cross-row refund cap enforcement.
-- Counts required/processing/completed refunds; failed refunds do not consume cap.
CREATE OR REPLACE FUNCTION public.khunyui_enforce_refund_cap()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payment_amount bigint;
  v_other_refunds  bigint;
BEGIN
  SELECT p.amount_satang
    INTO v_payment_amount
  FROM public.payments p
  WHERE p.id = NEW.payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment_not_found';
  END IF;

  SELECT COALESCE(SUM(r.amount_satang), 0)
    INTO v_other_refunds
  FROM public.payment_refunds r
  WHERE r.payment_id = NEW.payment_id
    AND r.status <> 'failed'
    AND (TG_OP = 'INSERT' OR r.id <> NEW.id);

  IF NEW.status <> 'failed'
     AND v_other_refunds + NEW.amount_satang > v_payment_amount THEN
    RAISE EXCEPTION 'refund_total_exceeds_payment';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER payment_refunds_enforce_cap
BEFORE INSERT OR UPDATE OF payment_id, amount_satang, status
ON public.payment_refunds
FOR EACH ROW EXECUTE FUNCTION public.khunyui_enforce_refund_cap();

-- --------------------------------------------------------------------------
-- create_order()
-- Only whitelisted write path for customers creating orders.
-- Browser supplies IDs/quantity/options; database reads authoritative prices.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_order(
  p_store_id uuid,
  p_fulfillment_type text,
  p_payment_method text,
  p_items jsonb,
  p_customer_note text,
  p_client_request_id uuid
)
RETURNS TABLE (
  order_id uuid,
  queue_code text,
  total_satang bigint,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid                   uuid := auth.uid();
  v_store_active          boolean;
  v_timezone              text;
  v_accepting             boolean;
  v_queue_prefix          text;
  v_qr_mode               text;
  v_max_new_orders        integer;
  v_max_order_lines       integer;
  v_max_quantity_per_item integer;
  v_max_total_quantity    integer;
  v_total_quantity        integer := 0;
  v_business_date         date;
  v_queue_number          integer;
  v_queue_code            text;
  v_order_id              uuid;
  v_total                 bigint := 0;
  v_existing              public.orders%ROWTYPE;
  v_item                  jsonb;
  v_option_ids            jsonb;
  v_menu_id               uuid;
  v_qty                   integer;
  v_item_note             text;
  v_menu_sku              text;
  v_menu_name             text;
  v_base_price            bigint;
  v_option_delta          bigint;
  v_line_total            bigint;
  v_selected_count        integer;
  v_distinct_count        integer;
  v_valid_count           integer;
  v_group                 record;
  v_group_selected        integer;
  v_order_item_id         uuid;
  v_option                record;
  v_confirmation_mode     text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication_required';
  END IF;

  IF p_client_request_id IS NULL THEN
    RAISE EXCEPTION 'client_request_id_required';
  END IF;

  IF p_fulfillment_type NOT IN ('dine_in', 'takeaway') THEN
    RAISE EXCEPTION 'invalid_fulfillment_type';
  END IF;

  IF p_payment_method NOT IN ('cash', 'promptpay_qr') THEN
    RAISE EXCEPTION 'payment_method_not_available_in_v1';
  END IF;

  IF p_customer_note IS NOT NULL AND char_length(p_customer_note) > 500 THEN
    RAISE EXCEPTION 'customer_note_too_long';
  END IF;

  IF p_items IS NULL
     OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required';
  END IF;

  -- Idempotency fast path: return only an order owned by the SAME auth user.
  SELECT o.*
    INTO v_existing
  FROM public.orders o
  WHERE o.store_id = p_store_id
    AND o.customer_user_id = v_uid
    AND o.client_request_id = p_client_request_id
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY
      SELECT v_existing.id, v_existing.queue_code,
             v_existing.total_satang, v_existing.status;
    RETURN;
  END IF;

  SELECT s.is_active, s.timezone,
         ps.is_accepting_orders, ps.queue_prefix,
         ps.max_new_orders_per_customer, ps.max_order_lines,
         ps.max_quantity_per_item, ps.max_total_quantity,
         os.qr_confirmation_mode
    INTO v_store_active, v_timezone, v_accepting, v_queue_prefix,
         v_max_new_orders, v_max_order_lines, v_max_quantity_per_item,
         v_max_total_quantity, v_qr_mode
  FROM public.stores s
  JOIN public.store_public_settings ps ON ps.store_id = s.id
  JOIN public.store_owner_settings os ON os.store_id = s.id
  WHERE s.id = p_store_id
  FOR SHARE OF s, ps, os;

  IF NOT FOUND OR v_store_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'store_unavailable';
  END IF;

  IF v_accepting IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'store_not_accepting_orders';
  END IF;

  IF jsonb_array_length(p_items) > v_max_order_lines THEN
    RAISE EXCEPTION 'too_many_order_lines';
  END IF;

  -- Serialize abuse-limit checks for this store + authenticated customer.
  -- This prevents concurrent create_order() calls from all passing the same count.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_store_id::text),
    pg_catalog.hashtext(v_uid::text)
  );

  IF (
    SELECT count(*)
    FROM public.orders o
    WHERE o.store_id = p_store_id
      AND o.customer_user_id = v_uid
      AND o.status = 'new'
  ) >= v_max_new_orders THEN
    RAISE EXCEPTION 'too_many_open_orders';
  END IF;

  v_business_date := (clock_timestamp() AT TIME ZONE v_timezone)::date;

  -- PASS 1: validate every line and calculate the authoritative total.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    BEGIN
      v_menu_id := (v_item->>'menu_item_id')::uuid;
      v_qty := (v_item->>'quantity')::integer;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'invalid_item_payload';
    END;

    v_item_note := NULLIF(btrim(v_item->>'customer_note'), '');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'invalid_quantity';
    END IF;
    IF v_qty > v_max_quantity_per_item THEN
      RAISE EXCEPTION 'quantity_per_item_limit_exceeded';
    END IF;
    v_total_quantity := v_total_quantity + v_qty;
    IF v_total_quantity > v_max_total_quantity THEN
      RAISE EXCEPTION 'total_quantity_limit_exceeded';
    END IF;
    IF v_item_note IS NOT NULL AND char_length(v_item_note) > 300 THEN
      RAISE EXCEPTION 'item_note_too_long';
    END IF;

    SELECT mi.sku, mi.name, mi.price_satang
      INTO v_menu_sku, v_menu_name, v_base_price
    FROM public.menu_items mi
    JOIN public.menu_categories mc ON mc.id = mi.category_id
    WHERE mi.id = v_menu_id
      AND mi.store_id = p_store_id
      AND mi.is_archived = false
      AND mi.is_available = true
      AND mc.is_active = true
    FOR SHARE OF mi;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'menu_item_unavailable:%', v_menu_id;
    END IF;

    v_option_ids := COALESCE(v_item->'option_value_ids', '[]'::jsonb);
    IF jsonb_typeof(v_option_ids) <> 'array' THEN
      RAISE EXCEPTION 'option_value_ids_must_be_array';
    END IF;

    v_selected_count := jsonb_array_length(v_option_ids);

    SELECT COUNT(DISTINCT x.value)
      INTO v_distinct_count
    FROM jsonb_array_elements_text(v_option_ids) AS x(value);

    IF v_distinct_count <> v_selected_count THEN
      RAISE EXCEPTION 'duplicate_option_value';
    END IF;

    -- Lock selected option rows so price/availability cannot change between
    -- validation/total calculation and snapshot insertion in this transaction.
    PERFORM ov.id
    FROM (
      SELECT x.value::uuid AS option_id
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    ) selected
    JOIN public.menu_option_values ov ON ov.id = selected.option_id
    JOIN public.menu_option_groups og ON og.id = ov.option_group_id
    JOIN public.menu_item_option_groups miog
      ON miog.option_group_id = og.id
     AND miog.menu_item_id = v_menu_id
    WHERE ov.is_available = true
      AND og.is_active = true
      AND og.store_id = p_store_id
    FOR SHARE OF ov, og;

    SELECT COUNT(*), COALESCE(SUM(ov.price_delta_satang), 0)
      INTO v_valid_count, v_option_delta
    FROM (
      SELECT x.value::uuid AS option_id
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    ) selected
    JOIN public.menu_option_values ov ON ov.id = selected.option_id
    JOIN public.menu_option_groups og ON og.id = ov.option_group_id
    JOIN public.menu_item_option_groups miog
      ON miog.option_group_id = og.id
     AND miog.menu_item_id = v_menu_id
    WHERE ov.is_available = true
      AND og.is_active = true
      AND og.store_id = p_store_id;

    IF v_valid_count <> v_selected_count THEN
      RAISE EXCEPTION 'invalid_or_unavailable_option';
    END IF;

    -- Every linked group must satisfy min/max selection rules.
    FOR v_group IN
      SELECT og.id, og.min_select, og.max_select
      FROM public.menu_item_option_groups miog
      JOIN public.menu_option_groups og ON og.id = miog.option_group_id
      WHERE miog.menu_item_id = v_menu_id
        AND og.is_active = true
    LOOP
      SELECT COUNT(*)
        INTO v_group_selected
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
      JOIN public.menu_option_values ov ON ov.id = x.value::uuid
      WHERE ov.option_group_id = v_group.id;

      IF v_group_selected < v_group.min_select
         OR v_group_selected > v_group.max_select THEN
        RAISE EXCEPTION 'option_selection_out_of_range';
      END IF;
    END LOOP;

    v_line_total := (v_base_price + v_option_delta) * v_qty;
    IF v_line_total < 0 THEN
      RAISE EXCEPTION 'negative_line_total';
    END IF;

    v_total := v_total + v_line_total;
  END LOOP;

  -- Atomic queue allocation + order insert. If a concurrent duplicate request
  -- wins the idempotency UNIQUE race, this subtransaction rolls back its queue
  -- increment and returns the already-created order belonging to the same user.
  BEGIN
    INSERT INTO public.daily_queue_counters (store_id, business_date, last_value)
    VALUES (p_store_id, v_business_date, 1)
    ON CONFLICT (store_id, business_date)
    DO UPDATE SET last_value = public.daily_queue_counters.last_value + 1
    RETURNING last_value INTO v_queue_number;

    v_queue_code := v_queue_prefix ||
      CASE
        WHEN v_queue_number < 1000 THEN lpad(v_queue_number::text, 3, '0')
        ELSE v_queue_number::text
      END;

    INSERT INTO public.orders (
      store_id, customer_user_id, client_request_id,
      business_date, queue_number, queue_code,
      fulfillment_type, status,
      subtotal_satang, total_satang, currency,
      customer_note
    ) VALUES (
      p_store_id, v_uid, p_client_request_id,
      v_business_date, v_queue_number, v_queue_code,
      p_fulfillment_type, 'new',
      v_total, v_total, 'THB',
      NULLIF(btrim(p_customer_note), '')
    )
    RETURNING id INTO v_order_id;

  EXCEPTION WHEN unique_violation THEN
    SELECT o.*
      INTO v_existing
    FROM public.orders o
    WHERE o.store_id = p_store_id
      AND o.customer_user_id = v_uid
      AND o.client_request_id = p_client_request_id
    LIMIT 1;

    IF FOUND THEN
      RETURN QUERY
        SELECT v_existing.id, v_existing.queue_code,
               v_existing.total_satang, v_existing.status;
      RETURN;
    END IF;

    RAISE;
  END;

  -- PASS 2: create immutable order snapshots.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_menu_id := (v_item->>'menu_item_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_item_note := NULLIF(btrim(v_item->>'customer_note'), '');
    v_option_ids := COALESCE(v_item->'option_value_ids', '[]'::jsonb);

    SELECT mi.sku, mi.name, mi.price_satang
      INTO v_menu_sku, v_menu_name, v_base_price
    FROM public.menu_items mi
    WHERE mi.id = v_menu_id
      AND mi.store_id = p_store_id;

    SELECT COALESCE(SUM(ov.price_delta_satang), 0)
      INTO v_option_delta
    FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    JOIN public.menu_option_values ov ON ov.id = x.value::uuid;

    v_line_total := (v_base_price + v_option_delta) * v_qty;

    INSERT INTO public.order_items (
      order_id, menu_item_id,
      menu_sku_snapshot, menu_name_snapshot,
      unit_price_satang, quantity, line_total_satang,
      customer_note
    ) VALUES (
      v_order_id, v_menu_id,
      v_menu_sku, v_menu_name,
      v_base_price, v_qty, v_line_total,
      v_item_note
    )
    RETURNING id INTO v_order_item_id;

    FOR v_option IN
      SELECT ov.id, ov.name, ov.price_delta_satang
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
      JOIN public.menu_option_values ov ON ov.id = x.value::uuid
    LOOP
      INSERT INTO public.order_item_options (
        order_item_id, option_value_id,
        option_name_snapshot, price_delta_satang
      ) VALUES (
        v_order_item_id, v_option.id,
        v_option.name, v_option.price_delta_satang
      );
    END LOOP;
  END LOOP;

  v_confirmation_mode := CASE
    WHEN p_payment_method = 'promptpay_qr' THEN v_qr_mode
    ELSE 'manual'
  END;

  INSERT INTO public.payments (
    order_id, method, status, amount_satang, confirmation_mode
  ) VALUES (
    v_order_id, p_payment_method, 'pending', v_total, v_confirmation_mode
  );

  INSERT INTO public.order_status_history (
    order_id, from_status, to_status, changed_by, change_source
  ) VALUES (
    v_order_id, NULL, 'new', v_uid, 'customer'
  );

  RETURN QUERY
    SELECT v_order_id, v_queue_code, v_total, 'new'::text;
END;
$$;

-- --------------------------------------------------------------------------
-- advance_order_status(): owner/staff operational flow only.
-- new -> preparing -> ready -> completed. No skipping.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.advance_order_status(p_order_id uuid)
RETURNS TABLE (order_id uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_order       public.orders%ROWTYPE;
  v_new_status  text;
  v_now         timestamptz := now();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_order.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role IN ('owner', 'staff')
  ) THEN
    RAISE EXCEPTION 'owner_or_staff_required';
  END IF;

  v_new_status := CASE v_order.status
    WHEN 'new' THEN 'preparing'
    WHEN 'preparing' THEN 'ready'
    WHEN 'ready' THEN 'completed'
    ELSE NULL
  END;

  IF v_new_status IS NULL THEN
    RAISE EXCEPTION 'invalid_status_transition';
  END IF;

  UPDATE public.orders
  SET status = v_new_status,
      accepted_at = CASE WHEN v_new_status = 'preparing' THEN COALESCE(accepted_at, v_now) ELSE accepted_at END,
      ready_at = CASE WHEN v_new_status = 'ready' THEN COALESCE(ready_at, v_now) ELSE ready_at END,
      completed_at = CASE WHEN v_new_status = 'completed' THEN COALESCE(completed_at, v_now) ELSE completed_at END
  WHERE id = p_order_id;

  INSERT INTO public.order_status_history (
    order_id, from_status, to_status, changed_by, change_source
  ) VALUES (
    p_order_id, v_order.status, v_new_status, v_uid, 'owner_app'
  );

  PERFORM public.khunyui_write_audit_log(
    v_order.store_id, v_uid, 'advance_order_status', 'order', p_order_id,
    jsonb_build_object('status', v_order.status),
    jsonb_build_object('status', v_new_status)
  );

  RETURN QUERY SELECT p_order_id, v_new_status;
END;
$$;

-- --------------------------------------------------------------------------
-- confirm_payment(): owner only. Payment state remains separate from food state.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_payment(p_order_id uuid)
RETURNS TABLE (payment_id uuid, status text, confirmed_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_store_id uuid;
  v_order_status text;
  v_payment  public.payments%ROWTYPE;
  v_now      timestamptz := now();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT o.store_id, o.status
    INTO v_store_id, v_order_status
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;
  IF v_order_status = 'cancelled' THEN RAISE EXCEPTION 'cannot_confirm_cancelled_order'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  SELECT p.* INTO v_payment
  FROM public.payments p
  WHERE p.order_id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'payment_not_found'; END IF;

  IF v_payment.status = 'confirmed' THEN
    RETURN QUERY SELECT v_payment.id, v_payment.status, v_payment.confirmed_at;
    RETURN;
  END IF;

  IF v_payment.status <> 'pending' THEN
    RAISE EXCEPTION 'payment_not_pending';
  END IF;

  UPDATE public.payments
  SET status = 'confirmed',
      confirmed_by = v_uid,
      confirmed_at = v_now
  WHERE id = v_payment.id;

  PERFORM public.khunyui_write_audit_log(
    v_store_id, v_uid, 'confirm_payment', 'payment', v_payment.id,
    jsonb_build_object('status', v_payment.status),
    jsonb_build_object('status', 'confirmed', 'confirmed_at', v_now)
  );

  RETURN QUERY SELECT v_payment.id, 'confirmed'::text, v_now;
END;
$$;

-- --------------------------------------------------------------------------
-- cancel_order():
--   Customer: own order + status=new only.
--   Owner: new/preparing/ready + mandatory cancel_reason.
--   Confirmed payment -> creates refund row for remaining refundable amount.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_cancel_reason text DEFAULT NULL
)
RETURNS TABLE (order_id uuid, status text, refund_required boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid              uuid := auth.uid();
  v_order            public.orders%ROWTYPE;
  v_is_owner         boolean := false;
  v_cancel_source    text;
  v_reason           text := NULLIF(btrim(p_cancel_reason), '');
  v_payment          public.payments%ROWTYPE;
  v_existing_refunds bigint := 0;
  v_refund_amount    bigint := 0;
  v_refund_required  boolean := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;
  IF v_order.status = 'cancelled' THEN
    RETURN QUERY SELECT p_order_id, 'cancelled'::text, false;
    RETURN;
  END IF;
  IF v_order.status = 'completed' THEN
    RAISE EXCEPTION 'completed_order_cannot_be_cancelled';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_order.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) INTO v_is_owner;

  IF v_is_owner THEN
    IF v_order.status NOT IN ('new', 'preparing', 'ready') THEN
      RAISE EXCEPTION 'owner_cannot_cancel_from_this_status';
    END IF;
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'cancel_reason_required_for_owner';
    END IF;
    v_cancel_source := 'owner';
  ELSE
    IF v_order.customer_user_id <> v_uid THEN
      RAISE EXCEPTION 'not_order_owner';
    END IF;
    IF v_order.status <> 'new' THEN
      RAISE EXCEPTION 'customer_can_only_cancel_new_order';
    END IF;
    v_cancel_source := 'customer';
  END IF;

  UPDATE public.orders
  SET status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = v_uid,
      cancel_source = v_cancel_source,
      cancel_reason = v_reason
  WHERE id = p_order_id;

  INSERT INTO public.order_status_history (
    order_id, from_status, to_status, changed_by, change_source, note
  ) VALUES (
    p_order_id, v_order.status, 'cancelled', v_uid,
    CASE WHEN v_is_owner THEN 'owner_app' ELSE 'customer' END,
    v_reason
  );

  SELECT p.* INTO v_payment
  FROM public.payments p
  WHERE p.order_id = p_order_id
  FOR UPDATE;

  IF FOUND AND v_payment.status = 'pending' THEN
    UPDATE public.payments p
    SET status = 'void',
        updated_at = now()
    WHERE p.id = v_payment.id;

    PERFORM public.khunyui_write_audit_log(
      v_order.store_id, v_uid, 'void_payment_on_cancel', 'payment', v_payment.id,
      jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'void')
    );
  END IF;

  IF FOUND AND v_payment.status = 'confirmed' THEN
    SELECT COALESCE(SUM(r.amount_satang), 0)
      INTO v_existing_refunds
    FROM public.payment_refunds r
    WHERE r.payment_id = v_payment.id
      AND r.status <> 'failed';

    v_refund_amount := v_payment.amount_satang - v_existing_refunds;

    IF v_refund_amount > 0 THEN
      INSERT INTO public.payment_refunds (
        payment_id, amount_satang, status, reason, handled_by
      ) VALUES (
        v_payment.id,
        v_refund_amount,
        'required',
        COALESCE(v_reason, 'order_cancelled'),
        CASE WHEN v_is_owner THEN v_uid ELSE NULL END
      );
      v_refund_required := true;
    END IF;
  END IF;

  PERFORM public.khunyui_write_audit_log(
    v_order.store_id, v_uid, 'cancel_order', 'order', p_order_id,
    jsonb_build_object('status', v_order.status),
    jsonb_build_object('status', 'cancelled', 'source', v_cancel_source, 'reason', v_reason)
  );

  RETURN QUERY SELECT p_order_id, 'cancelled'::text, v_refund_required;
END;
$$;

-- --------------------------------------------------------------------------
-- complete_refund(): owner-only manual refund completion.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_refund(
  p_refund_id uuid,
  p_provider_reference text DEFAULT NULL
)
RETURNS TABLE (refund_id uuid, status text, completed_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_refund    public.payment_refunds%ROWTYPE;
  v_payment   public.payments%ROWTYPE;
  v_order     public.orders%ROWTYPE;
  v_now       timestamptz := now();
  v_reference text := NULLIF(btrim(p_provider_reference), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication_required';
  END IF;

  SELECT r.*
    INTO v_refund
  FROM public.payment_refunds AS r
  WHERE r.id = p_refund_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'refund_not_found';
  END IF;

  SELECT p.*
    INTO v_payment
  FROM public.payments AS p
  WHERE p.id = v_refund.payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment_not_found';
  END IF;

  SELECT o.*
    INTO v_order
  FROM public.orders AS o
  WHERE o.id = v_payment.order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.store_members AS sm
    WHERE sm.store_id = v_order.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  IF v_order.status <> 'cancelled' THEN
    RAISE EXCEPTION 'refund_requires_cancelled_order';
  END IF;

  IF v_payment.status <> 'confirmed' THEN
    RAISE EXCEPTION 'refund_requires_confirmed_payment';
  END IF;

  -- Idempotent re-submit: already completed returns the existing result.
  IF v_refund.status = 'completed' THEN
    RETURN QUERY
    SELECT v_refund.id, v_refund.status, v_refund.completed_at;
    RETURN;
  END IF;

  IF v_refund.status NOT IN ('required', 'processing') THEN
    RAISE EXCEPTION 'refund_not_completable';
  END IF;

  UPDATE public.payment_refunds AS r
  SET status = 'completed',
      handled_by = v_uid,
      provider_reference = COALESCE(v_reference, r.provider_reference),
      completed_at = v_now,
      updated_at = v_now
  WHERE r.id = v_refund.id;

  PERFORM public.khunyui_write_audit_log(
    v_order.store_id,
    v_uid,
    'complete_refund',
    'payment_refund',
    v_refund.id,
    jsonb_build_object(
      'status', v_refund.status,
      'handled_by', v_refund.handled_by,
      'completed_at', v_refund.completed_at,
      'provider_reference', v_refund.provider_reference
    ),
    jsonb_build_object(
      'status', 'completed',
      'handled_by', v_uid,
      'completed_at', v_now,
      'provider_reference', COALESCE(v_reference, v_refund.provider_reference)
    )
  );

  RETURN QUERY
  SELECT v_refund.id, 'completed'::text, v_now;
END;
$$;

-- --------------------------------------------------------------------------
-- Menu write functions — owner only.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_menu_availability(
  p_menu_item_id uuid,
  p_is_available boolean
)
RETURNS TABLE (menu_item_id uuid, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.menu_items%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT mi.* INTO v_item
  FROM public.menu_items mi
  WHERE mi.id = p_menu_item_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'menu_item_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_item.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  UPDATE public.menu_items
  SET is_available = p_is_available
  WHERE id = p_menu_item_id;

  PERFORM public.khunyui_write_audit_log(
    v_item.store_id, v_uid, 'set_menu_availability', 'menu_item', p_menu_item_id,
    jsonb_build_object('is_available', v_item.is_available),
    jsonb_build_object('is_available', p_is_available)
  );

  RETURN QUERY SELECT p_menu_item_id, p_is_available;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_menu_item(
  p_menu_item_id uuid,
  p_name text,
  p_description text,
  p_price_satang bigint,
  p_category_id uuid,
  p_image_path text,
  p_is_available boolean
)
RETURNS TABLE (
  menu_item_id uuid,
  name text,
  price_satang bigint,
  category_id uuid,
  image_path text,
  is_available boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.menu_items%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF p_price_satang IS NULL OR p_price_satang < 0 THEN RAISE EXCEPTION 'invalid_price'; END IF;
  IF p_description IS NOT NULL AND char_length(p_description) > 1000 THEN RAISE EXCEPTION 'description_too_long'; END IF;

  SELECT mi.* INTO v_item
  FROM public.menu_items mi
  WHERE mi.id = p_menu_item_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'menu_item_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_item.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.menu_categories mc
    WHERE mc.id = p_category_id
      AND mc.store_id = v_item.store_id
      AND mc.is_active = true
  ) THEN
    RAISE EXCEPTION 'invalid_category';
  END IF;

  UPDATE public.menu_items
  SET name = btrim(p_name),
      description = NULLIF(btrim(p_description), ''),
      price_satang = p_price_satang,
      category_id = p_category_id,
      image_path = NULLIF(btrim(p_image_path), ''),
      is_available = p_is_available
  WHERE id = p_menu_item_id;

  PERFORM public.khunyui_write_audit_log(
    v_item.store_id, v_uid, 'update_menu_item', 'menu_item', p_menu_item_id,
    jsonb_build_object(
      'name', v_item.name,
      'description', v_item.description,
      'price_satang', v_item.price_satang,
      'category_id', v_item.category_id,
      'image_path', v_item.image_path,
      'is_available', v_item.is_available
    ),
    jsonb_build_object(
      'name', btrim(p_name),
      'description', NULLIF(btrim(p_description), ''),
      'price_satang', p_price_satang,
      'category_id', p_category_id,
      'image_path', NULLIF(btrim(p_image_path), ''),
      'is_available', p_is_available
    )
  );

  RETURN QUERY
  SELECT mi.id, mi.name, mi.price_satang, mi.category_id, mi.image_path, mi.is_available
  FROM public.menu_items mi
  WHERE mi.id = p_menu_item_id;
END;
$$;

-- --------------------------------------------------------------------------
-- create_menu_item(): owner-only creation path for SCREEN 07.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_menu_item(
  p_store_id uuid,
  p_category_id uuid,
  p_sku text,
  p_name text,
  p_description text,
  p_price_satang bigint,
  p_image_path text DEFAULT NULL,
  p_is_available boolean DEFAULT true,
  p_sort_order integer DEFAULT 0
)
RETURNS TABLE (menu_item_id uuid, sku text, name text, price_satang bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;
  IF p_sku IS NULL OR btrim(p_sku) = '' THEN RAISE EXCEPTION 'sku_required'; END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF p_price_satang IS NULL OR p_price_satang < 0 THEN RAISE EXCEPTION 'invalid_price'; END IF;
  IF p_description IS NOT NULL AND char_length(p_description) > 1000 THEN RAISE EXCEPTION 'description_too_long'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.menu_categories mc
    WHERE mc.id = p_category_id
      AND mc.store_id = p_store_id
      AND mc.is_active = true
  ) THEN
    RAISE EXCEPTION 'invalid_category';
  END IF;

  INSERT INTO public.menu_items (
    store_id, category_id, sku, name, description, price_satang,
    image_path, is_available, is_archived, sort_order
  ) VALUES (
    p_store_id, p_category_id, btrim(p_sku), btrim(p_name),
    NULLIF(btrim(p_description), ''), p_price_satang,
    NULLIF(btrim(p_image_path), ''), p_is_available, false, p_sort_order
  )
  RETURNING id INTO v_id;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'create_menu_item', 'menu_item', v_id,
    NULL,
    jsonb_build_object('sku', btrim(p_sku), 'name', btrim(p_name), 'price_satang', p_price_satang)
  );

  RETURN QUERY
  SELECT mi.id, mi.sku, mi.name, mi.price_satang
  FROM public.menu_items mi
  WHERE mi.id = v_id;
END;
$$;

-- --------------------------------------------------------------------------
-- set_menu_archived(): owner-only archive/restore without deleting history.
-- Archiving also makes the item unavailable to new orders.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_menu_archived(
  p_menu_item_id uuid,
  p_is_archived boolean
)
RETURNS TABLE (menu_item_id uuid, is_archived boolean, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.menu_items%ROWTYPE;
  v_available boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT mi.* INTO v_item
  FROM public.menu_items mi
  WHERE mi.id = p_menu_item_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'menu_item_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_item.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  v_available := CASE WHEN p_is_archived THEN false ELSE v_item.is_available END;

  UPDATE public.menu_items AS mi
  SET is_archived = p_is_archived,
      is_available = v_available
  WHERE mi.id = p_menu_item_id;

  PERFORM public.khunyui_write_audit_log(
    v_item.store_id, v_uid, 'set_menu_archived', 'menu_item', p_menu_item_id,
    jsonb_build_object('is_archived', v_item.is_archived, 'is_available', v_item.is_available),
    jsonb_build_object('is_archived', p_is_archived, 'is_available', v_available)
  );

  RETURN QUERY SELECT p_menu_item_id, p_is_archived, v_available;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_menu_option_value_availability(
  p_option_value_id uuid,
  p_is_available boolean
)
RETURNS TABLE (option_value_id uuid, is_available boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_store_id uuid;
  v_old boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT og.store_id, ov.is_available
    INTO v_store_id, v_old
  FROM public.menu_option_values ov
  JOIN public.menu_option_groups og ON og.id = ov.option_group_id
  WHERE ov.id = p_option_value_id
  FOR UPDATE OF ov;

  IF NOT FOUND THEN RAISE EXCEPTION 'option_value_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  UPDATE public.menu_option_values
  SET is_available = p_is_available
  WHERE id = p_option_value_id;

  PERFORM public.khunyui_write_audit_log(
    v_store_id, v_uid, 'set_menu_option_value_availability', 'menu_option_value', p_option_value_id,
    jsonb_build_object('is_available', v_old),
    jsonb_build_object('is_available', p_is_available)
  );

  RETURN QUERY SELECT p_option_value_id, p_is_available;
END;
$$;

-- --------------------------------------------------------------------------
-- Store settings write functions — owner only.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_store_accepting_orders(
  p_store_id uuid,
  p_is_accepting_orders boolean
)
RETURNS TABLE (store_id uuid, is_accepting_orders boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  SELECT s.is_accepting_orders INTO v_old
  FROM public.store_public_settings s
  WHERE s.store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'store_settings_not_found'; END IF;

  UPDATE public.store_public_settings AS sps
  SET is_accepting_orders = p_is_accepting_orders
  WHERE sps.store_id = p_store_id;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'set_store_accepting_orders', 'store_public_settings', p_store_id,
    jsonb_build_object('is_accepting_orders', v_old),
    jsonb_build_object('is_accepting_orders', p_is_accepting_orders)
  );

  RETURN QUERY SELECT p_store_id, p_is_accepting_orders;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_store_owner_settings(
  p_store_id uuid,
  p_notify_new_order boolean,
  p_sound_new_order boolean
)
RETURNS TABLE (
  store_id uuid,
  notify_new_order boolean,
  sound_new_order boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_before public.store_owner_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  SELECT s.* INTO v_before
  FROM public.store_owner_settings s
  WHERE s.store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'owner_settings_not_found'; END IF;

  UPDATE public.store_owner_settings AS sos
  SET notify_new_order = p_notify_new_order,
      sound_new_order = p_sound_new_order
  WHERE sos.store_id = p_store_id;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'update_store_owner_settings', 'store_owner_settings', p_store_id,
    jsonb_build_object(
      'notify_new_order', v_before.notify_new_order,
      'sound_new_order', v_before.sound_new_order
    ),
    jsonb_build_object(
      'notify_new_order', p_notify_new_order,
      'sound_new_order', p_sound_new_order
    )
  );

  RETURN QUERY SELECT p_store_id, p_notify_new_order, p_sound_new_order;
END;
$$;

-- --------------------------------------------------------------------------
-- Dashboard / finance read functions — derived from source-of-truth tables.
-- No dashboard totals are stored separately.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_owner_dashboard_summary(
  p_store_id uuid,
  p_business_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_timezone text;
  v_date date;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
  ) THEN
    RAISE EXCEPTION 'store_member_required';
  END IF;

  SELECT s.timezone INTO v_timezone
  FROM public.stores AS s
  WHERE s.id = p_store_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'store_not_found'; END IF;

  v_date := COALESCE(
    p_business_date,
    (clock_timestamp() AT TIME ZONE v_timezone)::date
  );

  SELECT jsonb_build_object(
    'business_date', v_date,
    'orders_total', COUNT(*) FILTER (WHERE o.status <> 'cancelled'),
    'new_count', COUNT(*) FILTER (WHERE o.status = 'new'),
    'preparing_count', COUNT(*) FILTER (WHERE o.status = 'preparing'),
    'ready_count', COUNT(*) FILTER (WHERE o.status = 'ready'),
    'completed_count', COUNT(*) FILTER (WHERE o.status = 'completed'),
    'cancelled_count', COUNT(*) FILTER (WHERE o.status = 'cancelled'),
    'sales_total_satang', COALESCE(
      SUM(o.total_satang) FILTER (WHERE o.status <> 'cancelled'),
      0
    ),

    -- Dashboard received money: exclude cancelled orders.
    'confirmed_payment_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS op ON op.id = p.order_id
      WHERE op.store_id = p_store_id
        AND op.business_date = v_date
        AND op.status <> 'cancelled'
        AND p.status = 'confirmed'
    ), 0),

    -- Reconciliation: all confirmed receipts, including later-cancelled orders.
    'confirmed_payment_gross_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS op ON op.id = p.order_id
      WHERE op.store_id = p_store_id
        AND op.business_date = v_date
        AND p.status = 'confirmed'
    ), 0),

    'refund_pending_count', COALESCE((
      SELECT COUNT(*)
      FROM public.payment_refunds AS r
      JOIN public.payments AS p ON p.id = r.payment_id
      JOIN public.orders AS orf ON orf.id = p.order_id
      WHERE orf.store_id = p_store_id
        AND orf.business_date = v_date
        AND r.status IN ('required', 'processing')
    ), 0),

    'refund_pending_satang', COALESCE((
      SELECT SUM(r.amount_satang)
      FROM public.payment_refunds AS r
      JOIN public.payments AS p ON p.id = r.payment_id
      JOIN public.orders AS orf ON orf.id = p.order_id
      WHERE orf.store_id = p_store_id
        AND orf.business_date = v_date
        AND r.status IN ('required', 'processing')
    ), 0),

    'completed_refund_satang', COALESCE((
      SELECT SUM(r.amount_satang)
      FROM public.payment_refunds AS r
      JOIN public.payments AS p ON p.id = r.payment_id
      JOIN public.orders AS orf ON orf.id = p.order_id
      WHERE orf.store_id = p_store_id
        AND orf.business_date = v_date
        AND r.status = 'completed'
    ), 0),

    'net_confirmed_after_completed_refunds_satang',
      COALESCE((
        SELECT SUM(p.amount_satang)
        FROM public.payments AS p
        JOIN public.orders AS op ON op.id = p.order_id
        WHERE op.store_id = p_store_id
          AND op.business_date = v_date
          AND p.status = 'confirmed'
      ), 0)
      -
      COALESCE((
        SELECT SUM(r.amount_satang)
        FROM public.payment_refunds AS r
        JOIN public.payments AS p ON p.id = r.payment_id
        JOIN public.orders AS orf ON orf.id = p.order_id
        WHERE orf.store_id = p_store_id
          AND orf.business_date = v_date
          AND r.status = 'completed'
      ), 0)
  )
  INTO v_result
  FROM public.orders AS o
  WHERE o.store_id = p_store_id
    AND o.business_date = v_date;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_finance_summary(
  p_store_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF p_start_date IS NULL
     OR p_end_date IS NULL
     OR p_end_date < p_start_date THEN
    RAISE EXCEPTION 'invalid_date_range';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  SELECT jsonb_build_object(
    'start_date', p_start_date,
    'end_date', p_end_date,

    'orders_total', (
      SELECT COUNT(*)
      FROM public.orders AS o
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND o.status <> 'cancelled'
    ),

    'sales_total_satang', COALESCE((
      SELECT SUM(o.total_satang)
      FROM public.orders AS o
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND o.status <> 'cancelled'
    ), 0),

    -- Gross confirmed receipts by channel; refund obligations are shown separately.
    'cash_confirmed_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND p.method = 'cash'
        AND p.status = 'confirmed'
    ), 0),

    'qr_confirmed_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND p.method = 'promptpay_qr'
        AND p.status = 'confirmed'
    ), 0),

    'confirmed_payment_gross_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND p.status = 'confirmed'
    ), 0),

    -- Confirmed receipts attached to still-active/non-cancelled orders.
    'active_order_confirmed_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND o.status <> 'cancelled'
        AND p.status = 'confirmed'
    ), 0),

    'refund_pending_count', COALESCE((
      SELECT COUNT(*)
      FROM public.payment_refunds AS r
      JOIN public.payments AS p ON p.id = r.payment_id
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND r.status IN ('required', 'processing')
    ), 0),

    'refund_pending_satang', COALESCE((
      SELECT SUM(r.amount_satang)
      FROM public.payment_refunds AS r
      JOIN public.payments AS p ON p.id = r.payment_id
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND r.status IN ('required', 'processing')
    ), 0),

    'refund_completed_satang', COALESCE((
      SELECT SUM(r.amount_satang)
      FROM public.payment_refunds AS r
      JOIN public.payments AS p ON p.id = r.payment_id
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND r.status = 'completed'
    ), 0),

    'net_after_completed_refunds_satang',
      COALESCE((
        SELECT SUM(p.amount_satang)
        FROM public.payments AS p
        JOIN public.orders AS o ON o.id = p.order_id
        WHERE o.store_id = p_store_id
          AND o.business_date BETWEEN p_start_date AND p_end_date
          AND p.status = 'confirmed'
      ), 0)
      -
      COALESCE((
        SELECT SUM(r.amount_satang)
        FROM public.payment_refunds AS r
        JOIN public.payments AS p ON p.id = r.payment_id
        JOIN public.orders AS o ON o.id = p.order_id
        WHERE o.store_id = p_store_id
          AND o.business_date BETWEEN p_start_date AND p_end_date
          AND r.status = 'completed'
      ), 0),

    'cash_pending_count', (
      SELECT COUNT(*)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND o.status <> 'cancelled'
        AND p.method = 'cash'
        AND p.status = 'pending'
    ),

    'cash_pending_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND o.status <> 'cancelled'
        AND p.method = 'cash'
        AND p.status = 'pending'
    ), 0),

    'qr_pending_count', (
      SELECT COUNT(*)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND o.status <> 'cancelled'
        AND p.method = 'promptpay_qr'
        AND p.status = 'pending'
    ),

    'qr_pending_satang', COALESCE((
      SELECT SUM(p.amount_satang)
      FROM public.payments AS p
      JOIN public.orders AS o ON o.id = p.order_id
      WHERE o.store_id = p_store_id
        AND o.business_date BETWEEN p_start_date AND p_end_date
        AND o.status <> 'cancelled'
        AND p.method = 'promptpay_qr'
        AND p.status = 'pending'
    ), 0)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

-- --------------------------------------------------------------------------
-- Realtime trigger publishers.
-- Browser clients receive only. Payloads intentionally omit internal user IDs
-- and payment provider references.
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.khunyui_broadcast_order_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := jsonb_build_object(
    'order_id', NEW.id,
    'queue_code', NEW.queue_code,
    'status', NEW.status,
    'fulfillment_type', NEW.fulfillment_type,
    'total_satang', NEW.total_satang,
    'business_date', NEW.business_date,
    'created_at', NEW.created_at,
    'accepted_at', NEW.accepted_at,
    'ready_at', NEW.ready_at,
    'completed_at', NEW.completed_at,
    'cancelled_at', NEW.cancelled_at
  );

  PERFORM realtime.send(v_payload, 'order_changed', 'order:' || NEW.id::text, true);
  PERFORM realtime.send(v_payload, 'order_changed', 'store:' || NEW.store_id::text || ':orders', true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER orders_broadcast_change
AFTER INSERT OR UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_order_change();

CREATE OR REPLACE FUNCTION public.khunyui_broadcast_payment_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_store_id uuid;
  v_payload jsonb;
BEGIN
  SELECT o.store_id INTO v_store_id
  FROM public.orders o WHERE o.id = NEW.order_id;

  v_payload := jsonb_build_object(
    'payment_id', NEW.id,
    'order_id', NEW.order_id,
    'method', NEW.method,
    'status', NEW.status,
    'amount_satang', NEW.amount_satang,
    'confirmed_at', NEW.confirmed_at
  );

  PERFORM realtime.send(v_payload, 'payment_changed', 'order:' || NEW.order_id::text, true);
  PERFORM realtime.send(v_payload, 'payment_changed', 'store:' || v_store_id::text || ':orders', true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER payments_broadcast_change
AFTER INSERT OR UPDATE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_payment_change();

CREATE OR REPLACE FUNCTION public.khunyui_broadcast_refund_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_order_id uuid;
  v_store_id uuid;
  v_payload jsonb;
BEGIN
  SELECT p.order_id, o.store_id
    INTO v_order_id, v_store_id
  FROM public.payments p
  JOIN public.orders o ON o.id = p.order_id
  WHERE p.id = NEW.payment_id;

  v_payload := jsonb_build_object(
    'refund_id', NEW.id,
    'payment_id', NEW.payment_id,
    'order_id', v_order_id,
    'amount_satang', NEW.amount_satang,
    'status', NEW.status,
    'completed_at', NEW.completed_at
  );

  PERFORM realtime.send(v_payload, 'refund_changed', 'order:' || v_order_id::text, true);
  PERFORM realtime.send(v_payload, 'refund_changed', 'store:' || v_store_id::text || ':orders', true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER refunds_broadcast_change
AFTER INSERT OR UPDATE ON public.payment_refunds
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_refund_change();

CREATE OR REPLACE FUNCTION public.khunyui_broadcast_menu_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := jsonb_build_object(
    'menu_item_id', NEW.id,
    'category_id', NEW.category_id,
    'sku', NEW.sku,
    'name', NEW.name,
    'price_satang', NEW.price_satang,
    'image_path', NEW.image_path,
    'is_available', NEW.is_available,
    'is_archived', NEW.is_archived,
    'updated_at', NEW.updated_at
  );

  PERFORM realtime.send(v_payload, 'menu_changed', 'store:' || NEW.store_id::text || ':menu', true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER menu_items_broadcast_change
AFTER INSERT OR UPDATE ON public.menu_items
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_menu_change();

CREATE OR REPLACE FUNCTION public.khunyui_broadcast_option_value_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_store_id uuid;
  v_payload jsonb;
BEGIN
  SELECT og.store_id INTO v_store_id
  FROM public.menu_option_groups og
  WHERE og.id = NEW.option_group_id;

  v_payload := jsonb_build_object(
    'option_value_id', NEW.id,
    'option_group_id', NEW.option_group_id,
    'name', NEW.name,
    'price_delta_satang', NEW.price_delta_satang,
    'is_available', NEW.is_available,
    'updated_at', NEW.updated_at
  );

  PERFORM realtime.send(v_payload, 'menu_option_changed', 'store:' || v_store_id::text || ':menu', true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER menu_option_values_broadcast_change
AFTER INSERT OR UPDATE ON public.menu_option_values
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_option_value_change();

CREATE OR REPLACE FUNCTION public.khunyui_broadcast_store_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := jsonb_build_object(
    'store_id', NEW.store_id,
    'is_accepting_orders', NEW.is_accepting_orders,
    'updated_at', NEW.updated_at
  );

  PERFORM realtime.send(v_payload, 'store_status_changed', 'store:' || NEW.store_id::text || ':status', true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER store_status_broadcast_change
AFTER UPDATE OF is_accepting_orders ON public.store_public_settings
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_store_status_change();

-- ============================================================================
-- 08. FUNCTION PRIVILEGES — WHITELIST ONLY AFTER FUNCTIONS EXIST
-- ============================================================================

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

-- Customer + owner can create orders after authenticated/anonymous-auth sign-in.
GRANT EXECUTE ON FUNCTION public.create_order(uuid, text, text, jsonb, text, uuid)
TO authenticated;

-- cancel_order() contains its own customer-vs-owner authorization.
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, text)
TO authenticated;

-- Owner/staff/owner-only authorization is checked again inside each function.
GRANT EXECUTE ON FUNCTION public.advance_order_status(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.confirm_payment(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.complete_refund(uuid, text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.set_menu_availability(uuid, boolean)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.update_menu_item(uuid, text, text, bigint, uuid, text, boolean)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.create_menu_item(uuid, uuid, text, text, text, bigint, text, boolean, integer)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.set_menu_archived(uuid, boolean)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.set_menu_option_value_availability(uuid, boolean)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.set_store_accepting_orders(uuid, boolean)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.update_store_owner_settings(uuid, boolean, boolean)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_owner_dashboard_summary(uuid, date)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_finance_summary(uuid, date, date)
TO authenticated;

-- Trigger/helper functions intentionally receive NO browser EXECUTE grant.

-- ============================================================================
-- 08B. STORAGE RLS — MENU IMAGES
-- Bucket expected: menu-images (private bucket).
-- Object path convention: stores/{store_id}/menu/{filename}
-- Customers (including Anonymous Auth users) can read only.
-- Active owners can insert/update/delete objects for their own store path.
-- ============================================================================

DROP POLICY IF EXISTS khunyui_menu_images_read ON storage.objects;
CREATE POLICY khunyui_menu_images_read
ON storage.objects
FOR SELECT TO authenticated
USING (bucket_id = 'menu-images');

DROP POLICY IF EXISTS khunyui_menu_images_owner_insert ON storage.objects;
CREATE POLICY khunyui_menu_images_owner_insert
ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'menu-images'
  AND (storage.foldername(name))[1] = 'stores'
  AND (storage.foldername(name))[3] = 'menu'
  AND EXISTS (
    SELECT 1
    FROM public.store_members sm
    WHERE sm.store_id::text = (storage.foldername(name))[2]
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
      AND sm.role = 'owner'
  )
);

DROP POLICY IF EXISTS khunyui_menu_images_owner_update ON storage.objects;
CREATE POLICY khunyui_menu_images_owner_update
ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'menu-images'
  AND (storage.foldername(name))[1] = 'stores'
  AND (storage.foldername(name))[3] = 'menu'
  AND EXISTS (
    SELECT 1
    FROM public.store_members sm
    WHERE sm.store_id::text = (storage.foldername(name))[2]
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
      AND sm.role = 'owner'
  )
)
WITH CHECK (
  bucket_id = 'menu-images'
  AND (storage.foldername(name))[1] = 'stores'
  AND (storage.foldername(name))[3] = 'menu'
  AND EXISTS (
    SELECT 1
    FROM public.store_members sm
    WHERE sm.store_id::text = (storage.foldername(name))[2]
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
      AND sm.role = 'owner'
  )
);

DROP POLICY IF EXISTS khunyui_menu_images_owner_delete ON storage.objects;
CREATE POLICY khunyui_menu_images_owner_delete
ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'menu-images'
  AND (storage.foldername(name))[1] = 'stores'
  AND (storage.foldername(name))[3] = 'menu'
  AND EXISTS (
    SELECT 1
    FROM public.store_members sm
    WHERE sm.store_id::text = (storage.foldername(name))[2]
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
      AND sm.role = 'owner'
  )
);

-- ============================================================================
-- 09. REALTIME AUTHORIZATION — PRIVATE, RECEIVE-ONLY
-- IMPORTANT: also disable "Allow public access to channels" in Realtime settings.
-- No INSERT policy is created on realtime.messages.
-- ============================================================================

-- Supabase enables RLS on realtime.messages by default.
-- Intentionally create SELECT/receive authorization only.
-- There is NO INSERT policy, so browser clients are not authorized to send
-- Broadcast/Presence messages into KHUNYUI private channels.
DROP POLICY IF EXISTS khunyui_realtime_receive ON realtime.messages;

CREATE POLICY khunyui_realtime_receive
ON realtime.messages
FOR SELECT TO authenticated
USING (
  realtime.messages.extension = 'broadcast'
  AND (
  -- Customer order channel: order:{order_id}
  (
    split_part(realtime.topic(), ':', 1) = 'order'
    AND split_part(realtime.topic(), ':', 3) = ''
    AND EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id::text = split_part(realtime.topic(), ':', 2)
        AND o.customer_user_id = (select auth.uid())
    )
  )

  OR

  -- Owner/staff order channel: store:{store_id}:orders
  (
    split_part(realtime.topic(), ':', 1) = 'store'
    AND split_part(realtime.topic(), ':', 3) = 'orders'
    AND split_part(realtime.topic(), ':', 4) = ''
    AND EXISTS (
      SELECT 1
      FROM public.store_members sm
      WHERE sm.store_id::text = split_part(realtime.topic(), ':', 2)
        AND sm.user_id = (select auth.uid())
        AND sm.is_active = true
    )
  )

  OR

  -- Customer menu channel: store:{store_id}:menu
  -- Any authenticated identity (including Anonymous Auth) may RECEIVE updates
  -- for an active store, but cannot INSERT/send messages.
  (
    split_part(realtime.topic(), ':', 1) = 'store'
    AND split_part(realtime.topic(), ':', 3) = 'menu'
    AND split_part(realtime.topic(), ':', 4) = ''
    AND EXISTS (
      SELECT 1
      FROM public.stores s
      WHERE s.id::text = split_part(realtime.topic(), ':', 2)
        AND s.is_active = true
    )
  )

  OR

  -- Customer store-status channel: store:{store_id}:status
  (
    split_part(realtime.topic(), ':', 1) = 'store'
    AND split_part(realtime.topic(), ':', 3) = 'status'
    AND split_part(realtime.topic(), ':', 4) = ''
    AND EXISTS (
      SELECT 1
      FROM public.stores s
      WHERE s.id::text = split_part(realtime.topic(), ':', 2)
        AND s.is_active = true
    )
  )
  )
);

-- ============================================================================
-- 10. SEED — KHUNYUI STORE + SETTINGS + CORE CATEGORIES
-- Menu items and option values are intentionally seeded in a separate migration
-- after the authoritative MENU/PRICE master is loaded and verified.
-- ============================================================================

INSERT INTO public.stores (
  id, name, branch_name, timezone, is_active
) VALUES (
  '11111111-1111-4111-8111-111111111111'::uuid,
  'คุณยุ้ย ส้มตำครกระเบิด',
  'ตลาดสดคุณยิ้ม',
  'Asia/Bangkok',
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.store_public_settings (
  store_id, is_accepting_orders, queue_prefix
) VALUES (
  '11111111-1111-4111-8111-111111111111'::uuid,
  true,
  'A'
)
ON CONFLICT (store_id) DO NOTHING;

INSERT INTO public.store_owner_settings (
  store_id, notify_new_order, sound_new_order, qr_confirmation_mode
) VALUES (
  '11111111-1111-4111-8111-111111111111'::uuid,
  true,
  true,
  'manual'
)
ON CONFLICT (store_id) DO NOTHING;

INSERT INTO public.menu_categories (id, store_id, code, name, sort_order, is_active)
VALUES
  ('21111111-1111-4111-8111-111111111111'::uuid, '11111111-1111-4111-8111-111111111111'::uuid, 'SOMTAM',  'ส้มตำ', 10, true),
  ('21111111-1111-4111-8111-111111111112'::uuid, '11111111-1111-4111-8111-111111111111'::uuid, 'YUM',     'ยำ', 20, true),
  ('21111111-1111-4111-8111-111111111113'::uuid, '11111111-1111-4111-8111-111111111111'::uuid, 'GAOLAO',  'เกาเหลา', 30, true),
  ('21111111-1111-4111-8111-111111111114'::uuid, '11111111-1111-4111-8111-111111111111'::uuid, 'SPECIAL', 'พิเศษ', 40, true),
  ('21111111-1111-4111-8111-111111111115'::uuid, '11111111-1111-4111-8111-111111111111'::uuid, 'SIDES',   'เครื่องเคียง/ของเพิ่ม', 50, true)
ON CONFLICT (store_id, code) DO NOTHING;

-- IMPORTANT: store_members must be added only after the real owner Auth user exists.
-- Run from trusted admin SQL / migration only; there is intentionally no browser
-- INSERT privilege or owner-facing function that can add store_members.
-- Example (DO NOT run with a placeholder UUID):
--
-- INSERT INTO public.store_members (store_id, user_id, role, is_active)
-- VALUES (
--   '11111111-1111-4111-8111-111111111111'::uuid,
--   '<REAL_OWNER_AUTH_USER_UUID>'::uuid,
--   'owner',
--   true
-- );

COMMIT;

-- ============================================================================
-- POST-MIGRATION CHECKLIST (manual, outside transaction)
--   [ ] Auth: Anonymous Sign-ins enabled.
--   [ ] Auth: CAPTCHA enabled for Anonymous Sign-in.
--   [ ] Realtime: "Allow public access to channels" disabled.
--   [ ] Client Realtime channels use config.private = true.
--   [ ] Add real owner auth user to store_members using trusted admin SQL.
--   [ ] Next migration: seed authoritative menu + option values.
--   [ ] Test as Anonymous Auth user: cannot INSERT/UPDATE/DELETE public tables.
--   [ ] Create PRIVATE Storage bucket: menu-images.
--   [ ] Test Storage: customer read only; owner upload/update/delete only own store path.
--   [ ] Test order limits: max new orders, max lines, per-line qty, total qty.
--   [ ] Test cancelled pending payment becomes void; cancelled order cannot be confirmed.
--   [ ] Test cancelled confirmed payment creates refund required.
--   [ ] Test complete_refund(): owner succeeds; non-owner fails; second call is idempotent.
--   [ ] Test Dashboard exposes pending-refund totals and excludes cancelled order from confirmed_payment_satang.
--   [ ] Test Finance exposes pending PromptPay QR and pending/completed refund totals.
--   [ ] Test as Anonymous Auth user: can call create_order(), read only own order.
--   [ ] Test as Owner: cannot direct-update orders; can use whitelisted functions.
--   [ ] Test Realtime: browser cannot send Broadcast; can receive authorized topics.
-- ============================================================================

-- =====================================================================
-- KHUNYUI DATABASE V1.5
-- Apply on top of V1.4 (001_khunyui_core_v1_4.sql).
-- 1) Queue number reserved when the customer opens the menu (queue_sessions)
-- 2) Store settings: PromptPay ID, hold minutes, day cutoff, hero image, per-day reservation cap
-- 3) Recommended menu flag
-- 4) Daily closing snapshots (daily_closings) + richer dashboard summary
-- =====================================================================

BEGIN;

-- ---------- 1. settings + menu columns ----------
ALTER TABLE public.store_public_settings
  ADD COLUMN promptpay_id text NULL
    CHECK (promptpay_id IS NULL OR promptpay_id ~ '^(0[0-9]{9}|[0-9]{13}|[0-9]{15})$'),
  ADD COLUMN queue_hold_minutes integer NOT NULL DEFAULT 30
    CHECK (queue_hold_minutes BETWEEN 5 AND 240),
  ADD COLUMN day_cutoff time NOT NULL DEFAULT '00:00',
  ADD COLUMN hero_image_path text NULL
    CHECK (hero_image_path IS NULL OR btrim(hero_image_path) <> ''),
  ADD COLUMN max_queue_per_customer_per_day integer NOT NULL DEFAULT 10
    CHECK (max_queue_per_customer_per_day BETWEEN 1 AND 100);

ALTER TABLE public.menu_items
  ADD COLUMN is_recommended boolean NOT NULL DEFAULT false;

-- ---------- 2. queue sessions ----------
CREATE TABLE public.queue_sessions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id          uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  customer_user_id  uuid NOT NULL,
  business_date     date NOT NULL,
  queue_number      integer NOT NULL CHECK (queue_number >= 1),
  queue_code        text NOT NULL CHECK (btrim(queue_code) <> ''),
  status            text NOT NULL DEFAULT 'browsing'
                    CHECK (status IN ('browsing', 'ordered', 'not_ordered')),
  order_id          uuid NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  created_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz NOT NULL,
  ordered_at        timestamptz NULL,
  UNIQUE (store_id, business_date, queue_number),
  CHECK ((status = 'ordered') = (order_id IS NOT NULL))
);

CREATE INDEX queue_sessions_customer_idx
  ON public.queue_sessions (store_id, customer_user_id, business_date, status);
CREATE INDEX queue_sessions_store_date_idx
  ON public.queue_sessions (store_id, business_date);

-- ---------- 3. daily closings ----------
CREATE TABLE public.daily_closings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id        uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  business_date   date NOT NULL,
  revision        integer NOT NULL CHECK (revision >= 1),
  summary         jsonb NOT NULL,
  closed_by       uuid NOT NULL,
  closed_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (store_id, business_date, revision)
);

CREATE INDEX daily_closings_store_date_idx
  ON public.daily_closings (store_id, business_date DESC, revision DESC);

-- ---------- 4. grants + RLS ----------
REVOKE ALL PRIVILEGES ON TABLE public.queue_sessions, public.daily_closings FROM anon, authenticated;
GRANT SELECT ON TABLE public.queue_sessions TO authenticated;
GRANT SELECT ON TABLE public.daily_closings TO authenticated;

ALTER TABLE public.queue_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_closings ENABLE ROW LEVEL SECURITY;

CREATE POLICY khunyui_queue_sessions_select
ON public.queue_sessions
FOR SELECT TO authenticated
USING (
  customer_user_id = (select auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = queue_sessions.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

CREATE POLICY khunyui_daily_closings_select_member
ON public.daily_closings
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = daily_closings.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

-- ---------- 5. internal helpers (not callable from the browser) ----------
CREATE OR REPLACE FUNCTION public.khunyui_business_date(p_store_id uuid)
RETURNS date
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tz  text;
  v_cut time;
BEGIN
  SELECT s.timezone, ps.day_cutoff
    INTO v_tz, v_cut
  FROM public.stores AS s
  JOIN public.store_public_settings AS ps ON ps.store_id = s.id
  WHERE s.id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'store_not_found';
  END IF;

  -- Local shop time minus the cutoff: with cutoff 04:00, 02:30 still counts as yesterday.
  RETURN ((clock_timestamp() AT TIME ZONE v_tz) - (v_cut - time '00:00'))::date;
END;
$$;

CREATE OR REPLACE FUNCTION public.khunyui_allocate_queue_session(
  p_store_id uuid,
  p_uid uuid,
  p_business_date date
)
RETURNS TABLE (session_id uuid, queue_number integer, queue_code text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_prefix text;
  v_hold   integer;
  v_n      integer;
  v_code   text;
  v_exp    timestamptz;
  v_id     uuid;
BEGIN
  SELECT ps.queue_prefix, ps.queue_hold_minutes
    INTO v_prefix, v_hold
  FROM public.store_public_settings AS ps
  WHERE ps.store_id = p_store_id;

  INSERT INTO public.daily_queue_counters AS c (store_id, business_date, last_value)
  VALUES (p_store_id, p_business_date, 1)
  ON CONFLICT (store_id, business_date)
  DO UPDATE SET last_value = c.last_value + 1
  RETURNING c.last_value INTO v_n;

  v_code := v_prefix || CASE WHEN v_n < 1000 THEN lpad(v_n::text, 3, '0') ELSE v_n::text END;
  v_exp := now() + make_interval(mins => v_hold);

  INSERT INTO public.queue_sessions AS qs (
    store_id, customer_user_id, business_date, queue_number, queue_code, status, expires_at
  ) VALUES (
    p_store_id, p_uid, p_business_date, v_n, v_code, 'browsing', v_exp
  )
  RETURNING qs.id INTO v_id;

  RETURN QUERY SELECT v_id, v_n, v_code, v_exp;
END;
$$;

CREATE OR REPLACE FUNCTION public.khunyui_day_summary(p_store_id uuid, p_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v jsonb;
BEGIN
  SELECT jsonb_build_object(
    'business_date', p_date,

    'visits_total', (SELECT COUNT(*) FROM public.queue_sessions q
                     WHERE q.store_id = p_store_id AND q.business_date = p_date),
    'visits_ordered', (SELECT COUNT(*) FROM public.queue_sessions q
                       WHERE q.store_id = p_store_id AND q.business_date = p_date AND q.status = 'ordered'),
    'visits_not_ordered', (SELECT COUNT(*) FROM public.queue_sessions q
                           WHERE q.store_id = p_store_id AND q.business_date = p_date
                             AND (q.status = 'not_ordered' OR (q.status = 'browsing' AND q.expires_at <= now()))),
    'visits_browsing', (SELECT COUNT(*) FROM public.queue_sessions q
                        WHERE q.store_id = p_store_id AND q.business_date = p_date
                          AND q.status = 'browsing' AND q.expires_at > now()),

    'orders_total', COUNT(*) FILTER (WHERE o.status <> 'cancelled'),
    'new_count', COUNT(*) FILTER (WHERE o.status = 'new'),
    'preparing_count', COUNT(*) FILTER (WHERE o.status = 'preparing'),
    'ready_count', COUNT(*) FILTER (WHERE o.status = 'ready'),
    'completed_count', COUNT(*) FILTER (WHERE o.status = 'completed'),
    'cancelled_count', COUNT(*) FILTER (WHERE o.status = 'cancelled'),
    'dine_in_count', COUNT(*) FILTER (WHERE o.status <> 'cancelled' AND o.fulfillment_type = 'dine_in'),
    'takeaway_count', COUNT(*) FILTER (WHERE o.status <> 'cancelled' AND o.fulfillment_type = 'takeaway'),
    'sales_total_satang', COALESCE(SUM(o.total_satang) FILTER (WHERE o.status <> 'cancelled'), 0),

    'received_cash_satang', COALESCE((
      SELECT SUM(p.amount_satang) FROM public.payments p JOIN public.orders op ON op.id = p.order_id
      WHERE op.store_id = p_store_id AND op.business_date = p_date AND op.status <> 'cancelled'
        AND p.status = 'confirmed' AND p.method = 'cash'), 0),
    'received_qr_satang', COALESCE((
      SELECT SUM(p.amount_satang) FROM public.payments p JOIN public.orders op ON op.id = p.order_id
      WHERE op.store_id = p_store_id AND op.business_date = p_date AND op.status <> 'cancelled'
        AND p.status = 'confirmed' AND p.method = 'promptpay_qr'), 0),
    'pending_cash_satang', COALESCE((
      SELECT SUM(p.amount_satang) FROM public.payments p JOIN public.orders op ON op.id = p.order_id
      WHERE op.store_id = p_store_id AND op.business_date = p_date AND op.status <> 'cancelled'
        AND p.status = 'pending' AND p.method = 'cash'), 0),
    'pending_qr_satang', COALESCE((
      SELECT SUM(p.amount_satang) FROM public.payments p JOIN public.orders op ON op.id = p.order_id
      WHERE op.store_id = p_store_id AND op.business_date = p_date AND op.status <> 'cancelled'
        AND p.status = 'pending' AND p.method = 'promptpay_qr'), 0),

    'confirmed_payment_gross_satang', COALESCE((
      SELECT SUM(p.amount_satang) FROM public.payments p JOIN public.orders op ON op.id = p.order_id
      WHERE op.store_id = p_store_id AND op.business_date = p_date AND p.status = 'confirmed'), 0),
    'refund_pending_count', (
      SELECT COUNT(*) FROM public.payment_refunds r JOIN public.payments p ON p.id = r.payment_id
      JOIN public.orders orf ON orf.id = p.order_id
      WHERE orf.store_id = p_store_id AND orf.business_date = p_date AND r.status IN ('required', 'processing')),
    'refund_pending_satang', COALESCE((
      SELECT SUM(r.amount_satang) FROM public.payment_refunds r JOIN public.payments p ON p.id = r.payment_id
      JOIN public.orders orf ON orf.id = p.order_id
      WHERE orf.store_id = p_store_id AND orf.business_date = p_date AND r.status IN ('required', 'processing')), 0),
    'refund_completed_satang', COALESCE((
      SELECT SUM(r.amount_satang) FROM public.payment_refunds r JOIN public.payments p ON p.id = r.payment_id
      JOIN public.orders orf ON orf.id = p.order_id
      WHERE orf.store_id = p_store_id AND orf.business_date = p_date AND r.status = 'completed'), 0)
  )
  INTO v
  FROM public.orders AS o
  WHERE o.store_id = p_store_id
    AND o.business_date = p_date;

  v := v || jsonb_build_object(
    'received_total_satang', (v->>'received_cash_satang')::bigint + (v->>'received_qr_satang')::bigint,
    'net_after_completed_refunds_satang',
      (v->>'confirmed_payment_gross_satang')::bigint - (v->>'refund_completed_satang')::bigint
  );
  RETURN v;
END;
$$;

-- ---------- 6. customer: reserve a queue number when opening the menu ----------
CREATE OR REPLACE FUNCTION public.reserve_queue(p_store_id uuid)
RETURNS TABLE (session_id uuid, queue_code text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_active    boolean;
  v_accepting boolean;
  v_max       integer;
  v_date      date;
  v_count     integer;
  v_s         public.queue_sessions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT s.is_active, ps.is_accepting_orders, ps.max_queue_per_customer_per_day
    INTO v_active, v_accepting, v_max
  FROM public.stores AS s
  JOIN public.store_public_settings AS ps ON ps.store_id = s.id
  WHERE s.id = p_store_id;

  IF NOT FOUND OR v_active IS DISTINCT FROM true THEN RAISE EXCEPTION 'store_unavailable'; END IF;
  IF v_accepting IS DISTINCT FROM true THEN RAISE EXCEPTION 'store_not_accepting_orders'; END IF;

  v_date := public.khunyui_business_date(p_store_id);

  -- One reservation at a time per customer per store.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_store_id::text),
    pg_catalog.hashtext(v_uid::text)
  );

  UPDATE public.queue_sessions AS q
  SET status = 'not_ordered'
  WHERE q.store_id = p_store_id
    AND q.customer_user_id = v_uid
    AND q.status = 'browsing'
    AND q.expires_at <= now();

  -- Same phone coming back / refreshing keeps the same number (hold time counts from first scan).
  SELECT q.* INTO v_s
  FROM public.queue_sessions AS q
  WHERE q.store_id = p_store_id
    AND q.customer_user_id = v_uid
    AND q.business_date = v_date
    AND q.status = 'browsing'
  ORDER BY q.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY SELECT v_s.id, v_s.queue_code, v_s.expires_at;
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.queue_sessions AS q
  WHERE q.store_id = p_store_id
    AND q.customer_user_id = v_uid
    AND q.business_date = v_date;

  IF v_count >= v_max THEN RAISE EXCEPTION 'too_many_queue_reservations'; END IF;

  RETURN QUERY
  SELECT a.session_id, a.queue_code, a.expires_at
  FROM public.khunyui_allocate_queue_session(p_store_id, v_uid, v_date) AS a;
END;
$$;

-- ---------- 7. create_order: use the reserved queue number ----------
CREATE OR REPLACE FUNCTION public.create_order(
  p_store_id uuid,
  p_fulfillment_type text,
  p_payment_method text,
  p_items jsonb,
  p_customer_note text,
  p_client_request_id uuid
)
RETURNS TABLE (
  order_id uuid,
  queue_code text,
  total_satang bigint,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid                   uuid := auth.uid();
  v_store_active          boolean;
  v_timezone              text;
  v_accepting             boolean;
  v_queue_prefix          text;
  v_qr_mode               text;
  v_max_new_orders        integer;
  v_max_order_lines       integer;
  v_max_quantity_per_item integer;
  v_max_total_quantity    integer;
  v_total_quantity        integer := 0;
  v_business_date         date;
  v_queue_number          integer;
  v_queue_code            text;
  v_order_id              uuid;
  v_total                 bigint := 0;
  v_existing              public.orders%ROWTYPE;
  v_item                  jsonb;
  v_option_ids            jsonb;
  v_menu_id               uuid;
  v_qty                   integer;
  v_item_note             text;
  v_menu_sku              text;
  v_menu_name             text;
  v_base_price            bigint;
  v_option_delta          bigint;
  v_line_total            bigint;
  v_selected_count        integer;
  v_distinct_count        integer;
  v_valid_count           integer;
  v_group                 record;
  v_group_selected        integer;
  v_order_item_id         uuid;
  v_option                record;
  v_confirmation_mode     text;
  v_session_id            uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication_required';
  END IF;

  IF p_client_request_id IS NULL THEN
    RAISE EXCEPTION 'client_request_id_required';
  END IF;

  IF p_fulfillment_type NOT IN ('dine_in', 'takeaway') THEN
    RAISE EXCEPTION 'invalid_fulfillment_type';
  END IF;

  IF p_payment_method NOT IN ('cash', 'promptpay_qr') THEN
    RAISE EXCEPTION 'payment_method_not_available_in_v1';
  END IF;

  IF p_customer_note IS NOT NULL AND char_length(p_customer_note) > 500 THEN
    RAISE EXCEPTION 'customer_note_too_long';
  END IF;

  IF p_items IS NULL
     OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required';
  END IF;

  -- Idempotency fast path: return only an order owned by the SAME auth user.
  SELECT o.*
    INTO v_existing
  FROM public.orders o
  WHERE o.store_id = p_store_id
    AND o.customer_user_id = v_uid
    AND o.client_request_id = p_client_request_id
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY
      SELECT v_existing.id, v_existing.queue_code,
             v_existing.total_satang, v_existing.status;
    RETURN;
  END IF;

  SELECT s.is_active, s.timezone,
         ps.is_accepting_orders, ps.queue_prefix,
         ps.max_new_orders_per_customer, ps.max_order_lines,
         ps.max_quantity_per_item, ps.max_total_quantity,
         os.qr_confirmation_mode
    INTO v_store_active, v_timezone, v_accepting, v_queue_prefix,
         v_max_new_orders, v_max_order_lines, v_max_quantity_per_item,
         v_max_total_quantity, v_qr_mode
  FROM public.stores s
  JOIN public.store_public_settings ps ON ps.store_id = s.id
  JOIN public.store_owner_settings os ON os.store_id = s.id
  WHERE s.id = p_store_id
  FOR SHARE OF s, ps, os;

  IF NOT FOUND OR v_store_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'store_unavailable';
  END IF;

  IF v_accepting IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'store_not_accepting_orders';
  END IF;

  IF jsonb_array_length(p_items) > v_max_order_lines THEN
    RAISE EXCEPTION 'too_many_order_lines';
  END IF;

  -- Serialize abuse-limit checks for this store + authenticated customer.
  -- This prevents concurrent create_order() calls from all passing the same count.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_store_id::text),
    pg_catalog.hashtext(v_uid::text)
  );

  IF (
    SELECT count(*)
    FROM public.orders o
    WHERE o.store_id = p_store_id
      AND o.customer_user_id = v_uid
      AND o.status = 'new'
  ) >= v_max_new_orders THEN
    RAISE EXCEPTION 'too_many_open_orders';
  END IF;

  v_business_date := public.khunyui_business_date(p_store_id);

  -- PASS 1: validate every line and calculate the authoritative total.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    BEGIN
      v_menu_id := (v_item->>'menu_item_id')::uuid;
      v_qty := (v_item->>'quantity')::integer;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'invalid_item_payload';
    END;

    v_item_note := NULLIF(btrim(v_item->>'customer_note'), '');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'invalid_quantity';
    END IF;
    IF v_qty > v_max_quantity_per_item THEN
      RAISE EXCEPTION 'quantity_per_item_limit_exceeded';
    END IF;
    v_total_quantity := v_total_quantity + v_qty;
    IF v_total_quantity > v_max_total_quantity THEN
      RAISE EXCEPTION 'total_quantity_limit_exceeded';
    END IF;
    IF v_item_note IS NOT NULL AND char_length(v_item_note) > 300 THEN
      RAISE EXCEPTION 'item_note_too_long';
    END IF;

    SELECT mi.sku, mi.name, mi.price_satang
      INTO v_menu_sku, v_menu_name, v_base_price
    FROM public.menu_items mi
    JOIN public.menu_categories mc ON mc.id = mi.category_id
    WHERE mi.id = v_menu_id
      AND mi.store_id = p_store_id
      AND mi.is_archived = false
      AND mi.is_available = true
      AND mc.is_active = true
    FOR SHARE OF mi;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'menu_item_unavailable:%', v_menu_id;
    END IF;

    v_option_ids := COALESCE(v_item->'option_value_ids', '[]'::jsonb);
    IF jsonb_typeof(v_option_ids) <> 'array' THEN
      RAISE EXCEPTION 'option_value_ids_must_be_array';
    END IF;

    v_selected_count := jsonb_array_length(v_option_ids);

    SELECT COUNT(DISTINCT x.value)
      INTO v_distinct_count
    FROM jsonb_array_elements_text(v_option_ids) AS x(value);

    IF v_distinct_count <> v_selected_count THEN
      RAISE EXCEPTION 'duplicate_option_value';
    END IF;

    -- Lock selected option rows so price/availability cannot change between
    -- validation/total calculation and snapshot insertion in this transaction.
    PERFORM ov.id
    FROM (
      SELECT x.value::uuid AS option_id
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    ) selected
    JOIN public.menu_option_values ov ON ov.id = selected.option_id
    JOIN public.menu_option_groups og ON og.id = ov.option_group_id
    JOIN public.menu_item_option_groups miog
      ON miog.option_group_id = og.id
     AND miog.menu_item_id = v_menu_id
    WHERE ov.is_available = true
      AND og.is_active = true
      AND og.store_id = p_store_id
    FOR SHARE OF ov, og;

    SELECT COUNT(*), COALESCE(SUM(ov.price_delta_satang), 0)
      INTO v_valid_count, v_option_delta
    FROM (
      SELECT x.value::uuid AS option_id
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    ) selected
    JOIN public.menu_option_values ov ON ov.id = selected.option_id
    JOIN public.menu_option_groups og ON og.id = ov.option_group_id
    JOIN public.menu_item_option_groups miog
      ON miog.option_group_id = og.id
     AND miog.menu_item_id = v_menu_id
    WHERE ov.is_available = true
      AND og.is_active = true
      AND og.store_id = p_store_id;

    IF v_valid_count <> v_selected_count THEN
      RAISE EXCEPTION 'invalid_or_unavailable_option';
    END IF;

    -- Every linked group must satisfy min/max selection rules.
    FOR v_group IN
      SELECT og.id, og.min_select, og.max_select
      FROM public.menu_item_option_groups miog
      JOIN public.menu_option_groups og ON og.id = miog.option_group_id
      WHERE miog.menu_item_id = v_menu_id
        AND og.is_active = true
    LOOP
      SELECT COUNT(*)
        INTO v_group_selected
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
      JOIN public.menu_option_values ov ON ov.id = x.value::uuid
      WHERE ov.option_group_id = v_group.id;

      IF v_group_selected < v_group.min_select
         OR v_group_selected > v_group.max_select THEN
        RAISE EXCEPTION 'option_selection_out_of_range';
      END IF;
    END LOOP;

    v_line_total := (v_base_price + v_option_delta) * v_qty;
    IF v_line_total < 0 THEN
      RAISE EXCEPTION 'negative_line_total';
    END IF;

    v_total := v_total + v_line_total;
  END LOOP;

  -- Queue session use + order insert. If a concurrent duplicate request wins the
  -- idempotency UNIQUE race, this subtransaction rolls back and returns the
  -- already-created order belonging to the same user.
  BEGIN
    -- V1.5: the queue number was reserved when the customer opened the menu.
    UPDATE public.queue_sessions AS q
    SET status = 'not_ordered'
    WHERE q.store_id = p_store_id
      AND q.customer_user_id = v_uid
      AND q.status = 'browsing'
      AND q.expires_at <= now();

    SELECT q.id, q.queue_number, q.queue_code
      INTO v_session_id, v_queue_number, v_queue_code
    FROM public.queue_sessions AS q
    WHERE q.store_id = p_store_id
      AND q.customer_user_id = v_uid
      AND q.business_date = v_business_date
      AND q.status = 'browsing'
      AND q.expires_at > now()
    ORDER BY q.created_at DESC
    LIMIT 1
    FOR UPDATE;

    -- No live reservation (hold time passed, or menu never opened): take the next number now.
    IF NOT FOUND THEN
      SELECT a.session_id, a.queue_number, a.queue_code
        INTO v_session_id, v_queue_number, v_queue_code
      FROM public.khunyui_allocate_queue_session(p_store_id, v_uid, v_business_date) AS a;
    END IF;

    INSERT INTO public.orders (
      store_id, customer_user_id, client_request_id,
      business_date, queue_number, queue_code,
      fulfillment_type, status,
      subtotal_satang, total_satang, currency,
      customer_note
    ) VALUES (
      p_store_id, v_uid, p_client_request_id,
      v_business_date, v_queue_number, v_queue_code,
      p_fulfillment_type, 'new',
      v_total, v_total, 'THB',
      NULLIF(btrim(p_customer_note), '')
    )
    RETURNING id INTO v_order_id;

    UPDATE public.queue_sessions AS q
    SET status = 'ordered', order_id = v_order_id, ordered_at = now()
    WHERE q.id = v_session_id;

  EXCEPTION WHEN unique_violation THEN
    SELECT o.*
      INTO v_existing
    FROM public.orders o
    WHERE o.store_id = p_store_id
      AND o.customer_user_id = v_uid
      AND o.client_request_id = p_client_request_id
    LIMIT 1;

    IF FOUND THEN
      RETURN QUERY
        SELECT v_existing.id, v_existing.queue_code,
               v_existing.total_satang, v_existing.status;
      RETURN;
    END IF;

    RAISE;
  END;

  -- PASS 2: create immutable order snapshots.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_menu_id := (v_item->>'menu_item_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_item_note := NULLIF(btrim(v_item->>'customer_note'), '');
    v_option_ids := COALESCE(v_item->'option_value_ids', '[]'::jsonb);

    SELECT mi.sku, mi.name, mi.price_satang
      INTO v_menu_sku, v_menu_name, v_base_price
    FROM public.menu_items mi
    WHERE mi.id = v_menu_id
      AND mi.store_id = p_store_id;

    SELECT COALESCE(SUM(ov.price_delta_satang), 0)
      INTO v_option_delta
    FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    JOIN public.menu_option_values ov ON ov.id = x.value::uuid;

    v_line_total := (v_base_price + v_option_delta) * v_qty;

    INSERT INTO public.order_items (
      order_id, menu_item_id,
      menu_sku_snapshot, menu_name_snapshot,
      unit_price_satang, quantity, line_total_satang,
      customer_note
    ) VALUES (
      v_order_id, v_menu_id,
      v_menu_sku, v_menu_name,
      v_base_price, v_qty, v_line_total,
      v_item_note
    )
    RETURNING id INTO v_order_item_id;

    FOR v_option IN
      SELECT ov.id, ov.name, ov.price_delta_satang
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
      JOIN public.menu_option_values ov ON ov.id = x.value::uuid
    LOOP
      INSERT INTO public.order_item_options (
        order_item_id, option_value_id,
        option_name_snapshot, price_delta_satang
      ) VALUES (
        v_order_item_id, v_option.id,
        v_option.name, v_option.price_delta_satang
      );
    END LOOP;
  END LOOP;

  v_confirmation_mode := CASE
    WHEN p_payment_method = 'promptpay_qr' THEN v_qr_mode
    ELSE 'manual'
  END;

  INSERT INTO public.payments (
    order_id, method, status, amount_satang, confirmation_mode
  ) VALUES (
    v_order_id, p_payment_method, 'pending', v_total, v_confirmation_mode
  );

  INSERT INTO public.order_status_history (
    order_id, from_status, to_status, changed_by, change_source
  ) VALUES (
    v_order_id, NULL, 'new', v_uid, 'customer'
  );

  RETURN QUERY
    SELECT v_order_id, v_queue_code, v_total, 'new'::text;
END;
$$;

-- ---------- 8. owner: dashboard (same signature, richer data) ----------
CREATE OR REPLACE FUNCTION public.get_owner_dashboard_summary(
  p_store_id uuid,
  p_business_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
  ) THEN
    RAISE EXCEPTION 'store_member_required';
  END IF;

  RETURN public.khunyui_day_summary(
    p_store_id,
    COALESCE(p_business_date, public.khunyui_business_date(p_store_id))
  );
END;
$$;

-- ---------- 9. owner: close the business day ----------
CREATE OR REPLACE FUNCTION public.close_business_day(
  p_store_id uuid,
  p_business_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_today    date;
  v_date     date;
  v_rev      integer;
  v_summary  jsonb;
  v_id       uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  v_today := public.khunyui_business_date(p_store_id);
  v_date := COALESCE(p_business_date, v_today);
  IF v_date > v_today THEN RAISE EXCEPTION 'cannot_close_future_day'; END IF;

  -- Serialize closings per store so two taps cannot create the same revision.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('close:' || p_store_id::text));

  SELECT COALESCE(MAX(dc.revision), 0) + 1 INTO v_rev
  FROM public.daily_closings AS dc
  WHERE dc.store_id = p_store_id AND dc.business_date = v_date;

  v_summary := public.khunyui_day_summary(p_store_id, v_date);

  INSERT INTO public.daily_closings AS dc (store_id, business_date, revision, summary, closed_by)
  VALUES (p_store_id, v_date, v_rev, v_summary, v_uid)
  RETURNING dc.id INTO v_id;

  -- Closing today also stops new orders. Closing a past day changes nothing live.
  IF v_date = v_today THEN
    UPDATE public.store_public_settings AS sps
    SET is_accepting_orders = false
    WHERE sps.store_id = p_store_id;
  END IF;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'close_business_day', 'daily_closing', v_id,
    NULL, jsonb_build_object('business_date', v_date, 'revision', v_rev)
  );

  RETURN jsonb_build_object('closing_id', v_id, 'business_date', v_date, 'revision', v_rev, 'summary', v_summary);
END;
$$;

-- ---------- 10. owner: settings ----------
CREATE OR REPLACE FUNCTION public.set_store_settings(
  p_store_id uuid,
  p_promptpay_id text,
  p_queue_hold_minutes integer,
  p_day_cutoff time
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_before public.store_public_settings%ROWTYPE;
  v_pp     text := NULLIF(regexp_replace(COALESCE(p_promptpay_id, ''), '[^0-9]', '', 'g'), '');
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  IF v_pp IS NOT NULL AND v_pp !~ '^(0[0-9]{9}|[0-9]{13}|[0-9]{15})$' THEN
    RAISE EXCEPTION 'invalid_promptpay_id';
  END IF;
  IF p_queue_hold_minutes IS NULL OR p_queue_hold_minutes NOT BETWEEN 5 AND 240 THEN
    RAISE EXCEPTION 'invalid_queue_hold_minutes';
  END IF;
  IF p_day_cutoff IS NULL THEN RAISE EXCEPTION 'invalid_day_cutoff'; END IF;

  SELECT sps.* INTO v_before
  FROM public.store_public_settings AS sps
  WHERE sps.store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'store_settings_not_found'; END IF;

  UPDATE public.store_public_settings AS sps
  SET promptpay_id = v_pp,
      queue_hold_minutes = p_queue_hold_minutes,
      day_cutoff = p_day_cutoff
  WHERE sps.store_id = p_store_id;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'set_store_settings', 'store_public_settings', p_store_id,
    jsonb_build_object('promptpay_id', v_before.promptpay_id, 'queue_hold_minutes', v_before.queue_hold_minutes, 'day_cutoff', v_before.day_cutoff),
    jsonb_build_object('promptpay_id', v_pp, 'queue_hold_minutes', p_queue_hold_minutes, 'day_cutoff', p_day_cutoff)
  );

  RETURN jsonb_build_object('promptpay_id', v_pp, 'queue_hold_minutes', p_queue_hold_minutes, 'day_cutoff', p_day_cutoff);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_store_hero_image(p_store_id uuid, p_image_path text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_path text := NULLIF(btrim(p_image_path), '');
  v_old  text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  IF v_path IS NOT NULL AND v_path NOT LIKE 'stores/' || p_store_id::text || '/menu/%' THEN
    RAISE EXCEPTION 'invalid_image_path';
  END IF;

  SELECT sps.hero_image_path INTO v_old
  FROM public.store_public_settings AS sps
  WHERE sps.store_id = p_store_id
  FOR UPDATE;

  UPDATE public.store_public_settings AS sps
  SET hero_image_path = v_path
  WHERE sps.store_id = p_store_id;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'set_store_hero_image', 'store_public_settings', p_store_id,
    jsonb_build_object('hero_image_path', v_old), jsonb_build_object('hero_image_path', v_path)
  );

  RETURN jsonb_build_object('hero_image_path', v_path);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_menu_recommended(p_menu_item_id uuid, p_is_recommended boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_item public.menu_items%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT mi.* INTO v_item
  FROM public.menu_items AS mi
  WHERE mi.id = p_menu_item_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'menu_item_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = v_item.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  UPDATE public.menu_items AS mi
  SET is_recommended = COALESCE(p_is_recommended, false)
  WHERE mi.id = p_menu_item_id;

  PERFORM public.khunyui_write_audit_log(
    v_item.store_id, v_uid, 'set_menu_recommended', 'menu_item', p_menu_item_id,
    jsonb_build_object('is_recommended', v_item.is_recommended),
    jsonb_build_object('is_recommended', COALESCE(p_is_recommended, false))
  );

  RETURN jsonb_build_object('menu_item_id', p_menu_item_id, 'is_recommended', COALESCE(p_is_recommended, false));
END;
$$;

-- ---------- 11. execute grants (whitelist) ----------
REVOKE EXECUTE ON FUNCTION
  public.khunyui_business_date(uuid),
  public.khunyui_allocate_queue_session(uuid, uuid, date),
  public.khunyui_day_summary(uuid, date),
  public.reserve_queue(uuid),
  public.close_business_day(uuid, date),
  public.set_store_settings(uuid, text, integer, time),
  public.set_store_hero_image(uuid, text),
  public.set_menu_recommended(uuid, boolean)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.reserve_queue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_business_day(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_store_settings(uuid, text, integer, time) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_store_hero_image(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_menu_recommended(uuid, boolean) TO authenticated;

COMMIT;

-- =====================================================================
-- KHUNYUI DATABASE V1.6 — apply on top of V1.5
-- Completing an order (ready -> completed) also confirms a pending payment.
-- =====================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.advance_order_status(p_order_id uuid)
RETURNS TABLE (order_id uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid         uuid := auth.uid();
  v_order       public.orders%ROWTYPE;
  v_new_status  text;
  v_now         timestamptz := now();
  v_payment_id  uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = v_order.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role IN ('owner', 'staff')
  ) THEN
    RAISE EXCEPTION 'owner_or_staff_required';
  END IF;

  v_new_status := CASE v_order.status
    WHEN 'new' THEN 'preparing'
    WHEN 'preparing' THEN 'ready'
    WHEN 'ready' THEN 'completed'
    ELSE NULL
  END;

  IF v_new_status IS NULL THEN
    RAISE EXCEPTION 'invalid_status_transition';
  END IF;

  UPDATE public.orders
  SET status = v_new_status,
      accepted_at = CASE WHEN v_new_status = 'preparing' THEN COALESCE(accepted_at, v_now) ELSE accepted_at END,
      ready_at = CASE WHEN v_new_status = 'ready' THEN COALESCE(ready_at, v_now) ELSE ready_at END,
      completed_at = CASE WHEN v_new_status = 'completed' THEN COALESCE(completed_at, v_now) ELSE completed_at END
  WHERE id = p_order_id;

  -- V1.6: finishing an order means the shop has the money.
  -- A still-pending payment is confirmed in the same transaction, so the dashboard counts it.
  IF v_new_status = 'completed' THEN
    UPDATE public.payments AS p
    SET status = 'confirmed',
        confirmed_by = v_uid,
        confirmed_at = v_now
    WHERE p.order_id = p_order_id
      AND p.status = 'pending'
    RETURNING p.id INTO v_payment_id;

    IF v_payment_id IS NOT NULL THEN
      PERFORM public.khunyui_write_audit_log(
        v_order.store_id, v_uid, 'confirm_payment_on_complete', 'payment', v_payment_id,
        jsonb_build_object('status', 'pending'),
        jsonb_build_object('status', 'confirmed', 'confirmed_at', v_now)
      );
    END IF;
  END IF;

  INSERT INTO public.order_status_history (
    order_id, from_status, to_status, changed_by, change_source
  ) VALUES (
    p_order_id, v_order.status, v_new_status, v_uid, 'owner_app'
  );

  PERFORM public.khunyui_write_audit_log(
    v_order.store_id, v_uid, 'advance_order_status', 'order', p_order_id,
    jsonb_build_object('status', v_order.status),
    jsonb_build_object('status', v_new_status)
  );

  RETURN QUERY SELECT p_order_id, v_new_status;
END;
$$;

COMMIT;

-- =====================================================================
-- KHUNYUI DATABASE V1.7 — apply on top of V1.6
-- 1) "สรุปยอด" closes only that business day; the shop reopens by itself on the next day.
--    A manual close from the settings switch stays closed until the owner reopens it.
-- 2) Customers get a live update when the hero image or PromptPay number changes.
-- =====================================================================
BEGIN;

ALTER TABLE public.store_public_settings
  ADD COLUMN closed_for_date date NULL;

CREATE OR REPLACE FUNCTION public.khunyui_auto_reopen(p_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_today date := public.khunyui_business_date(p_store_id);
  v_rows  integer;
BEGIN
  UPDATE public.store_public_settings AS sps
  SET is_accepting_orders = true,
      closed_for_date = NULL
  WHERE sps.store_id = p_store_id
    AND sps.is_accepting_orders = false
    AND sps.closed_for_date IS NOT NULL
    AND sps.closed_for_date < v_today;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows > 0 THEN
    PERFORM public.khunyui_write_audit_log(
      p_store_id, NULL, 'auto_reopen_new_day', 'store_public_settings', p_store_id,
      NULL, jsonb_build_object('business_date', v_today)
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.reserve_queue(p_store_id uuid)
RETURNS TABLE (session_id uuid, queue_code text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_active    boolean;
  v_accepting boolean;
  v_max       integer;
  v_date      date;
  v_count     integer;
  v_s         public.queue_sessions%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  -- A day closed with "สรุปยอด" opens again automatically on the next business day.
  PERFORM public.khunyui_auto_reopen(p_store_id);

  SELECT s.is_active, ps.is_accepting_orders, ps.max_queue_per_customer_per_day
    INTO v_active, v_accepting, v_max
  FROM public.stores AS s
  JOIN public.store_public_settings AS ps ON ps.store_id = s.id
  WHERE s.id = p_store_id;

  IF NOT FOUND OR v_active IS DISTINCT FROM true THEN RAISE EXCEPTION 'store_unavailable'; END IF;
  IF v_accepting IS DISTINCT FROM true THEN RAISE EXCEPTION 'store_not_accepting_orders'; END IF;

  v_date := public.khunyui_business_date(p_store_id);

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_store_id::text),
    pg_catalog.hashtext(v_uid::text)
  );

  UPDATE public.queue_sessions AS q
  SET status = 'not_ordered'
  WHERE q.store_id = p_store_id
    AND q.customer_user_id = v_uid
    AND q.status = 'browsing'
    AND q.expires_at <= now();

  SELECT q.* INTO v_s
  FROM public.queue_sessions AS q
  WHERE q.store_id = p_store_id
    AND q.customer_user_id = v_uid
    AND q.business_date = v_date
    AND q.status = 'browsing'
  ORDER BY q.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY SELECT v_s.id, v_s.queue_code, v_s.expires_at;
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.queue_sessions AS q
  WHERE q.store_id = p_store_id
    AND q.customer_user_id = v_uid
    AND q.business_date = v_date;

  IF v_count >= v_max THEN RAISE EXCEPTION 'too_many_queue_reservations'; END IF;

  RETURN QUERY
  SELECT a.session_id, a.queue_code, a.expires_at
  FROM public.khunyui_allocate_queue_session(p_store_id, v_uid, v_date) AS a;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_owner_dashboard_summary(
  p_store_id uuid,
  p_business_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
  ) THEN
    RAISE EXCEPTION 'store_member_required';
  END IF;

  -- The owner opening the app on a new day also reopens a day closed with "สรุปยอด".
  PERFORM public.khunyui_auto_reopen(p_store_id);

  RETURN public.khunyui_day_summary(
    p_store_id,
    COALESCE(p_business_date, public.khunyui_business_date(p_store_id))
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.close_business_day(
  p_store_id uuid,
  p_business_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_today    date;
  v_date     date;
  v_rev      integer;
  v_summary  jsonb;
  v_id       uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  v_today := public.khunyui_business_date(p_store_id);
  v_date := COALESCE(p_business_date, v_today);
  IF v_date > v_today THEN RAISE EXCEPTION 'cannot_close_future_day'; END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('close:' || p_store_id::text));

  SELECT COALESCE(MAX(dc.revision), 0) + 1 INTO v_rev
  FROM public.daily_closings AS dc
  WHERE dc.store_id = p_store_id AND dc.business_date = v_date;

  v_summary := public.khunyui_day_summary(p_store_id, v_date);

  INSERT INTO public.daily_closings AS dc (store_id, business_date, revision, summary, closed_by)
  VALUES (p_store_id, v_date, v_rev, v_summary, v_uid)
  RETURNING dc.id INTO v_id;

  -- Closing today stops orders for the rest of today only; the shop reopens on the next business day.
  IF v_date = v_today THEN
    UPDATE public.store_public_settings AS sps
    SET is_accepting_orders = false,
        closed_for_date = v_date
    WHERE sps.store_id = p_store_id;
  END IF;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'close_business_day', 'daily_closing', v_id,
    NULL, jsonb_build_object('business_date', v_date, 'revision', v_rev)
  );

  RETURN jsonb_build_object('closing_id', v_id, 'business_date', v_date, 'revision', v_rev, 'summary', v_summary);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_store_accepting_orders(
  p_store_id uuid,
  p_is_accepting_orders boolean
)
RETURNS TABLE (store_id uuid, is_accepting_orders boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = p_store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  SELECT sps.is_accepting_orders INTO v_old
  FROM public.store_public_settings AS sps
  WHERE sps.store_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'store_settings_not_found'; END IF;

  -- A manual switch is the owner's decision: it clears any automatic next-day reopen.
  UPDATE public.store_public_settings AS sps
  SET is_accepting_orders = p_is_accepting_orders,
      closed_for_date = NULL
  WHERE sps.store_id = p_store_id;

  PERFORM public.khunyui_write_audit_log(
    p_store_id, v_uid, 'set_store_accepting_orders', 'store_public_settings', p_store_id,
    jsonb_build_object('is_accepting_orders', v_old),
    jsonb_build_object('is_accepting_orders', p_is_accepting_orders)
  );

  RETURN QUERY SELECT p_store_id, p_is_accepting_orders;
END;
$$;

DROP TRIGGER IF EXISTS store_status_broadcast_change ON public.store_public_settings;
CREATE TRIGGER store_status_broadcast_change
AFTER UPDATE OF is_accepting_orders, hero_image_path, promptpay_id ON public.store_public_settings
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_store_status_change();

REVOKE EXECUTE ON FUNCTION public.khunyui_auto_reopen(uuid) FROM PUBLIC, anon, authenticated;

COMMIT;

-- =====================================================================
-- KHUNYUI DATABASE V1.8 — apply on top of V1.7
-- 1) Spice levels as default options per category (น้อย · พอดี · เผ็ด · เผ็ดเว่อ, default พอดี)
-- 2) One-way shop → customer message box (customer_messages), live on the order channel
-- 3) Shop-cancelled orders can be re-ordered with the SAME queue number and queue position
-- 4) report_sold_out(): mark a dish sold out, suggest up to 3 similar dishes, cancel the order
-- =====================================================================
BEGIN;

-- ---------- 1. schema ----------
ALTER TABLE public.menu_option_values
  ADD COLUMN is_default boolean NOT NULL DEFAULT false;

ALTER TABLE public.menu_categories
  ADD COLUMN default_option_group_id uuid NULL REFERENCES public.menu_option_groups(id) ON DELETE SET NULL;

ALTER TABLE public.orders
  ADD COLUMN replaces_order_id uuid NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  ADD COLUMN queue_sort_at timestamptz NOT NULL DEFAULT now();

UPDATE public.orders SET queue_sort_at = created_at;

-- A cancelled order no longer holds its queue number, so a re-order can reuse it.
ALTER TABLE public.orders DROP CONSTRAINT orders_store_id_business_date_queue_number_key;
CREATE UNIQUE INDEX orders_active_queue_number_uniq
  ON public.orders (store_id, business_date, queue_number)
  WHERE status <> 'cancelled';

CREATE TABLE public.customer_messages (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id          uuid NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
  order_id          uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  customer_user_id  uuid NOT NULL,
  queue_code        text NOT NULL,
  kind              text NOT NULL CHECK (kind IN ('order_cancelled', 'sold_out')),
  title             text NOT NULL CHECK (btrim(title) <> '' AND char_length(title) <= 120),
  body              text NOT NULL CHECK (char_length(body) <= 500),
  sold_out_item_id  uuid NULL REFERENCES public.menu_items(id) ON DELETE SET NULL,
  suggestions       jsonb NOT NULL DEFAULT '[]'::jsonb
                    CHECK (jsonb_typeof(suggestions) = 'array' AND jsonb_array_length(suggestions) <= 3),
  created_by        uuid NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  read_at           timestamptz NULL
);

CREATE INDEX customer_messages_customer_idx ON public.customer_messages (customer_user_id, created_at DESC);
CREATE INDEX customer_messages_store_idx ON public.customer_messages (store_id, created_at DESC);
CREATE INDEX customer_messages_order_idx ON public.customer_messages (order_id);

REVOKE ALL PRIVILEGES ON TABLE public.customer_messages FROM anon, authenticated;
GRANT SELECT ON TABLE public.customer_messages TO authenticated;
ALTER TABLE public.customer_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY khunyui_customer_messages_select
ON public.customer_messages
FOR SELECT TO authenticated
USING (
  customer_user_id = (select auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.store_members sm
    WHERE sm.store_id = customer_messages.store_id
      AND sm.user_id = (select auth.uid())
      AND sm.is_active = true
  )
);

-- ---------- 2. triggers ----------
CREATE OR REPLACE FUNCTION public.khunyui_apply_category_options()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_group uuid;
BEGIN
  SELECT c.default_option_group_id INTO v_group
  FROM public.menu_categories AS c
  WHERE c.id = NEW.category_id;

  IF v_group IS NOT NULL THEN
    INSERT INTO public.menu_item_option_groups (menu_item_id, option_group_id)
    VALUES (NEW.id, v_group)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER menu_items_apply_category_options
AFTER INSERT OR UPDATE OF category_id ON public.menu_items
FOR EACH ROW EXECUTE FUNCTION public.khunyui_apply_category_options();

CREATE OR REPLACE FUNCTION public.khunyui_message_on_owner_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- report_sold_out() writes its own richer message first; do not send a second one.
  IF EXISTS (SELECT 1 FROM public.customer_messages AS m WHERE m.order_id = NEW.id AND m.kind = 'sold_out') THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.customer_messages (
    store_id, order_id, customer_user_id, queue_code, kind, title, body, created_by
  ) VALUES (
    NEW.store_id, NEW.id, NEW.customer_user_id, NEW.queue_code, 'order_cancelled',
    'ร้านยกเลิกออเดอร์ ' || NEW.queue_code,
    COALESCE(NEW.cancel_reason, ''),
    NEW.cancelled_by
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER orders_message_on_owner_cancel
AFTER UPDATE OF status ON public.orders
FOR EACH ROW
WHEN (NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' AND NEW.cancel_source = 'owner')
EXECUTE FUNCTION public.khunyui_message_on_owner_cancel();

CREATE OR REPLACE FUNCTION public.khunyui_broadcast_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := jsonb_build_object(
    'message_id', NEW.id, 'order_id', NEW.order_id, 'queue_code', NEW.queue_code,
    'kind', NEW.kind, 'title', NEW.title, 'created_at', NEW.created_at
  );
  PERFORM realtime.send(v_payload, 'message', 'order:' || NEW.order_id::text, true);
  PERFORM realtime.send(v_payload, 'message_sent', 'store:' || NEW.store_id::text || ':orders', true);
  RETURN NEW;
END;
$$;

CREATE TRIGGER customer_messages_broadcast
AFTER INSERT ON public.customer_messages
FOR EACH ROW EXECUTE FUNCTION public.khunyui_broadcast_message();

-- ---------- 3. customer: mark messages read ----------
CREATE OR REPLACE FUNCTION public.mark_messages_read(p_store_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_rows integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  UPDATE public.customer_messages AS m
  SET read_at = now()
  WHERE m.store_id = p_store_id
    AND m.customer_user_id = v_uid
    AND m.read_at IS NULL;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;

-- ---------- 4. owner: report a sold-out dish on an order ----------
CREATE OR REPLACE FUNCTION public.report_sold_out(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_suggestions uuid[] DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_order  public.orders%ROWTYPE;
  v_item   public.menu_items%ROWTYPE;
  v_sugg   uuid[] := COALESCE(p_suggestions, '{}');
  v_valid  integer;
  v_msg    uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;

  SELECT o.* INTO v_order
  FROM public.orders AS o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members AS sm
    WHERE sm.store_id = v_order.store_id
      AND sm.user_id = v_uid
      AND sm.is_active = true
      AND sm.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_required';
  END IF;

  IF v_order.status NOT IN ('new', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'order_not_open';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.order_items AS oi
    WHERE oi.order_id = p_order_id AND oi.menu_item_id = p_menu_item_id
  ) THEN
    RAISE EXCEPTION 'item_not_in_order';
  END IF;

  SELECT mi.* INTO v_item
  FROM public.menu_items AS mi
  WHERE mi.id = p_menu_item_id AND mi.store_id = v_order.store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'menu_item_not_found'; END IF;

  IF cardinality(v_sugg) > 3 THEN RAISE EXCEPTION 'too_many_suggestions'; END IF;

  SELECT COUNT(DISTINCT mi.id) INTO v_valid
  FROM public.menu_items AS mi
  WHERE mi.id = ANY (v_sugg)
    AND mi.store_id = v_order.store_id
    AND mi.id <> p_menu_item_id
    AND mi.is_available = true
    AND mi.is_archived = false;

  IF v_valid <> cardinality(ARRAY(SELECT DISTINCT unnest(v_sugg))) THEN
    RAISE EXCEPTION 'invalid_suggestion';
  END IF;

  -- The dish is gone for everyone, not just this order.
  UPDATE public.menu_items AS mi
  SET is_available = false
  WHERE mi.id = p_menu_item_id;

  PERFORM public.khunyui_write_audit_log(
    v_order.store_id, v_uid, 'report_sold_out', 'menu_item', p_menu_item_id,
    jsonb_build_object('is_available', v_item.is_available),
    jsonb_build_object('is_available', false, 'order_id', p_order_id)
  );

  -- Message first, so the cancel trigger knows not to send a second one.
  INSERT INTO public.customer_messages AS m (
    store_id, order_id, customer_user_id, queue_code, kind, title, body, sold_out_item_id, suggestions, created_by
  ) VALUES (
    v_order.store_id, v_order.id, v_order.customer_user_id, v_order.queue_code, 'sold_out',
    'ขออภัยค่ะ สินค้าหมดแล้ว',
    'ขออภัยค่ะ ' || v_item.name || ' หมดแล้ว ลองเมนูที่คล้ายกันแทนได้นะคะ',
    v_item.id,
    to_jsonb(ARRAY(SELECT DISTINCT unnest(v_sugg))),
    v_uid
  )
  RETURNING m.id INTO v_msg;

  PERFORM public.cancel_order(p_order_id, 'สินค้าหมด: ' || v_item.name);

  RETURN jsonb_build_object('message_id', v_msg, 'order_id', p_order_id, 'sold_out_item', v_item.name);
END;
$$;

-- ---------- 5. create_order: optional p_replaces_order_id (same queue number after a shop cancel) ----------
DROP FUNCTION public.create_order(uuid, text, text, jsonb, text, uuid);

CREATE OR REPLACE FUNCTION public.create_order(
  p_store_id uuid,
  p_fulfillment_type text,
  p_payment_method text,
  p_items jsonb,
  p_customer_note text,
  p_client_request_id uuid,
  p_replaces_order_id uuid DEFAULT NULL
)
RETURNS TABLE (
  order_id uuid,
  queue_code text,
  total_satang bigint,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid                   uuid := auth.uid();
  v_store_active          boolean;
  v_timezone              text;
  v_accepting             boolean;
  v_queue_prefix          text;
  v_qr_mode               text;
  v_max_new_orders        integer;
  v_max_order_lines       integer;
  v_max_quantity_per_item integer;
  v_max_total_quantity    integer;
  v_total_quantity        integer := 0;
  v_business_date         date;
  v_queue_number          integer;
  v_queue_code            text;
  v_order_id              uuid;
  v_total                 bigint := 0;
  v_existing              public.orders%ROWTYPE;
  v_item                  jsonb;
  v_option_ids            jsonb;
  v_menu_id               uuid;
  v_qty                   integer;
  v_item_note             text;
  v_menu_sku              text;
  v_menu_name             text;
  v_base_price            bigint;
  v_option_delta          bigint;
  v_line_total            bigint;
  v_selected_count        integer;
  v_distinct_count        integer;
  v_valid_count           integer;
  v_group                 record;
  v_group_selected        integer;
  v_order_item_id         uuid;
  v_option                record;
  v_confirmation_mode     text;
  v_session_id            uuid;
  v_replaced              public.orders%ROWTYPE;
  v_sort_at               timestamptz := now();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication_required';
  END IF;

  IF p_client_request_id IS NULL THEN
    RAISE EXCEPTION 'client_request_id_required';
  END IF;

  IF p_fulfillment_type NOT IN ('dine_in', 'takeaway') THEN
    RAISE EXCEPTION 'invalid_fulfillment_type';
  END IF;

  IF p_payment_method NOT IN ('cash', 'promptpay_qr') THEN
    RAISE EXCEPTION 'payment_method_not_available_in_v1';
  END IF;

  IF p_customer_note IS NOT NULL AND char_length(p_customer_note) > 500 THEN
    RAISE EXCEPTION 'customer_note_too_long';
  END IF;

  IF p_items IS NULL
     OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required';
  END IF;

  -- Idempotency fast path: return only an order owned by the SAME auth user.
  SELECT o.*
    INTO v_existing
  FROM public.orders o
  WHERE o.store_id = p_store_id
    AND o.customer_user_id = v_uid
    AND o.client_request_id = p_client_request_id
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY
      SELECT v_existing.id, v_existing.queue_code,
             v_existing.total_satang, v_existing.status;
    RETURN;
  END IF;

  SELECT s.is_active, s.timezone,
         ps.is_accepting_orders, ps.queue_prefix,
         ps.max_new_orders_per_customer, ps.max_order_lines,
         ps.max_quantity_per_item, ps.max_total_quantity,
         os.qr_confirmation_mode
    INTO v_store_active, v_timezone, v_accepting, v_queue_prefix,
         v_max_new_orders, v_max_order_lines, v_max_quantity_per_item,
         v_max_total_quantity, v_qr_mode
  FROM public.stores s
  JOIN public.store_public_settings ps ON ps.store_id = s.id
  JOIN public.store_owner_settings os ON os.store_id = s.id
  WHERE s.id = p_store_id
  FOR SHARE OF s, ps, os;

  IF NOT FOUND OR v_store_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'store_unavailable';
  END IF;

  IF v_accepting IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'store_not_accepting_orders';
  END IF;

  IF jsonb_array_length(p_items) > v_max_order_lines THEN
    RAISE EXCEPTION 'too_many_order_lines';
  END IF;

  -- Serialize abuse-limit checks for this store + authenticated customer.
  -- This prevents concurrent create_order() calls from all passing the same count.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_store_id::text),
    pg_catalog.hashtext(v_uid::text)
  );

  IF (
    SELECT count(*)
    FROM public.orders o
    WHERE o.store_id = p_store_id
      AND o.customer_user_id = v_uid
      AND o.status = 'new'
  ) >= v_max_new_orders THEN
    RAISE EXCEPTION 'too_many_open_orders';
  END IF;

  v_business_date := public.khunyui_business_date(p_store_id);

  -- V1.8: re-order after the shop cancelled keeps the same queue number and queue position.
  IF p_replaces_order_id IS NOT NULL THEN
    SELECT o.* INTO v_replaced
    FROM public.orders o
    WHERE o.id = p_replaces_order_id
      AND o.store_id = p_store_id
      AND o.customer_user_id = v_uid
    FOR UPDATE;

    IF NOT FOUND
       OR v_replaced.status <> 'cancelled'
       OR v_replaced.cancel_source IS DISTINCT FROM 'owner'
       OR v_replaced.business_date <> v_business_date
       OR EXISTS (SELECT 1 FROM public.orders r WHERE r.replaces_order_id = v_replaced.id) THEN
      RAISE EXCEPTION 'reorder_not_allowed';
    END IF;
  END IF;

  -- PASS 1: validate every line and calculate the authoritative total.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    BEGIN
      v_menu_id := (v_item->>'menu_item_id')::uuid;
      v_qty := (v_item->>'quantity')::integer;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'invalid_item_payload';
    END;

    v_item_note := NULLIF(btrim(v_item->>'customer_note'), '');
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'invalid_quantity';
    END IF;
    IF v_qty > v_max_quantity_per_item THEN
      RAISE EXCEPTION 'quantity_per_item_limit_exceeded';
    END IF;
    v_total_quantity := v_total_quantity + v_qty;
    IF v_total_quantity > v_max_total_quantity THEN
      RAISE EXCEPTION 'total_quantity_limit_exceeded';
    END IF;
    IF v_item_note IS NOT NULL AND char_length(v_item_note) > 300 THEN
      RAISE EXCEPTION 'item_note_too_long';
    END IF;

    SELECT mi.sku, mi.name, mi.price_satang
      INTO v_menu_sku, v_menu_name, v_base_price
    FROM public.menu_items mi
    JOIN public.menu_categories mc ON mc.id = mi.category_id
    WHERE mi.id = v_menu_id
      AND mi.store_id = p_store_id
      AND mi.is_archived = false
      AND mi.is_available = true
      AND mc.is_active = true
    FOR SHARE OF mi;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'menu_item_unavailable:%', v_menu_id;
    END IF;

    v_option_ids := COALESCE(v_item->'option_value_ids', '[]'::jsonb);
    IF jsonb_typeof(v_option_ids) <> 'array' THEN
      RAISE EXCEPTION 'option_value_ids_must_be_array';
    END IF;

    v_selected_count := jsonb_array_length(v_option_ids);

    SELECT COUNT(DISTINCT x.value)
      INTO v_distinct_count
    FROM jsonb_array_elements_text(v_option_ids) AS x(value);

    IF v_distinct_count <> v_selected_count THEN
      RAISE EXCEPTION 'duplicate_option_value';
    END IF;

    -- Lock selected option rows so price/availability cannot change between
    -- validation/total calculation and snapshot insertion in this transaction.
    PERFORM ov.id
    FROM (
      SELECT x.value::uuid AS option_id
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    ) selected
    JOIN public.menu_option_values ov ON ov.id = selected.option_id
    JOIN public.menu_option_groups og ON og.id = ov.option_group_id
    JOIN public.menu_item_option_groups miog
      ON miog.option_group_id = og.id
     AND miog.menu_item_id = v_menu_id
    WHERE ov.is_available = true
      AND og.is_active = true
      AND og.store_id = p_store_id
    FOR SHARE OF ov, og;

    SELECT COUNT(*), COALESCE(SUM(ov.price_delta_satang), 0)
      INTO v_valid_count, v_option_delta
    FROM (
      SELECT x.value::uuid AS option_id
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    ) selected
    JOIN public.menu_option_values ov ON ov.id = selected.option_id
    JOIN public.menu_option_groups og ON og.id = ov.option_group_id
    JOIN public.menu_item_option_groups miog
      ON miog.option_group_id = og.id
     AND miog.menu_item_id = v_menu_id
    WHERE ov.is_available = true
      AND og.is_active = true
      AND og.store_id = p_store_id;

    IF v_valid_count <> v_selected_count THEN
      RAISE EXCEPTION 'invalid_or_unavailable_option';
    END IF;

    -- Every linked group must satisfy min/max selection rules.
    FOR v_group IN
      SELECT og.id, og.min_select, og.max_select
      FROM public.menu_item_option_groups miog
      JOIN public.menu_option_groups og ON og.id = miog.option_group_id
      WHERE miog.menu_item_id = v_menu_id
        AND og.is_active = true
    LOOP
      SELECT COUNT(*)
        INTO v_group_selected
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
      JOIN public.menu_option_values ov ON ov.id = x.value::uuid
      WHERE ov.option_group_id = v_group.id;

      IF v_group_selected < v_group.min_select
         OR v_group_selected > v_group.max_select THEN
        RAISE EXCEPTION 'option_selection_out_of_range';
      END IF;
    END LOOP;

    v_line_total := (v_base_price + v_option_delta) * v_qty;
    IF v_line_total < 0 THEN
      RAISE EXCEPTION 'negative_line_total';
    END IF;

    v_total := v_total + v_line_total;
  END LOOP;

  -- Queue session use + order insert. If a concurrent duplicate request wins the
  -- idempotency UNIQUE race, this subtransaction rolls back and returns the
  -- already-created order belonging to the same user.
  BEGIN
    IF p_replaces_order_id IS NOT NULL THEN
      v_queue_number := v_replaced.queue_number;
      v_queue_code := v_replaced.queue_code;
      v_sort_at := v_replaced.queue_sort_at;
      SELECT q.id INTO v_session_id
      FROM public.queue_sessions AS q
      WHERE q.order_id = v_replaced.id;
    ELSE
      -- V1.5: the queue number was reserved when the customer opened the menu.
      UPDATE public.queue_sessions AS q
      SET status = 'not_ordered'
      WHERE q.store_id = p_store_id
        AND q.customer_user_id = v_uid
        AND q.status = 'browsing'
        AND q.expires_at <= now();

      SELECT q.id, q.queue_number, q.queue_code
        INTO v_session_id, v_queue_number, v_queue_code
      FROM public.queue_sessions AS q
      WHERE q.store_id = p_store_id
        AND q.customer_user_id = v_uid
        AND q.business_date = v_business_date
        AND q.status = 'browsing'
        AND q.expires_at > now()
      ORDER BY q.created_at DESC
      LIMIT 1
      FOR UPDATE;

      -- No live reservation (hold time passed, or menu never opened): take the next number now.
      IF NOT FOUND THEN
        SELECT a.session_id, a.queue_number, a.queue_code
          INTO v_session_id, v_queue_number, v_queue_code
        FROM public.khunyui_allocate_queue_session(p_store_id, v_uid, v_business_date) AS a;
      END IF;
    END IF;

    INSERT INTO public.orders (
      store_id, customer_user_id, client_request_id,
      business_date, queue_number, queue_code,
      fulfillment_type, status,
      subtotal_satang, total_satang, currency,
      customer_note, replaces_order_id, queue_sort_at
    ) VALUES (
      p_store_id, v_uid, p_client_request_id,
      v_business_date, v_queue_number, v_queue_code,
      p_fulfillment_type, 'new',
      v_total, v_total, 'THB',
      NULLIF(btrim(p_customer_note), ''), p_replaces_order_id, v_sort_at
    )
    RETURNING id INTO v_order_id;

    UPDATE public.queue_sessions AS q
    SET status = 'ordered', order_id = v_order_id, ordered_at = now()
    WHERE q.id = v_session_id;

  EXCEPTION WHEN unique_violation THEN
    SELECT o.*
      INTO v_existing
    FROM public.orders o
    WHERE o.store_id = p_store_id
      AND o.customer_user_id = v_uid
      AND o.client_request_id = p_client_request_id
    LIMIT 1;

    IF FOUND THEN
      RETURN QUERY
        SELECT v_existing.id, v_existing.queue_code,
               v_existing.total_satang, v_existing.status;
      RETURN;
    END IF;

    RAISE;
  END;

  -- PASS 2: create immutable order snapshots.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_menu_id := (v_item->>'menu_item_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_item_note := NULLIF(btrim(v_item->>'customer_note'), '');
    v_option_ids := COALESCE(v_item->'option_value_ids', '[]'::jsonb);

    SELECT mi.sku, mi.name, mi.price_satang
      INTO v_menu_sku, v_menu_name, v_base_price
    FROM public.menu_items mi
    WHERE mi.id = v_menu_id
      AND mi.store_id = p_store_id;

    SELECT COALESCE(SUM(ov.price_delta_satang), 0)
      INTO v_option_delta
    FROM jsonb_array_elements_text(v_option_ids) AS x(value)
    JOIN public.menu_option_values ov ON ov.id = x.value::uuid;

    v_line_total := (v_base_price + v_option_delta) * v_qty;

    INSERT INTO public.order_items (
      order_id, menu_item_id,
      menu_sku_snapshot, menu_name_snapshot,
      unit_price_satang, quantity, line_total_satang,
      customer_note
    ) VALUES (
      v_order_id, v_menu_id,
      v_menu_sku, v_menu_name,
      v_base_price, v_qty, v_line_total,
      v_item_note
    )
    RETURNING id INTO v_order_item_id;

    FOR v_option IN
      SELECT ov.id, ov.name, ov.price_delta_satang
      FROM jsonb_array_elements_text(v_option_ids) AS x(value)
      JOIN public.menu_option_values ov ON ov.id = x.value::uuid
    LOOP
      INSERT INTO public.order_item_options (
        order_item_id, option_value_id,
        option_name_snapshot, price_delta_satang
      ) VALUES (
        v_order_item_id, v_option.id,
        v_option.name, v_option.price_delta_satang
      );
    END LOOP;
  END LOOP;

  v_confirmation_mode := CASE
    WHEN p_payment_method = 'promptpay_qr' THEN v_qr_mode
    ELSE 'manual'
  END;

  INSERT INTO public.payments (
    order_id, method, status, amount_satang, confirmation_mode
  ) VALUES (
    v_order_id, p_payment_method, 'pending', v_total, v_confirmation_mode
  );

  INSERT INTO public.order_status_history (
    order_id, from_status, to_status, changed_by, change_source
  ) VALUES (
    v_order_id, NULL, 'new', v_uid, 'customer'
  );

  RETURN QUERY
    SELECT v_order_id, v_queue_code, v_total, 'new'::text;
END;
$$;

-- ---------- 6. grants ----------
REVOKE EXECUTE ON FUNCTION
  public.khunyui_apply_category_options(),
  public.khunyui_message_on_owner_cancel(),
  public.khunyui_broadcast_message(),
  public.mark_messages_read(uuid),
  public.report_sold_out(uuid, uuid, uuid[]),
  public.create_order(uuid, text, text, jsonb, text, uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.mark_messages_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_sold_out(uuid, uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_order(uuid, text, text, jsonb, text, uuid, uuid) TO authenticated;

-- ---------- 7. store setup: spice levels on ส้มตำ ยำ พิเศษ (idempotent) ----------
DO $setup$
DECLARE
  v_store uuid := '11111111-1111-4111-8111-111111111111';
  v_group uuid;
BEGIN
  INSERT INTO public.menu_option_groups (store_id, code, name, selection_type, min_select, max_select, sort_order)
  VALUES (v_store, 'SPICE', 'ระดับเผ็ด', 'single', 1, 1, 0)
  ON CONFLICT (store_id, code) DO UPDATE SET name = EXCLUDED.name, selection_type = 'single', min_select = 1, max_select = 1, is_active = true
  RETURNING id INTO v_group;

  INSERT INTO public.menu_option_values (option_group_id, code, name, price_delta_satang, sort_order, is_default, is_available)
  VALUES (v_group, 'MILD', 'น้อย', 0, 1, false, true),
         (v_group, 'MEDIUM', 'พอดี', 0, 2, true, true),
         (v_group, 'HOT', 'เผ็ด', 0, 3, false, true),
         (v_group, 'EXTRA', 'เผ็ดเว่อ', 0, 4, false, true)
  ON CONFLICT (option_group_id, code) DO UPDATE
    SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order, is_default = EXCLUDED.is_default, is_available = true;

  UPDATE public.menu_categories AS c
  SET default_option_group_id = v_group
  WHERE c.store_id = v_store AND c.code IN ('SOMTAM', 'YUM', 'SPECIAL');

  INSERT INTO public.menu_item_option_groups (menu_item_id, option_group_id)
  SELECT mi.id, v_group
  FROM public.menu_items AS mi
  JOIN public.menu_categories AS c ON c.id = mi.category_id
  WHERE mi.store_id = v_store AND c.code IN ('SOMTAM', 'YUM', 'SPECIAL')
  ON CONFLICT DO NOTHING;
END
$setup$;

COMMIT;
