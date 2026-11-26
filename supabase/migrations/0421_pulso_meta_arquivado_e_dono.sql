-- NIOGEN | supabase/migrations/0421_pulso_meta_arquivado_e_dono.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 26/11 ~17h30 (aviso da Live): "8 anúncio(s) com problema de entrega · 68,65 gasto e apenas 2 conversas · Das campanhas
-- da Dharma" → "Corrige o aviso."
-- O que houve: (1) os 8 eram os anúncios da C1, ARQUIVADA em 25/11 23h14. A coleta (n8n meta_ads_coleta → /ads) não recebe mais
-- anúncio arquivado ou apagado — a Meta tira da lista —, então meta_ads_anuncios ficou para sempre com o último status visto
-- (WITH_ISSUES, coleta das 23h15) e o pulso contava. (2) O gasto do dia somava a campanha da agência (R$ 43,56 Dharma +
-- R$ 25,09 agência) sem dizer de quem era.
-- Conserto:
--   1. meta_ads_gravar: anúncio que não veio na lista da Meta passa a ARCHIVED (a própria lista é a fonte). Só quando a lista
--      veio com 1 a 199 anúncios — lista vazia (falha) ou cheia (limite 200 da chamada, pode haver página seguinte) não arquiva
--      ninguém. Se o anúncio voltar à lista, o status dele é regravado como sempre.
--   2. pulso_operacao: os avisos de anúncio reprovado / com problema e o "A Meta gastou R$ X hoje" dizem de quem é quando há
--      algo que não é da Dharma: "(Dharma R$ 43,56 · agência R$ 25,09)", "(agência 8)". Só Dharma → texto igual ao de antes.
--      Remendo no texto da função que está na produção (pg_get_functiondef), sem reescrever o resto; para se não achar o trecho.
-- Regra 20: (1) não cria estado de lead · (2) tira um alerta falso, não cala alerta verdadeiro (WITH_ISSUES de anúncio que a
-- Meta ainda lista continua acendendo) · (3) status do anúncio continua vindo só da coleta, por função · (4) fonte única: a
-- Meta · (5) sem número novo — conferência não se aplica. Não cria tabela (regra 15: nada novo sem parceiro_id).
-- Desempenho: o pulso ganha 1–3 consultas pequenas (tabelas de dezenas de linhas) só quando há aviso; a coleta, 1 update.
-- Cenário: tests/fluxos/cenarios/X145_pulso_meta_arquivado_e_dono.sql.
begin;

-- ───────────── helpers do texto (de quem é) ─────────────
create or replace function public._pulso_meta_gasto_donos(p_dia date)
returns text language sql stable security definer set search_path = public as $f$
  with g as (
    select coalesce(c.dono, 'sem_dono') as dono, sum(d.gasto) as gasto
      from public.meta_ads_diario d
      left join public.meta_ads_campanhas_dono c on c.campanha_id = d.campanha_id
     where d.dia = p_dia
     group by 1 having sum(d.gasto) > 0)
  select case when exists (select 1 from g where dono <> 'dharma') then
    ' (' || (select string_agg(
               case dono when 'dharma' then 'Dharma' when 'agencia' then 'agência' else 'sem dono' end
               || ' R$ ' || replace(to_char(gasto, 'FM999G990D00'), '.', ','),
               ' · ' order by case dono when 'dharma' then 0 when 'agencia' then 1 else 2 end) from g) || ')'
  else '' end;
$f$;

create or replace function public._pulso_meta_anuncios_donos(p_status text)
returns text language sql stable security definer set search_path = public as $f$
  with g as (
    select coalesce(c.dono, 'sem_dono') as dono, count(*) as n
      from public.meta_ads_anuncios a
      left join public.meta_ads_campanhas_dono c on c.campanha_id = a.campanha_id
     where a.status_efetivo = p_status
     group by 1)
  select case when exists (select 1 from g where dono <> 'dharma') then
    ' (' || (select string_agg(
               case dono when 'dharma' then 'Dharma' when 'agencia' then 'agência' else 'sem dono' end || ' ' || n,
               ' · ' order by case dono when 'dharma' then 0 when 'agencia' then 1 else 2 end) from g) || ')'
  else '' end;
$f$;

revoke all on function public._pulso_meta_gasto_donos(date) from public, anon, authenticated;
revoke all on function public._pulso_meta_anuncios_donos(text) from public, anon, authenticated;
grant execute on function public._pulso_meta_gasto_donos(date), public._pulso_meta_anuncios_donos(text) to service_role;

-- ───────────── remendos nas duas funções da produção ─────────────
do $do$
declare
  v_def text; v_novo text;
begin
  -- 1. coleta: quem sumiu da lista da Meta está arquivado
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'meta_ads_gravar';
  if v_def is null then raise exception '0421: meta_ads_gravar não existe'; end if;
  if position('0421' in v_def) = 0 then
    v_novo := regexp_replace(v_def, '(get diagnostics v_ads = row_count;)(\r?\n)',
      E'\\1\\2\\2' ||
      E'  -- 0421: a Meta não lista anúncio arquivado/apagado; quem sumiu da lista deixa de valer o último status visto.\\2' ||
      E'  if jsonb_array_length(coalesce(p_anuncios, ''[]''::jsonb)) between 1 and 199 then\\2' ||
      E'    update public.meta_ads_anuncios a set status_efetivo = ''ARCHIVED'', atualizado_em = now()\\2' ||
      E'     where a.status_efetivo not in (''ARCHIVED'', ''DELETED'')\\2' ||
      E'       and not exists (select 1 from jsonb_array_elements(p_anuncios) r where r ->> ''id'' = a.ad_id);\\2' ||
      E'  end if;\\2');
    if v_novo = v_def then raise exception '0421: trecho de meta_ads_gravar não encontrado'; end if;
    execute v_novo;
  end if;

  -- 2. pulso: dizer de quem é
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pulso_operacao';
  if v_def is null then raise exception '0421: pulso_operacao não existe'; end if;
  if position('_pulso_meta_gasto_donos' in v_def) = 0 then
    v_novo := v_def;
    v_novo := replace(v_novo,
      $a$a_mot || format('%s anúncio(s) reprovado(s)', v_reprov)$a$,
      $a$a_mot || (format('%s anúncio(s) reprovado(s)', v_reprov) || public._pulso_meta_anuncios_donos('DISAPPROVED'))$a$);
    if v_novo = v_def then raise exception '0421: trecho "reprovado(s)" do pulso não encontrado'; end if;
    v_def := v_novo;
    v_novo := replace(v_novo,
      $a$a_mot || format('%s anúncio(s) com problema de entrega', v_problema)$a$,
      $a$a_mot || (format('%s anúncio(s) com problema de entrega', v_problema) || public._pulso_meta_anuncios_donos('WITH_ISSUES'))$a$);
    if v_novo = v_def then raise exception '0421: trecho "problema de entrega" do pulso não encontrado'; end if;
    v_def := v_novo;
    v_novo := replace(v_novo,
      $a$format('A Meta gastou R$ %s hoje e %s', replace(to_char(v_gasto, 'FM999G990D00'), '.', ','),$a$,
      $a$format('A Meta gastou R$ %s hoje%s e %s', replace(to_char(v_gasto, 'FM999G990D00'), '.', ','), public._pulso_meta_gasto_donos(v_hoje),$a$);
    if v_novo = v_def then raise exception '0421: trecho "A Meta gastou" do pulso não encontrado'; end if;
    execute v_novo;
  end if;
end $do$;

-- Os 8 anúncios congelados hoje viram ARCHIVED na primeira coleta depois desta migration (a cada 30 min).

commit;
