REVOKE ALL PRIVILEGES ON TABLE
  public.admin_log,
  public.app_moderators,
  public.ban_appeals,
  public.push_config,
  public.turn_config,
  public.user_reports
FROM PUBLIC, anon, authenticated;
