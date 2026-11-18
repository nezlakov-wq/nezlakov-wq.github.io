DROP POLICY IF EXISTS "stories insert" ON public.stories;

CREATE POLICY "stories insert"
ON public.stories
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = (SELECT auth.uid())
  AND count_my_stories() < 5
  AND (
    media_url ~ (
      '^' || (SELECT auth.uid())::text ||
      '/story-[A-Za-z0-9-]{1,64}\.[A-Za-z0-9]{1,8}$'
    )
    OR
    media_url ~ (
      '^https://cqhlkriyfgkhjjnxqvyv\.supabase\.co/storage/v1/object/public/avatars/' ||
      (SELECT auth.uid())::text ||
      '/story-[A-Za-z0-9-]{1,64}\.[A-Za-z0-9]{1,8}(\?t=[0-9]{1,16})?$'
    )
  )
);
