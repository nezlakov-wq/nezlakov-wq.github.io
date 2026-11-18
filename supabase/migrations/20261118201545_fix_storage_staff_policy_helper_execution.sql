CREATE OR REPLACE FUNCTION public.current_user_is_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND (
      auth.uid() = '852d1d07-897e-4fb0-af14-8530b2c4dd8a'::uuid
      OR EXISTS (
        SELECT 1 FROM public.app_moderators m
        WHERE m.user_id = auth.uid()
      )
    );
$function$;

REVOKE ALL ON FUNCTION public.current_user_is_staff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_is_staff() TO authenticated;

DROP POLICY IF EXISTS "report evidence staff read" ON storage.objects;
CREATE POLICY "report evidence staff read"
ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'report-evidence'
  AND public.current_user_is_staff()
);
