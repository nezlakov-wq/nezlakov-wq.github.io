ALTER TABLE public.profiles
ADD CONSTRAINT profiles_username_format_check
CHECK (username ~ '^[a-z0-9_]{3,32}$');

REVOKE UPDATE (username) ON TABLE public.profiles FROM authenticated;
