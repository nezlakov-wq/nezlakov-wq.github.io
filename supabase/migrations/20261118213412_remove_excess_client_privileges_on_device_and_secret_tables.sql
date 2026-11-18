-- Defense in depth: remove table-level operations that bypass row-level security,
-- and keep anonymous clients away from push credentials and encrypted key records.
REVOKE TRUNCATE ON TABLE public.user_devices FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.push_subscriptions FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.user_keys FROM PUBLIC, anon;
