INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('story-media', 'story-media', false, 20971520)
ON CONFLICT (id) DO UPDATE
SET public = false, file_size_limit = EXCLUDED.file_size_limit;

CREATE POLICY "Story media read own or shared"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'story-media'
  AND (
    (storage.foldername(name))[1] = (SELECT auth.uid())::text
    OR CASE
      WHEN (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN public.shares_conversation_with(((storage.foldername(name))[1])::uuid)
      ELSE false
    END
  )
);

CREATE POLICY "Story media upload own"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'story-media'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);

CREATE POLICY "Story media delete own"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'story-media'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
);
