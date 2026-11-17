-- Avoid invoking SECURITY DEFINER is_banned(uuid) from the message INSERT policy.
-- The user_bans table's own-row SELECT policy scopes this lookup to the caller.
ALTER POLICY "banned cannot insert messages"
ON public.messages
WITH CHECK (
  NOT EXISTS (
    SELECT 1
    FROM public.user_bans AS b
    WHERE b.user_id = (SELECT auth.uid())
      AND (b.until IS NULL OR b.until > now())
  )
);
