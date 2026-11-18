DROP POLICY IF EXISTS "chat media delete" ON storage.objects;
CREATE POLICY "chat media delete"
ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'chat-media'
  AND owner_id = (SELECT auth.uid())::text
);
