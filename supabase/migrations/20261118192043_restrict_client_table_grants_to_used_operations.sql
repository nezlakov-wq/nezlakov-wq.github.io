REVOKE ALL PRIVILEGES ON TABLE
  public.messages,
  public.conversations,
  public.conversation_members,
  public.group_keys,
  public.stories,
  public.privacy_rules,
  public.user_bans,
  public.user_badges
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT ON TABLE public.messages TO authenticated;
GRANT SELECT, INSERT ON TABLE public.conversations TO authenticated;
GRANT SELECT ON TABLE public.conversations TO anon;
GRANT SELECT, INSERT, DELETE ON TABLE public.conversation_members TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.group_keys TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.stories TO authenticated;
GRANT SELECT ON TABLE public.privacy_rules, public.user_bans, public.user_badges TO authenticated;
