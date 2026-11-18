-- Clients use PostgREST and do not need DDL-related table privileges.
-- Remove unused capabilities that are unrelated to application reads/writes.
REVOKE TRIGGER, REFERENCES ON TABLE public.profiles, public.push_subscriptions, public.user_devices, public.user_keys FROM PUBLIC, anon, authenticated;
