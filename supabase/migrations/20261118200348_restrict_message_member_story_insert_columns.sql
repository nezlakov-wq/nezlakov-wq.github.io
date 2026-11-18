REVOKE INSERT ON public.conversation_members FROM authenticated;
GRANT INSERT (conversation_id, user_id)
ON public.conversation_members TO authenticated;

REVOKE INSERT ON public.messages FROM authenticated;
GRANT INSERT (
  conversation_id, sender_id, text, key_version, reply_to, kind, forwarded_from
) ON public.messages TO authenticated;

REVOKE INSERT ON public.stories FROM authenticated;
GRANT INSERT (user_id, media_url, kind)
ON public.stories TO authenticated;
