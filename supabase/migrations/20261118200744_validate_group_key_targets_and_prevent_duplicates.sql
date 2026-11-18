CREATE OR REPLACE FUNCTION public.can_write_group_key(
  p_conversation_id uuid,
  p_user_id uuid,
  p_device_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = p_conversation_id
        AND c.is_group
        AND NOT c.is_channel
    )
    AND EXISTS (
      SELECT 1 FROM public.conversation_members mine
      WHERE mine.conversation_id = p_conversation_id
        AND mine.user_id = auth.uid()
    )
    AND EXISTS (
      SELECT 1 FROM public.conversation_members target
      WHERE target.conversation_id = p_conversation_id
        AND target.user_id = p_user_id
    )
    AND (
      (p_device_id IS NULL AND EXISTS (
        SELECT 1 FROM public.profiles p
        WHERE p.id = p_user_id AND p.pub_key IS NOT NULL
      ))
      OR
      (p_device_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.user_devices d
        WHERE d.user_id = p_user_id AND d.device_id = p_device_id
      ))
    );
$function$;

REVOKE ALL ON FUNCTION public.can_write_group_key(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_write_group_key(uuid,uuid,text) TO authenticated;

DROP POLICY IF EXISTS "members write group keys" ON public.group_keys;
CREATE POLICY "members write group keys"
ON public.group_keys
FOR INSERT TO authenticated
WITH CHECK (
  public.can_write_group_key(conversation_id, user_id, device_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS group_keys_unique_target_version_device
ON public.group_keys (conversation_id, user_id, key_version, (coalesce(device_id, '')));

ALTER TABLE public.group_keys
  ADD CONSTRAINT group_keys_key_version_positive CHECK (key_version > 0),
  ADD CONSTRAINT group_keys_wrapped_format CHECK (
    length(wrapped) BETWEEN 4 AND 16384
    AND wrapped ~ '^g1:[A-Za-z0-9+/=]+$'
  ),
  ADD CONSTRAINT group_keys_device_id_valid CHECK (
    device_id IS NULL OR length(device_id) BETWEEN 1 AND 128
  );
