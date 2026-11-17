REVOKE INSERT ON TABLE public.profiles FROM authenticated;

GRANT INSERT (id, username, display_name, avatar_color)
ON TABLE public.profiles TO authenticated;
