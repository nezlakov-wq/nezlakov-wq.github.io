ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_avatar_url_safe_check
  CHECK (avatar_url IS NULL OR avatar_url ~ '^https://cqhlkriyfgkhjjnxqvyv\.supabase\.co/storage/v1/object/public/avatars/[0-9a-f-]{36}/[A-Za-z0-9._-]+(\?t=[0-9]{1,16})?$'),
  ADD CONSTRAINT profiles_banner_url_safe_check
  CHECK (banner_url IS NULL OR banner_url ~ '^https://cqhlkriyfgkhjjnxqvyv\.supabase\.co/storage/v1/object/public/avatars/[0-9a-f-]{36}/[A-Za-z0-9._-]+(\?t=[0-9]{1,16})?$'),
  ADD CONSTRAINT profiles_profile_bg_url_safe_check
  CHECK (profile_bg_url IS NULL OR profile_bg_url ~ '^https://cqhlkriyfgkhjjnxqvyv\.supabase\.co/storage/v1/object/public/avatars/[0-9a-f-]{36}/[A-Za-z0-9._-]+(\?t=[0-9]{1,16})?$');

ALTER TABLE public.conversations
  ADD CONSTRAINT conversations_avatar_url_safe_check
  CHECK (avatar_url IS NULL OR avatar_url ~ '^https://cqhlkriyfgkhjjnxqvyv\.supabase\.co/storage/v1/object/public/avatars/[0-9a-f-]{36}/[A-Za-z0-9._-]+(\?t=[0-9]{1,16})?$');
