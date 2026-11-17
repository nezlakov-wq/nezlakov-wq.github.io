-- is_banned(uuid) is not used by the browser client or any RLS policy.
-- Keep execution restricted to trusted backend/service-role code.
REVOKE EXECUTE ON FUNCTION public.is_banned(uuid) FROM authenticated;
