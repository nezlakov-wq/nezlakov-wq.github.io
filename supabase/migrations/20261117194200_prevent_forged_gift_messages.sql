-- Gift markers must only be minted by the trusted send_gift RPC.
DROP POLICY IF EXISTS "Members can send messages" ON public.messages;
CREATE POLICY "Members can send messages"
ON public.messages
FOR INSERT
TO authenticated
WITH CHECK (
  (SELECT auth.uid()) = sender_id
  AND EXISTS (
    SELECT 1 FROM public.conversation_members AS m
    WHERE m.conversation_id = messages.conversation_id
      AND m.user_id = (SELECT auth.uid())
  )
  AND left(coalesce(messages.text, ''), 6) <> '[gift:'
  AND left(coalesce(messages.text, ''), 7) <> '[ggift:'
  AND NOT EXISTS (
    SELECT 1 FROM public.conversations AS c
    WHERE c.id = messages.conversation_id
      AND c.is_channel
      AND c.created_by IS DISTINCT FROM (SELECT auth.uid())
  )
);

CREATE OR REPLACE FUNCTION public.edit_message(msg uuid, new_text text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  old_text text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT m.text INTO old_text
  FROM public.messages AS m
  WHERE m.id = msg AND m.sender_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF left(coalesce(old_text, ''), 6) = '[gift:'
     OR left(coalesce(old_text, ''), 7) = '[ggift:' THEN
    RAISE EXCEPTION 'Нельзя редактировать подарок';
  END IF;

  IF left(coalesce(new_text, ''), 6) = '[gift:'
     OR left(coalesce(new_text, ''), 7) = '[ggift:' THEN
    RAISE EXCEPTION 'Подарки отправляются через магазин';
  END IF;

  UPDATE public.messages SET text = new_text, edited = true WHERE id = msg;
END
$function$;
