CREATE OR REPLACE FUNCTION public.is_conversation_creator(p_conversation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.conversations c
       WHERE c.id = p_conversation_id
         AND c.created_by = auth.uid()
     );
$function$;

REVOKE ALL ON FUNCTION public.is_conversation_creator(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_conversation_creator(uuid) TO authenticated;

DROP POLICY IF EXISTS "conversation creator adds initial members" ON public.conversation_members;
CREATE POLICY "conversation creator adds initial members"
ON public.conversation_members
FOR INSERT TO authenticated
WITH CHECK (public.is_conversation_creator(conversation_id));

DROP POLICY IF EXISTS "leave or creator removes" ON public.conversation_members;
CREATE POLICY "leave or creator removes"
ON public.conversation_members
FOR DELETE TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR public.is_conversation_creator(conversation_id)
);
