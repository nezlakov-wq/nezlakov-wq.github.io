REVOKE INSERT ON public.contacts FROM authenticated;
GRANT INSERT (owner_id, contact_id) ON public.contacts TO authenticated;

REVOKE INSERT, UPDATE ON public.push_subscriptions FROM authenticated;
GRANT INSERT (user_id, endpoint, p256dh, auth),
      UPDATE (user_id, endpoint, p256dh, auth)
ON public.push_subscriptions TO authenticated;

REVOKE INSERT, UPDATE ON public.user_devices FROM authenticated;
GRANT INSERT (user_id, device_id, pub_key, name, last_seen_at),
      UPDATE (user_id, device_id, pub_key, name, last_seen_at)
ON public.user_devices TO authenticated;

REVOKE INSERT, UPDATE ON public.user_keys FROM authenticated;
GRANT INSERT (user_id, enc_priv),
      UPDATE (user_id, enc_priv, enc_recovery)
ON public.user_keys TO authenticated;

REVOKE INSERT, UPDATE, DELETE ON public.profiles_view FROM authenticated;
