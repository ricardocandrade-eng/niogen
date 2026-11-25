-- NIOGEN | supabase/migrations/0392_live2_medicao.sql | 24/11/2026 — Claude Code (Fable 5.2)
-- Live 2.0, passo 3 — a MEDIÇÃO dos 7 dias lado a lado (Ricardo, 24/11: "7 dias lado a lado"; regra 18: toda entrega diz como
-- medir em 7 dias). A medição prometida no redesenho de 11/11 nunca foi feita; esta entra junto com a tela.
--   live2_medicao(dias) → por dia: respostas de pessoa no horário (9h–21h), mediana da espera do cliente, quantas passaram de
--     30 min e de 2 h (e quantas dessas em lead que viu os planos para cima), furos de cobertura e quantas vezes cada tela
--     (Live · Live 2.0 · Conversas) foi aberta. Base medida antes da 2.0, de 10 a 23/11: 294 respostas, 55 acima de 30 min (19 %).
--   tela_abriu(tela) → conta uma abertura de tela por pessoa e dia. A app_sessoes só registra o app instalado (9 linhas em 14 dias)
--     e não serve para saber se o Ricardo parou de ir à Conversas conferir.
-- A etapa usada é a de HOJE do lead (a de cada momento não fica guardada): serve para comparar períodos, não para auditar um caso.
-- Regra 20: só leitura e um contador de uso; nenhum estado de lead. Regra 15: tabela com parceiro_id. Cenário X123.
begin;

create table if not exists public.tela_aberturas (
  parceiro_id text not null default 'dharma',
  dia         date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  tela        text not null,
  por         uuid not null,
  n           int not null default 1,
  ultima_em   timestamptz not null default now(),
  primary key (dia, tela, por)
);
alter table public.tela_aberturas enable row level security;
drop policy if exists tela_aberturas_ler on public.tela_aberturas;
create policy tela_aberturas_ler on public.tela_aberturas for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke insert, update, delete on public.tela_aberturas from anon, authenticated;

create or replace function public.tela_abriu(p_tela text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return; end if;
  if p_tela not in ('minhavez', 'live2', 'conversas') then return; end if;
  insert into public.tela_aberturas (tela, por) values (p_tela, auth.uid())
  on conflict (dia, tela, por) do update set n = public.tela_aberturas.n + 1, ultima_em = now();
end $$;
revoke all on function public.tela_abriu(text) from public, anon;
grant execute on function public.tela_abriu(text) to authenticated;

create or replace function public.live2_medicao(p_dias int default 14)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ini timestamptz := (date_trunc('day', now() at time zone 'America/Sao_Paulo') - make_interval(days => greatest(1, least(coalesce(p_dias, 14), 60)) - 1)) at time zone 'America/Sao_Paulo';
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return null; end if;
  with t as (
    select mt.conversa_id, mt.papel, mt.created_at,
           lag(mt.papel) over (partition by mt.conversa_id order by mt.created_at) as ant
      from public.mari_turnos mt
     where mt.papel in ('lead', 'mari', 'humano') and mt.created_at > v_ini - interval '2 days'
  ),
  ini as (   -- começo de cada vez em que o cliente ficou esperando
    select conversa_id, created_at as ini from t where papel = 'lead' and coalesce(ant, 'x') <> 'lead' and created_at >= v_ini
  ),
  esp as (
    select i.conversa_id, (i.ini at time zone 'America/Sao_Paulo')::date as dia,
           extract(hour from i.ini at time zone 'America/Sao_Paulo')::int as h,
           rsp.papel as quem, extract(epoch from (rsp.created_at - i.ini)) / 60 as min,
           (c.funil_etapa in ('viu_planos', 'viavel', 'qualificada', 'pedido', 'biometria', 'agendada')) as avancado
      from ini i
      join public.mari_conversas c on c.id = i.conversa_id and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
      left join lateral (select x.papel, x.created_at from public.mari_turnos x
                          where x.conversa_id = i.conversa_id and x.papel in ('mari', 'humano') and x.created_at > i.ini
                          order by x.created_at limit 1) rsp on true
  ),
  dias as (select generate_series((v_ini at time zone 'America/Sao_Paulo')::date, (now() at time zone 'America/Sao_Paulo')::date, interval '1 day')::date as dia),
  h as (
    select dia, count(*) as respostas, round((percentile_cont(0.5) within group (order by min))::numeric, 1) as mediana_min,
           count(*) filter (where min > 30) as acima_30, count(*) filter (where min > 120) as acima_2h,
           count(*) filter (where min > 30 and avancado) as acima_30_avancado
      from esp where quem = 'humano' and h >= 9 and h < 21 group by dia
  ),
  m as (select dia, count(*) as respostas_mari from esp where quem = 'mari' group by dia),
  fu as (select (f.visto_em at time zone 'America/Sao_Paulo')::date as dia, count(*) as furos from public.live2_furos f where f.visto_em >= v_ini group by 1),
  ab as (select a.dia, sum(a.n) filter (where a.tela = 'minhavez') as live, sum(a.n) filter (where a.tela = 'live2') as live2,
                sum(a.n) filter (where a.tela = 'conversas') as conversas
           from public.tela_aberturas a where a.dia >= (v_ini at time zone 'America/Sao_Paulo')::date group by a.dia)
  select jsonb_build_object(
    'base', jsonb_build_object('periodo', '10 a 23/11/2026', 'respostas', 294, 'mediana_min', 3.1, 'acima_30', 55, 'acima_2h', 29, 'pct_acima_30', 19),
    'total', (select jsonb_build_object('respostas', coalesce(sum(respostas), 0), 'acima_30', coalesce(sum(acima_30), 0), 'acima_2h', coalesce(sum(acima_2h), 0),
                'acima_30_avancado', coalesce(sum(acima_30_avancado), 0),
                'pct_acima_30', case when coalesce(sum(respostas), 0) > 0 then round(100.0 * sum(acima_30) / sum(respostas), 1) end) from h),
    'dias', coalesce((select jsonb_agg(jsonb_build_object('dia', d.dia, 'respostas', coalesce(h.respostas, 0), 'mediana_min', h.mediana_min,
                'acima_30', coalesce(h.acima_30, 0), 'acima_2h', coalesce(h.acima_2h, 0), 'acima_30_avancado', coalesce(h.acima_30_avancado, 0),
                'respostas_mari', coalesce(m.respostas_mari, 0), 'furos', coalesce(fu.furos, 0),
                'abriu_live', coalesce(ab.live, 0), 'abriu_live2', coalesce(ab.live2, 0), 'abriu_conversas', coalesce(ab.conversas, 0)) order by d.dia)
              from dias d left join h on h.dia = d.dia left join m on m.dia = d.dia left join fu on fu.dia = d.dia left join ab on ab.dia = d.dia), '[]'::jsonb),
    'reforco', coalesce(public.reforco_resultado(greatest(1, coalesce(p_dias, 14))), '[]'::jsonb))
    into r;
  return r;
end $$;
revoke all on function public.live2_medicao(int) from public, anon;
grant execute on function public.live2_medicao(int) to authenticated, service_role;

commit;
