-- Add indexes for foreign-key columns that were missing a leading-column index.
-- This reduces parent-row delete/update checks and improves joins/filtering.
CREATE INDEX IF NOT EXISTS ban_appeals_user_id_idx ON public.ban_appeals (user_id);
CREATE INDEX IF NOT EXISTS contacts_contact_id_idx ON public.contacts (contact_id);
CREATE INDEX IF NOT EXISTS conversations_pinned_msg_idx ON public.conversations (pinned_msg);
CREATE INDEX IF NOT EXISTS gift_sales_user_id_idx ON public.gift_sales (user_id);
CREATE INDEX IF NOT EXISTS group_keys_user_id_idx ON public.group_keys (user_id);
CREATE INDEX IF NOT EXISTS messages_reply_to_idx ON public.messages (reply_to);
CREATE INDEX IF NOT EXISTS messages_sender_id_idx ON public.messages (sender_id);
CREATE INDEX IF NOT EXISTS payments_user_id_idx ON public.payments (user_id);
CREATE INDEX IF NOT EXISTS privacy_rules_viewer_idx ON public.privacy_rules (viewer);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_id_idx ON public.push_subscriptions (user_id);
CREATE INDEX IF NOT EXISTS stories_user_id_idx ON public.stories (user_id);
CREATE INDEX IF NOT EXISTS user_reports_reporter_id_idx ON public.user_reports (reporter_id);
CREATE INDEX IF NOT EXISTS user_reports_target_user_idx ON public.user_reports (target_user);
CREATE INDEX IF NOT EXISTS username_aliases_user_id_idx ON public.username_aliases (user_id);
