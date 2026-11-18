REVOKE ALL PRIVILEGES ON TABLE
  public.payments,
  public.token_ledger,
  public.gift_sales,
  public.gifts
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE
  public.payments,
  public.token_ledger,
  public.gift_sales,
  public.gifts
TO authenticated;
