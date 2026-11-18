-- Defense in depth for pg_net. Supabase's managed issue_pg_net_access
-- event trigger may re-grant usage/execute to anon and authenticated roles
-- when extension-owned objects are changed. Keep the net schema out of the
-- PostgREST exposed-schema list regardless of these grants.
REVOKE ALL ON SCHEMA net FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA net TO postgres, service_role, supabase_functions_admin;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA net FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA net TO postgres, service_role, supabase_functions_admin;
