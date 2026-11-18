DROP POLICY IF EXISTS "stories insert" ON public.stories;

CREATE POLICY "stories insert"
ON public.stories
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = (SELECT auth.uid())
  AND count_my_stories() < 5
);
