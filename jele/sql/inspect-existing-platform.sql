-- Read-only inspection for the existing Jele/Khunyui Supabase project.
-- Run with a verified project connection before writing any schema migration.
-- This file does not create a store, grant memberships, or modify shop data.
begin transaction read only;
set local statement_timeout = '15s';

select table_name, ordinal_position, column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in (
    'stores', 'store_members', 'store_public_settings', 'menu_categories',
    'menu_items', 'menu_item_option_groups', 'menu_option_groups',
    'menu_option_values', 'orders', 'order_items', 'order_item_options',
    'payments', 'payment_refunds', 'daily_closings'
  )
order by table_name, ordinal_position;

select ns.nspname as schema_name, cls.relname as table_name,
       cls.relrowsecurity as row_security_enabled,
       cls.relforcerowsecurity as force_row_security, cls.relkind as relation_kind,
       cls.reloptions as relation_options
from pg_catalog.pg_class cls
join pg_catalog.pg_namespace ns on ns.oid = cls.relnamespace
where ns.nspname = 'public'
  and cls.relname in (
    'store_members', 'store_public_settings', 'menu_categories', 'menu_items',
    'menu_item_option_groups', 'menu_option_groups', 'menu_option_values',
    'orders', 'order_items', 'order_item_options', 'payments',
    'payment_refunds', 'daily_closings'
  )
order by cls.relname;

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_catalog.pg_policies
where (schemaname = 'public' and tablename in (
    'store_members', 'menu_categories', 'menu_items', 'menu_item_option_groups',
    'menu_option_groups', 'menu_option_values', 'orders', 'order_items',
    'order_item_options', 'payments', 'payment_refunds', 'daily_closings'
  ))
   or (schemaname = 'storage' and tablename = 'objects')
order by schemaname, tablename, policyname;

select ns.nspname as schema_name, fn.proname as function_name,
       pg_catalog.pg_get_function_identity_arguments(fn.oid) as identity_arguments,
       pg_catalog.pg_get_function_result(fn.oid) as result_type,
       fn.prosecdef as security_definer, fn.proconfig as function_settings,
       pg_catalog.pg_get_functiondef(fn.oid) as definition
from pg_catalog.pg_proc fn
join pg_catalog.pg_namespace ns on ns.oid = fn.pronamespace
where ns.nspname = 'public'
  and fn.proname in (
    'create_menu_item', 'update_menu_item', 'set_menu_archived',
    'save_menu_option_value', 'set_menu_recommended', 'set_store_hero_image',
    'reserve_queue', 'create_order', 'advance_order_status', 'confirm_payment',
    'cancel_order', 'complete_refund', 'get_store_open_state',
    'get_owner_dashboard_summary', 'close_business_day'
  )
order by fn.proname, identity_arguments;

select ns.nspname as schema_name, cls.relname as table_name, con.conname,
       pg_catalog.pg_get_constraintdef(con.oid) as definition
from pg_catalog.pg_constraint con
join pg_catalog.pg_class cls on cls.oid = con.conrelid
join pg_catalog.pg_namespace ns on ns.oid = cls.relnamespace
where ns.nspname = 'public'
  and cls.relname in ('menu_items', 'menu_option_groups', 'menu_option_values', 'store_members')
order by cls.relname, con.conname;

select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'menu-images';

select store_id, role, count(*) as active_members
from public.store_members
where is_active = true
group by store_id, role
order by store_id, role;

select store_id, count(*) as menu_count,
       count(*) filter (where is_archived = true) as archived_count,
       count(*) filter (where price_satang > 0) as priced_count
from public.menu_items
group by store_id
order by store_id;

rollback;
