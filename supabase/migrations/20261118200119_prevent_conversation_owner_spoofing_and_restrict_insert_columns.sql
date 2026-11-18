-- Restrict client-created conversations to the fields used by the app.
-- The trigger enforces that created_by is the caller and official channels remain server-managed.
REVOKE INSERT ON public.conversations FROM authenticated;
GRANT INSERT (
  id, is_group, name, created_by, key_version, is_channel, is_public, username
) ON public.conversations TO authenticated;

CREATE OR REPLACE FUNCTION public.enforce_channel_create()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(auth.jwt()->>'role', '') <> 'service_role' THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'authentication required';
    END IF;
    IF NEW.created_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'conversation owner must be the current user';
    END IF;
    IF NEW.is_official THEN
      RAISE EXCEPTION 'official conversations are server-managed';
    END IF;
  END IF;

  IF NEW.is_channel THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = NEW.created_by
        AND p.plus_until IS NOT NULL
        AND p.plus_until > now()
    ) THEN
      RAISE EXCEPTION 'Создавать каналы может только подписчик Plus';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
