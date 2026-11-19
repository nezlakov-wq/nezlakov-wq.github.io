-- Serialize per-user limits that were previously vulnerable to concurrent RPC calls.

CREATE OR REPLACE FUNCTION public.add_username(name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  n text := lower(trim(both '@' from name));
  cnt integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Нужен вход'; END IF;
  IF NOT public.is_plus(auth.uid()) THEN RAISE EXCEPTION 'Доп. юзернеймы доступны с подпиской Plus'; END IF;
  IF n !~ '^[a-z0-9_]{3,20}$' THEN RAISE EXCEPTION 'Юзернейм: 3–20 символов, латиница, цифры и _'; END IF;

  PERFORM pg_advisory_xact_lock(183603, hashtext(auth.uid()::text));

  SELECT count(*) INTO cnt FROM public.username_aliases WHERE user_id = auth.uid();
  IF cnt >= 3 THEN RAISE EXCEPTION 'Не больше 3 дополнительных юзернеймов'; END IF;
  IF EXISTS (SELECT 1 FROM public.profiles WHERE username = n) THEN RAISE EXCEPTION 'Юзернейм занят'; END IF;

  INSERT INTO public.username_aliases(user_id, username) VALUES (auth.uid(), n);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Юзернейм занят';
END
$function$;

CREATE OR REPLACE FUNCTION public.report_user(
  target_username text, reason text, evidence text[] DEFAULT '{}'::text[]
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  tgt uuid;
  r text;
  p text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Нужен вход'; END IF;
  SELECT id INTO tgt FROM public.profiles WHERE username = target_username;
  IF tgt IS NULL THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;
  IF tgt = auth.uid() THEN RAISE EXCEPTION 'Нельзя пожаловаться на себя'; END IF;

  r := nullif(trim(coalesce(reason, '')), '');
  IF r IS NULL THEN RAISE EXCEPTION 'Укажите причину'; END IF;
  IF coalesce(array_length(evidence, 1), 0) > 3 THEN RAISE EXCEPTION 'Не больше 3 фото'; END IF;
  FOREACH p IN ARRAY coalesce(evidence, '{}') LOOP
    IF left(p, 37) <> auth.uid()::text || '/' THEN RAISE EXCEPTION 'Недопустимый файл'; END IF;
  END LOOP;

  PERFORM pg_advisory_xact_lock(183604, hashtext(auth.uid()::text || ':' || tgt::text));

  IF EXISTS (
    SELECT 1 FROM public.user_reports
    WHERE reporter_id = auth.uid() AND target_user = tgt
      AND created_at > now() - interval '1 day'
  ) THEN
    RAISE EXCEPTION 'Вы уже жаловались на этого пользователя сегодня';
  END IF;

  INSERT INTO public.user_reports (reporter_id, target_user, reason, evidence)
  VALUES (auth.uid(), tgt, left(r, 300), coalesce(evidence, '{}'));
  RETURN 'Жалоба отправлена';
END
$function$;

CREATE OR REPLACE FUNCTION public.submit_appeal(text_in text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  t text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_banned(auth.uid()) THEN
    RAISE EXCEPTION 'Апелляция доступна только заблокированным';
  END IF;
  t := nullif(trim(coalesce(text_in, '')), '');
  IF t IS NULL THEN RAISE EXCEPTION 'Напишите текст апелляции'; END IF;

  PERFORM pg_advisory_xact_lock(183605, hashtext(auth.uid()::text));

  IF EXISTS (
    SELECT 1 FROM public.ban_appeals
    WHERE user_id = auth.uid() AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'Апелляция уже отправлена, ждите ответа';
  END IF;

  INSERT INTO public.ban_appeals (user_id, text) VALUES (auth.uid(), left(t, 1000));
  RETURN 'Апелляция отправлена';
END
$function$;