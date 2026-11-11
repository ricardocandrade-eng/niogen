-- NIOGEN | supabase/migrations/0121_live_ultra_rapida.sql | 11/11/2026 — Claude Code
-- Live lenta (Ricardo, 11/11: "deixar o sistema ultra rápido"). Medido em produção, como usuário logado:
--   · 89 das 97 políticas de RLS chamavam meu_perfil() / auth.uid() "cru": o Postgres refaz a conta A CADA LINHA lida. Dentro
--     das views (v_jornada, v_conversas, v_mari_cadencia…) isso multiplica. Envolvida em (select …), a função vira InitPlan e
--     roda UMA vez por consulta — a regra de acesso é exatamente a mesma (função STABLE: mesmo valor na consulta inteira).
--     Ensaio em transação desfeita: v_jornada 650 → 365 ms · v_conversas 160 → 16 ms · v_mari_cadencia 480 → 108 ms.
--   · v_jornada (security_invoker) é a consulta mais pesada e a mais pedida (menu de todas as telas, Live, Funil, Painel, Mari):
--     RPC jornada_live() SECURITY DEFINER com a porta admin/backoffice — o mesmo desenho da 0108 (oportunidades_abertas).
--     Os outros perfis continuam lendo a view, com o RLS de sempre.
-- Só aditivo: nenhuma política muda de regra, nenhuma view muda. Idempotente (pode rodar de novo).
-- ATENÇÃO para migrations futuras: política nova deve nascer com (select public.meu_perfil()) e (select auth.uid()).

-- ───────── 1. RLS: meu_perfil() e auth.uid() uma vez por consulta ─────────
do $$
declare p record; q text; w text;
begin
  for p in select schemaname, tablename, policyname, qual, with_check from pg_policies where schemaname = 'public' loop
    q := p.qual; w := p.with_check;
    if q is not null then
      q := regexp_replace(q, '(?<!SELECT )meu_perfil\(\)', '(SELECT meu_perfil())', 'g');
      q := regexp_replace(q, '(?<!SELECT )auth\.uid\(\)', '(SELECT auth.uid())', 'g');
    end if;
    if w is not null then
      w := regexp_replace(w, '(?<!SELECT )meu_perfil\(\)', '(SELECT meu_perfil())', 'g');
      w := regexp_replace(w, '(?<!SELECT )auth\.uid\(\)', '(SELECT auth.uid())', 'g');
    end if;
    if q is distinct from p.qual or w is distinct from p.with_check then
      execute format('alter policy %I on %I.%I %s %s', p.policyname, p.schemaname, p.tablename,
        case when q is not null then 'using (' || q || ')' else '' end,
        case when w is not null then 'with check (' || w || ')' else '' end);
    end if;
  end loop;
end $$;

-- ───────── 2. jornada_live(): a v_jornada sem o custo do RLS, para admin/backoffice ─────────
create or replace function public.jornada_live()
returns setof public.v_jornada
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return;
  end if;
  return query select * from public.v_jornada;
end $$;
revoke all on function public.jornada_live() from public, anon;
grant execute on function public.jornada_live() to authenticated;
