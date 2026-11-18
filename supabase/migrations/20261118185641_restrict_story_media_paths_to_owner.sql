DROP POLICY IF EXISTS "stories insert" ON public.stories;

CREATE POLICY "stories insert"
ON public.stories
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = (SELECT auth.uid())
  AND media_url IS NOT NULL
  AND left(
    media_url,
    char_length((SELECT auth.uid())::text || '/')
  ) = (SELECT auth.uid())::text || '/'
  AND count_my_stories() < 5
);
