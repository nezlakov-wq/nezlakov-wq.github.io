REVOKE ALL PRIVILEGES ON TABLE public.contacts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.contacts TO authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.username_aliases FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.username_aliases TO authenticated;

REVOKE ALL PRIVILEGES ON TABLE public.profiles FROM anon;
REVOKE DELETE ON TABLE public.profiles FROM PUBLIC, authenticated;
