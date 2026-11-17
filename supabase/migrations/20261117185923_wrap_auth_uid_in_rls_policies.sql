-- Wrap auth.uid() calls in scalar subqueries so Postgres evaluates them once
-- per statement rather than once per row in RLS predicates.
DO $$
DECLARE
  p record;
  v_clauses text;
BEGIN
  FOR p IN
    SELECT schemaname, tablename, policyname, qual, with_check
    FROM pg_policies
    WHERE schemaname = 'public'
      AND (
        (coalesce(qual, '') ILIKE '%auth.uid()%' AND coalesce(qual, '') NOT ILIKE '%select auth.uid()%')
        OR
        (coalesce(with_check, '') ILIKE '%auth.uid()%' AND coalesce(with_check, '') NOT ILIKE '%select auth.uid()%')
      )
  LOOP
    v_clauses := concat_ws(
      ' ',
      CASE WHEN p.qual IS NOT NULL
        THEN format('USING (%s)', replace(p.qual, 'auth.uid()', '(SELECT auth.uid())'))
      END,
      CASE WHEN p.with_check IS NOT NULL
        THEN format('WITH CHECK (%s)', replace(p.with_check, 'auth.uid()', '(SELECT auth.uid())'))
      END
    );
    EXECUTE format(
      'ALTER POLICY %I ON %I.%I %s',
      p.policyname, p.schemaname, p.tablename, v_clauses
    );
  END LOOP;
END
$$;
