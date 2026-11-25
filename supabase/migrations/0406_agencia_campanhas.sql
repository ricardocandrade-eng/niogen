-- NIOGEN | supabase/migrations/0406_agencia_campanhas.sql | 25/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo, 25/11: a agência de anúncios vê SÓ as campanhas que ele liberar (lista em Configurações), o NIOGEN avisa quando
-- aparece campanha nova na conta, a tela Meta Ads ganha gráficos (funil, CPM, CTR, CAC, retorno à Meta) e um bloco "Atendimento dos
-- leads" que mostra, só em números, que os leads dos anúncios são atendidos. O Placar continua o da empresa inteira.
--  (1) meta_ads_campanhas_dono: uma linha por campanha da conta, dono 'dharma' | 'agencia' | nulo (= ainda não classificada).
--      As que já existem entram como 'dharma'. Campanha nova entra sozinha (gatilho nas tabelas da coleta), SEM dono — nunca liberada.
--      Só o admin lê; só meta_ads_campanha_dono() grava (porta: admin).
--  (2) agencia_campanhas(): a lista das liberadas. As policies da agência em meta_ads_diario/anuncios/conjuntos/posicionamento passam a
--      exigir campanha_id nela. _agencia_recorte(p): a agência sempre; admin/backoffice quando pedem a prévia ("Ver como a agência").
--  (3) Funções da tela filtradas pelo recorte: meta_ads_dia(p_agencia), meta_ads_resultado(p_agencia),
--      meta_ads_motivos_saida(de, ate, p_agencia). Sem parâmetro, meta_ads_dia() segue a conta inteira — é o que o Placar usa (decisão
--      do Ricardo: o Placar da agência é o da empresa). Novas: meta_ads_graficos(de, ate, p_agencia), meta_ads_atendimento(de, ate, p_agencia).
--  (4) Google Ads não é da agência: saem as policies dela nas tabelas do Google e google_ads_dia() deixa de atendê-la.
--  (5) Aviso de campanha nova: no celular do admin (push_pendentes, gatilho campanha_nova) — 1 por campanha, das 8h às 21h, até 3 por
--      dia — e no menu (meta_ads_campanhas_sem_dono). Conferência: campanha sem dono há mais de 24 h; e agencia_leituras_indevidas()
--      acusa policy da Meta que deixe a agência ver campanha que não é dela.
-- Regra 20: (1) estado novo "campanha sem dono" com dono (o admin), aviso e prazo (24 h) · (2) ninguém parado em silêncio: aviso e
-- conferência · (3) só o admin muda o dono, por uma função, com quem e quando · (4) gráficos e atendimento saem do banco, com a mesma
-- atribuição (v_mari_conversa_anuncio) de 0361 · (5) dois itens novos na conferência.
begin;

-- ───────────── (1) dono das campanhas ─────────────
create table if not exists public.meta_ads_campanhas_dono (
  campanha_id       text primary key,
  campanha_nome     text,
  dono              text check (dono in ('dharma', 'agencia')),
  vista_em          timestamptz not null default now(),
  classificada_em   timestamptz,
  classificada_por  uuid,
  avisada_em        timestamptz
);
comment on table public.meta_ads_campanhas_dono is '0406: de quem é cada campanha da conta da Meta. dono nulo = nova, esperando o admin. A agência só vê as de dono agencia.';
alter table public.meta_ads_campanhas_dono enable row level security;
drop policy if exists meta_ads_campanhas_dono_admin on public.meta_ads_campanhas_dono;
create policy meta_ads_campanhas_dono_admin on public.meta_ads_campanhas_dono for select to authenticated
  using (coalesce((select public.meu_perfil()), '') = 'admin');
revoke all on public.meta_ads_campanhas_dono from anon;
revoke insert, update, delete on public.meta_ads_campanhas_dono from authenticated;

insert into public.meta_ads_campanhas_dono (campanha_id, campanha_nome, dono, vista_em, classificada_em)
select campanha_id, (array_agg(campanha_nome order by quando desc nulls last))[1], 'dharma', min(quando), now()
  from (select campanha_id, campanha_nome, dia::timestamptz as quando from public.meta_ads_diario
        union all select campanha_id, campanha_nome, atualizado_em from public.meta_ads_anuncios
        union all select campanha_id, campanha_nome, atualizado_em from public.meta_ads_conjuntos
        union all select campanha_id, campanha_nome, dia::timestamptz from public.meta_ads_posicionamento_diario) x
 where campanha_id is not null
 group by campanha_id
on conflict (campanha_id) do nothing;

create or replace function public._meta_campanha_vista()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.campanha_id is not null then
    insert into public.meta_ads_campanhas_dono (campanha_id, campanha_nome) values (new.campanha_id, new.campanha_nome)
    on conflict (campanha_id) do update set campanha_nome = excluded.campanha_nome
     where excluded.campanha_nome is not null and public.meta_ads_campanhas_dono.campanha_nome is distinct from excluded.campanha_nome;
  end if;
  return null;
end $$;
revoke all on function public._meta_campanha_vista() from public, anon, authenticated;
drop trigger if exists meta_campanha_vista on public.meta_ads_diario;
create trigger meta_campanha_vista after insert or update of campanha_id, campanha_nome on public.meta_ads_diario for each row execute function public._meta_campanha_vista();
drop trigger if exists meta_campanha_vista on public.meta_ads_anuncios;
create trigger meta_campanha_vista after insert or update of campanha_id, campanha_nome on public.meta_ads_anuncios for each row execute function public._meta_campanha_vista();
drop trigger if exists meta_campanha_vista on public.meta_ads_conjuntos;
create trigger meta_campanha_vista after insert or update of campanha_id, campanha_nome on public.meta_ads_conjuntos for each row execute function public._meta_campanha_vista();
drop trigger if exists meta_campanha_vista on public.meta_ads_posicionamento_diario;
create trigger meta_campanha_vista after insert or update of campanha_id, campanha_nome on public.meta_ads_posicionamento_diario for each row execute function public._meta_campanha_vista();

-- Configurações › Agência (só admin): a lista, com o gasto, e a troca de dono
create or replace function public.meta_ads_campanhas_lista()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then raise exception 'Só o admin.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by (x.dono is null) desc, x.ultimo_dia desc nulls last, x.campanha_nome) from (
    select d.campanha_id, d.campanha_nome, d.dono, d.vista_em, d.classificada_em, u.nome as classificada_por, d.avisada_em,
           (d.campanha_nome ~* '^AG_') as parece_agencia,
           coalesce((select sum(m.gasto) from public.meta_ads_diario m where m.campanha_id = d.campanha_id
                      and m.dia > (now() at time zone 'America/Sao_Paulo')::date - 7), 0) as gasto_7d,
           coalesce((select sum(m.gasto) from public.meta_ads_diario m where m.campanha_id = d.campanha_id), 0) as gasto_total,
           (select max(m.dia) from public.meta_ads_diario m where m.campanha_id = d.campanha_id and m.gasto > 0) as ultimo_dia,
           (select count(distinct a.ad_id) from public.meta_ads_anuncios a where a.campanha_id = d.campanha_id and a.status_efetivo = 'ACTIVE') as anuncios_ativos
      from public.meta_ads_campanhas_dono d left join public.usuarios u on u.id = d.classificada_por) x), '[]'::jsonb);
end $$;
revoke all on function public.meta_ads_campanhas_lista() from public, anon;
grant execute on function public.meta_ads_campanhas_lista() to authenticated;

create or replace function public.meta_ads_campanha_dono(p_campanha text, p_dono text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.meta_ads_campanhas_dono;
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then raise exception 'Só o admin decide de quem é a campanha.' using errcode = '42501'; end if;
  if p_dono is null or p_dono not in ('dharma', 'agencia') then raise exception 'Dono deve ser dharma ou agencia.' using errcode = '22023'; end if;
  update public.meta_ads_campanhas_dono set dono = p_dono, classificada_em = now(), classificada_por = auth.uid()
   where campanha_id = p_campanha returning * into r;
  if r.campanha_id is null then raise exception 'Campanha % não encontrada.', p_campanha using errcode = 'P0002'; end if;
  return to_jsonb(r);
end $$;
revoke all on function public.meta_ads_campanha_dono(text, text) from public, anon;
grant execute on function public.meta_ads_campanha_dono(text, text) to authenticated;

-- o número do menu (Configurações) para o admin: campanhas esperando dono
create or replace function public.meta_ads_campanhas_sem_dono()
returns integer language sql stable security definer set search_path = public as $$
  select case when coalesce((select public.meu_perfil()), '') = 'admin'
              then (select count(*)::int from public.meta_ads_campanhas_dono where dono is null) else 0 end
$$;
revoke all on function public.meta_ads_campanhas_sem_dono() from public, anon;
grant execute on function public.meta_ads_campanhas_sem_dono() to authenticated;

-- ───────────── (2) o recorte da agência ─────────────
create or replace function public.agencia_campanhas()
returns setof text language sql stable security definer set search_path = public as $$
  select d.campanha_id from public.meta_ads_campanhas_dono d
   where d.dono = 'agencia'
     and ((select public.sou_agencia()) or coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice'))
$$;
revoke all on function public.agencia_campanhas() from public, anon;
grant execute on function public.agencia_campanhas() to authenticated;

-- verdadeiro = aplicar o recorte da agência: sempre para ela; para admin/backoffice só quando pedem a prévia
create or replace function public._agencia_recorte(p_agencia boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select (select public.sou_agencia()) or (coalesce(p_agencia, false) and coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice'))
$$;
revoke all on function public._agencia_recorte(boolean) from public, anon, authenticated;

alter policy meta_ads_diario_agencia on public.meta_ads_diario
  using ((select public.sou_agencia()) and campanha_id in (select public.agencia_campanhas()));
alter policy meta_ads_anuncios_agencia on public.meta_ads_anuncios
  using ((select public.sou_agencia()) and campanha_id in (select public.agencia_campanhas()));
alter policy meta_ads_conjuntos_agencia on public.meta_ads_conjuntos
  using ((select public.sou_agencia()) and campanha_id in (select public.agencia_campanhas()));
alter policy meta_ads_posic_agencia on public.meta_ads_posicionamento_diario
  using ((select public.sou_agencia()) and campanha_id in (select public.agencia_campanhas()));

-- ───────────── (4) Google Ads não é da agência ─────────────
drop policy if exists google_ads_campanhas_agencia on public.google_ads_campanhas;
drop policy if exists google_ads_diario_agencia on public.google_ads_diario;
drop policy if exists google_ads_palavras_agencia on public.google_ads_palavras;
create or replace function public.google_ads_dia()
returns setof public.v_google_ads_dia language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return; end if;   -- 0406: a agência não vê o Google
  return query select * from public.v_google_ads_dia order by dia;
end $$;

-- ───────────── (3) as funções da tela, com o recorte ─────────────
-- O retorno à Meta (o que a API de Conversões recebeu) de um conjunto de conversas/vendas — mesmas chaves e mesma regra de degrau
-- da v_meta_capi_painel (0186/0291), sem o id do dataset. Interna: só as funções desta migration chamam.
create or replace function public._meta_capi_de(p_conversas uuid[], p_vendas uuid[])
returns jsonb language sql stable security definer set search_path = public as $$
  with j as (select (now() at time zone 'America/Sao_Paulo')::date as hoje),
  t as (select coalesce((valor ->> 'degraus_desde')::timestamptz, 'infinity'::timestamptz) as troca from public.config_regras where chave = 'meta_capi'),
  e as (
    select e.status, e.criado_em, e.enviado_em, (e.fato_em at time zone 'America/Sao_Paulo')::date as dia,
           case when e.evento = 'ViewContent' then 'cidade' when e.evento = 'Purchase' then 'venda'
                when (e.evento = 'QualifiedLead') = (e.fato_em < coalesce((select troca from t), 'infinity')) then 'viavel' else 'qualificada' end as degrau
      from public.meta_eventos e
     where e.conversa_id = any (coalesce(p_conversas, '{}')) or e.venda_id = any (coalesce(p_vendas, '{}'))
  )
  select jsonb_build_object(
    'cidade_hoje', count(*) filter (where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'cidade'),
    'viaveis_hoje', count(*) filter (where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'viavel'),
    'qualificadas_hoje', count(*) filter (where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'qualificada'),
    'vendas_hoje', count(*) filter (where e.dia = j.hoje and e.status = 'enviado' and e.degrau = 'venda'),
    'enviados_hoje', count(*) filter (where e.dia = j.hoje and e.status = 'enviado'),
    'sem_clique_hoje', count(*) filter (where e.dia = j.hoje and e.status = 'sem_clique'),
    'erros_hoje', count(*) filter (where e.dia = j.hoje and e.status = 'erro'),
    'cidade_7d', count(*) filter (where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'cidade'),
    'viaveis_7d', count(*) filter (where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'viavel'),
    'qualificadas_7d', count(*) filter (where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'qualificada'),
    'vendas_7d', count(*) filter (where e.dia > j.hoje - 7 and e.status = 'enviado' and e.degrau = 'venda'),
    'enviados_7d', count(*) filter (where e.dia > j.hoje - 7 and e.status = 'enviado'),
    'sem_clique_7d', count(*) filter (where e.dia > j.hoje - 7 and e.status = 'sem_clique'),
    'erros_7d', count(*) filter (where e.dia > j.hoje - 7 and e.status = 'erro'),
    'na_fila', count(*) filter (where e.status in ('pendente', 'erro')),
    'ultimo_envio', max(e.enviado_em),
    'atrasados', count(*) filter (where e.status in ('pendente', 'erro') and e.criado_em < now() - interval '1 hour'))
    from j left join e on true
$$;
revoke all on function public._meta_capi_de(uuid[], uuid[]) from public, anon, authenticated;

drop function if exists public.meta_ads_dia();
create or replace function public.meta_ads_dia(p_agencia boolean default false)
returns table (dia date, gasto numeric, impressoes integer, cliques integer, conversas_meta integer, conversas_mari integer,
               com_cep integer, fora_area integer, qualificadas integer, atualizado_em timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if public.meu_perfil() is null and not public.sou_agencia() then return; end if;
  -- sem o recorte: o dia a dia da conta inteira (é o que o Placar usa, para todos — decisão do Ricardo, 25/11)
  if not (coalesce(p_agencia, false) and public._agencia_recorte(true)) then
    return query select d.dia, d.gasto, d.impressoes, d.cliques, d.conversas_meta, d.conversas_mari, d.com_cep, d.fora_area, d.qualificadas, d.atualizado_em
                   from public.v_meta_ads_dia d;
    return;
  end if;
  -- com o recorte: só as campanhas liberadas para a agência (gasto pela campanha; conversas pelo anúncio de onde vieram)
  return query
  with camp as (select public.agencia_campanhas() as id),
  meta as (
    select m.dia, sum(m.gasto) as gasto, sum(m.impressoes)::int as impressoes, sum(m.cliques)::int as cliques,
           sum(m.conversas)::int as conversas_meta, max(m.atualizado_em) as atualizado_em
      from public.meta_ads_diario m where m.campanha_id in (select id from camp) group by m.dia
  ), mari as (
    select (c.created_at at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as conversas_mari,
           count(*) filter (where c.cep is not null)::int as com_cep,
           count(*) filter (where c.elegibilidade = 'fora_area' or c.dentro_area is false)::int as fora_area,
           count(*) filter (where c.handoff_motivo = 'dados_completos')::int as qualificadas
      from public.mari_conversas c join public.v_mari_conversa_anuncio a on a.conversa_id = c.id
     where c.origem = 'meta_ads' and c.canal = 'whatsapp' and a.campanha_id in (select id from camp)
     group by 1
  )
  select coalesce(m.dia, x.dia), coalesce(m.gasto, 0), coalesce(m.impressoes, 0), coalesce(m.cliques, 0), coalesce(m.conversas_meta, 0),
         coalesce(x.conversas_mari, 0), coalesce(x.com_cep, 0), coalesce(x.fora_area, 0), coalesce(x.qualificadas, 0), m.atualizado_em
    from meta m full join mari x on x.dia = m.dia;
end $$;
revoke all on function public.meta_ads_dia(boolean) from public, anon;
grant execute on function public.meta_ads_dia(boolean) to authenticated;

drop function if exists public.meta_ads_resultado();
create or replace function public.meta_ads_resultado(p_agencia boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_ag boolean;
begin
  if public.meu_perfil() is null and not public.sou_agencia() then
    return null;
  end if;
  v_ag := public._agencia_recorte(p_agencia);   -- 0406: a agência só recebe o que veio das campanhas liberadas
  with atrib as (
    select a.conversa_id, a.ad_id, a.adset_id, a.referral_em, a.cep, a.dentro_area, a.venda_id
      from public.v_mari_conversa_anuncio a
     where a.ad_id is not null and (not v_ag or a.campanha_id in (select public.agencia_campanhas()))
  ), vend as (
    select v.id, v.motivo_saida, (coalesce(v.nio_os, '') <> '') as com_os,
           (v.nio_os_em at time zone 'America/Sao_Paulo')::date as dia_os
      from public.vendas v where v.origem = 'meta_ads'
  ), conv as (
    select (c.created_at at time zone 'America/Sao_Paulo')::date as dia, a.ad_id,
           (coalesce(c.cep, '') <> '' and c.dentro_area is true) as cep_ok,
           (c.handoff_motivo = 'dados_completos') as qualif,
           (c.handoff_motivo = 'ja_cliente_nio') as ja_cliente,
           (c.dentro_area is false or c.elegibilidade = 'fora_area' or vd.motivo_saida = 'Sem cobertura') as sem_cob
      from public.mari_conversas c
      left join atrib a on a.conversa_id = c.id
      left join vend vd on vd.id = c.venda_id
     where c.origem = 'meta_ads' and (not v_ag or a.conversa_id is not null)
  ), venda_ad as (   -- o anúncio de cada venda: a conversa mais recente que aponta para ela
    select distinct on (a.venda_id) a.venda_id, a.ad_id from atrib a where a.venda_id is not null
     order by a.venda_id, a.referral_em desc nulls last
  )
  select jsonb_build_object(
    'conversas', coalesce((select jsonb_agg(x order by x.dia, x.ad_id) from (
        select dia, ad_id, count(*)::int as n, count(*) filter (where cep_ok)::int as cep_ok,
               count(*) filter (where qualif)::int as qualif, count(*) filter (where ja_cliente)::int as ja_cliente,
               count(*) filter (where sem_cob)::int as sem_cob
          from conv group by dia, ad_id) x), '[]'::jsonb),
    'vendas', coalesce((select jsonb_agg(x order by x.dia, x.ad_id) from (
        select vd.dia_os as dia, va.ad_id, count(*)::int as n
          from vend vd left join venda_ad va on va.venda_id = vd.id
         where vd.com_os and vd.dia_os is not null and (not v_ag or va.ad_id is not null) group by vd.dia_os, va.ad_id) x), '[]'::jsonb),
    'cep_ok_ad', coalesce((select jsonb_object_agg(ad_id, n) from (
        select a.ad_id, count(*)::int as n from atrib a where coalesce(a.cep, '') <> '' and a.dentro_area is true group by a.ad_id) x), '{}'::jsonb),
    'vendas_conjunto', coalesce((select jsonb_object_agg(adset_id, n) from (
        select a.adset_id, count(*)::int as n from atrib a join vend vd on vd.id = a.venda_id
         where vd.com_os and a.adset_id is not null group by a.adset_id) x), '{}'::jsonb),
    'tem_atrib', exists (select 1 from atrib),
    'inicio_atrib', (select (min(a.referral_em) at time zone 'UTC')::date from atrib a),
    'capi', case when v_ag then public._meta_capi_de((select array_agg(conversa_id) from atrib), (select array_agg(venda_id) from atrib where venda_id is not null))
                 else (select to_jsonb(p) - 'dataset_id' from public.v_meta_capi_painel p) end,
    'recorte', v_ag
  ) into r;
  return r;
end $$;
revoke all on function public.meta_ads_resultado(boolean) from public, anon;
grant execute on function public.meta_ads_resultado(boolean) to authenticated;

drop function if exists public.meta_ads_motivos_saida(date, date);
create or replace function public.meta_ads_motivos_saida(p_de date default null, p_ate date default null, p_agencia boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_ag boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and not public.sou_agencia() then
    return null;
  end if;
  v_ag := public._agencia_recorte(p_agencia);
  with l as (
    select a.ad_id, x.destino, x.saida_motivo, x.saida_nome
      from public.v_leads x
      left join public.v_mari_conversa_anuncio a on a.conversa_id = x.conversa_id and a.ad_id is not null
                and (not v_ag or a.campanha_id in (select public.agencia_campanhas()))
     where x.origem = 'meta_ads' and coalesce(x.destino, '') <> 'teste_duplicada'
       and (not v_ag or a.conversa_id is not null)
       and (p_de is null or (x.criado_em at time zone 'America/Sao_Paulo')::date >= p_de)
       and (p_ate is null or (x.criado_em at time zone 'America/Sao_Paulo')::date <= p_ate)
  )
  select jsonb_build_object(
    'leads', coalesce((select jsonb_agg(y) from (
        select ad_id, count(*)::int as leads, count(*) filter (where destino = 'saida' and saida_motivo is not null)::int as saidas
          from l group by ad_id) y), '[]'::jsonb),
    'linhas', coalesce((select jsonb_agg(y) from (
        select ad_id, saida_motivo as motivo, count(*)::int as n
          from l where destino = 'saida' and saida_motivo is not null group by ad_id, saida_motivo) y), '[]'::jsonb),
    'motivos', coalesce((select jsonb_agg(jsonb_build_object('codigo', c.codigo, 'nome', c.nome, 'ordem', c.ordem) order by c.ordem)
                           from public.config_lead c where c.tipo = 'saida' and c.parceiro_id = 'dharma'), '[]'::jsonb)
  ) into r;
  return r;
end $$;
revoke all on function public.meta_ads_motivos_saida(date, date, boolean) from public, anon;
grant execute on function public.meta_ads_motivos_saida(date, date, boolean) to authenticated;

-- Gráficos do Meta Ads: tudo por dia × campanha, no período (de/até nulos = desde o início). Só contagens e dinheiro da mídia.
--   midia: gasto, impressões, cliques, conversas contadas pela Meta (meta_ads_diario)
--   conversas: conversas da Mari pelo dia da conversa, com CEP atendido e qualificadas (campanha nula = o WhatsApp não disse o anúncio;
--              só aparece sem o recorte)
--   vendas: vendas de anúncio com OS, pelo dia da OS · instaladas: pelo dia da instalação
--   capi: o que a Meta recebeu de volta, por dia × degrau (enviados e erros)
create or replace function public.meta_ads_graficos(p_de date default null, p_ate date default null, p_agencia boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_ag boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and not public.sou_agencia() then
    return null;
  end if;
  v_ag := public._agencia_recorte(p_agencia);
  with camp as (select public.agencia_campanhas() as id),
  noper as (select p_de as de, p_ate as ate),
  atrib as (
    select a.conversa_id, a.campanha_id, a.venda_id, a.referral_em
      from public.v_mari_conversa_anuncio a
     where a.ad_id is not null and (not v_ag or a.campanha_id in (select id from camp))
  ), venda_camp as (
    select distinct on (a.venda_id) a.venda_id, a.campanha_id from atrib a where a.venda_id is not null
     order by a.venda_id, a.referral_em desc nulls last
  ), conv as (
    select (c.created_at at time zone 'America/Sao_Paulo')::date as dia, a.campanha_id,
           (coalesce(c.cep, '') <> '' and c.dentro_area is true) as cep_ok, (c.handoff_motivo = 'dados_completos') as qualif
      from public.mari_conversas c left join atrib a on a.conversa_id = c.id
     where c.origem = 'meta_ads' and (not v_ag or a.conversa_id is not null)
  ), vend as (
    select vc.campanha_id, (coalesce(v.nio_os, '') <> '') as com_os,
           (v.nio_os_em at time zone 'America/Sao_Paulo')::date as dia_os, (v.instalado_em at time zone 'America/Sao_Paulo')::date as dia_inst
      from public.vendas v left join venda_camp vc on vc.venda_id = v.id
     where v.origem = 'meta_ads' and (not v_ag or vc.venda_id is not null)
  ), t as (select coalesce((valor ->> 'degraus_desde')::timestamptz, 'infinity'::timestamptz) as troca from public.config_regras where chave = 'meta_capi'),
  ev as (
    select (e.fato_em at time zone 'America/Sao_Paulo')::date as dia, e.status,
           case when e.evento = 'ViewContent' then 'cidade' when e.evento = 'Purchase' then 'venda'
                when (e.evento = 'QualifiedLead') = (e.fato_em < coalesce((select troca from t), 'infinity')) then 'viavel' else 'qualificada' end as degrau
      from public.meta_eventos e
     where not v_ag or e.conversa_id in (select conversa_id from atrib) or e.venda_id in (select venda_id from atrib where venda_id is not null)
  )
  select jsonb_build_object(
    'midia', coalesce((select jsonb_agg(x order by x.dia, x.campanha_id) from (
        select m.dia, m.campanha_id, round(sum(m.gasto), 2) as gasto, sum(m.impressoes)::int as impressoes, sum(m.cliques)::int as cliques,
               sum(m.conversas)::int as conversas_meta
          from public.meta_ads_diario m, noper
         where (not v_ag or m.campanha_id in (select id from camp))
           and (noper.de is null or m.dia >= noper.de) and (noper.ate is null or m.dia <= noper.ate)
         group by m.dia, m.campanha_id) x), '[]'::jsonb),
    'conversas', coalesce((select jsonb_agg(x order by x.dia, x.campanha_id) from (
        select dia, campanha_id, count(*)::int as n, count(*) filter (where cep_ok)::int as cep_ok, count(*) filter (where qualif)::int as qualif
          from conv, noper where (noper.de is null or dia >= noper.de) and (noper.ate is null or dia <= noper.ate)
         group by dia, campanha_id) x), '[]'::jsonb),
    'vendas', coalesce((select jsonb_agg(x order by x.dia) from (
        select dia_os as dia, campanha_id, count(*)::int as n from vend, noper
         where com_os and dia_os is not null and (noper.de is null or dia_os >= noper.de) and (noper.ate is null or dia_os <= noper.ate)
         group by dia_os, campanha_id) x), '[]'::jsonb),
    'instaladas', coalesce((select jsonb_agg(x order by x.dia) from (
        select dia_inst as dia, campanha_id, count(*)::int as n from vend, noper
         where dia_inst is not null and (noper.de is null or dia_inst >= noper.de) and (noper.ate is null or dia_inst <= noper.ate)
         group by dia_inst, campanha_id) x), '[]'::jsonb),
    'capi', coalesce((select jsonb_agg(x order by x.dia, x.degrau) from (
        select dia, degrau, count(*) filter (where status = 'enviado')::int as enviados, count(*) filter (where status = 'erro')::int as erros
          from ev, noper where (noper.de is null or dia >= noper.de) and (noper.ate is null or dia <= noper.ate)
         group by dia, degrau) x), '[]'::jsonb),
    'campanhas', coalesce((select jsonb_agg(x order by x.nome) from (
        select d.campanha_id, coalesce(d.campanha_nome, d.campanha_id) as nome from public.meta_ads_campanhas_dono d
         where not v_ag or d.campanha_id in (select id from camp)) x), '[]'::jsonb),
    'recorte', v_ag
  ) into r;
  return r;
end $$;
revoke all on function public.meta_ads_graficos(date, date, boolean) from public, anon;
grant execute on function public.meta_ads_graficos(date, date, boolean) to authenticated;

-- Atendimento dos leads de anúncio (a prova de que são atendidos), por campanha × anúncio e no total. Conversas que CHEGARAM no
-- período. Só contagem e tempo: nenhum identificador de conversa, telefone, nome, texto ou horário de conversa.
--   respondidas: houve turno da Mari ou de pessoa do time depois da 1ª mensagem do cliente · 1ª resposta: segundos até ela
--   consultor: passadas ao time (handoff) e, onde há registro de mensagem do time depois da passagem, os minutos até ela
--     (consultor_medidas de passadas_consultor — a resposta dada no Chatwoot nem sempre volta ao NIOGEN)
--   paradas: o cliente falou por último, há mais de 15 min, e a conversa segue em andamento · encerradas_sem_resposta: o cliente falou
--     por último numa conversa já encerrada (já cliente, sem cobertura, recusou…) — não é falha de atendimento
create or replace function public.meta_ads_atendimento(p_de date default null, p_ate date default null, p_agencia boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; v_ag boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and not public.sou_agencia() then
    return null;
  end if;
  v_ag := public._agencia_recorte(p_agencia);
  with atrib as (
    select a.conversa_id, a.ad_id, a.campanha_id from public.v_mari_conversa_anuncio a
     where a.ad_id is not null and (not v_ag or a.campanha_id in (select public.agencia_campanhas()))
  ), c as (
    select c.id, c.handoff_em, coalesce(c.funil_destino, 'em_andamento') as destino, a.ad_id, a.campanha_id
      from public.mari_conversas c left join atrib a on a.conversa_id = c.id
     where c.origem = 'meta_ads' and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
       and (not v_ag or a.conversa_id is not null)
       and (p_de is null or (c.created_at at time zone 'America/Sao_Paulo')::date >= p_de)
       and (p_ate is null or (c.created_at at time zone 'America/Sao_Paulo')::date <= p_ate)
  ), t as (
    select c.*, x.l1, x.lu, x.ru,
           (select min(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('mari', 'humano') and t.created_at >= x.l1) as r1,
           (select min(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano' and t.created_at >= c.handoff_em) as h1
      from c cross join lateral (
        select min(t.created_at) filter (where t.papel = 'lead') as l1, max(t.created_at) filter (where t.papel = 'lead') as lu,
               max(t.created_at) filter (where t.papel in ('mari', 'humano')) as ru
          from public.mari_turnos t where t.conversa_id = c.id) x
  ), m as (
    select t.*, extract(epoch from t.r1 - t.l1) as s1, extract(epoch from t.h1 - t.handoff_em) / 60 as hm,
           (t.lu is not null and t.lu > coalesce(t.ru, '-infinity') and t.lu < now() - interval '15 minutes') as ultima_do_cliente
      from t
  ), g as (
    select grouping(m.campanha_id, m.ad_id) as nivel, m.campanha_id, m.ad_id,
           count(*) filter (where m.l1 is not null)::int as conversas,
           count(*) filter (where m.l1 is not null and m.r1 is not null)::int as respondidas,
           count(*) filter (where m.l1 is not null and m.r1 is null)::int as sem_resposta,
           round(percentile_cont(0.5) within group (order by m.s1)::numeric, 1) as resp_mediana_s,
           round(percentile_cont(0.95) within group (order by m.s1)::numeric, 1) as resp_p95_s,
           round(max(m.s1)::numeric, 1) as resp_pior_s,
           count(*) filter (where m.s1 > 60)::int as resp_acima_1min,
           count(*) filter (where m.handoff_em is not null)::int as passadas_consultor,
           count(*) filter (where m.handoff_em is not null and m.h1 is not null)::int as consultor_medidas,
           round(percentile_cont(0.5) within group (order by m.hm)::numeric, 1) as consultor_mediana_min,
           round(max(m.hm)::numeric, 1) as consultor_pior_min,
           count(*) filter (where m.ultima_do_cliente and m.destino = 'em_andamento')::int as paradas,
           count(*) filter (where m.ultima_do_cliente and m.destino <> 'em_andamento')::int as encerradas_sem_resposta
      from m group by grouping sets ((m.campanha_id, m.ad_id), ())
  )
  select jsonb_build_object(
    'total', (select to_jsonb(g) - 'nivel' - 'campanha_id' - 'ad_id' from g where g.nivel = 3),
    'linhas', coalesce((select jsonb_agg(to_jsonb(g) - 'nivel' || jsonb_build_object('ad_nome', a.ad_nome, 'campanha_nome', d.campanha_nome)
                                         order by g.conversas desc, a.ad_nome)
                          from g left join public.meta_ads_anuncios a on a.ad_id = g.ad_id
                                 left join public.meta_ads_campanhas_dono d on d.campanha_id = g.campanha_id
                         where g.nivel = 0), '[]'::jsonb),
    'recorte', v_ag
  ) into r;
  return r;
end $$;
revoke all on function public.meta_ads_atendimento(date, date, boolean) from public, anon;
grant execute on function public.meta_ads_atendimento(date, date, boolean) to authenticated;

-- ───────────── (5) aviso de campanha nova e conferência ─────────────
-- push_envios aceita só gatilhos conhecidos: acrescenta campanha_nova à lista que estiver no ar
do $$
declare c record; d text;
begin
  select conname, pg_get_constraintdef(oid) as def into c from pg_constraint
   where conrelid = 'public.push_envios'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ 'gatilho';
  if c.conname is null or position('campanha_nova' in c.def) > 0 then return; end if;
  if position('ARRAY[' in c.def) = 0 then raise exception '0406: a regra de gatilho do push_envios mudou de forma — refazer'; end if;
  d := replace(c.def, 'ARRAY[', 'ARRAY[''campanha_nova''::text, ');
  execute format('alter table public.push_envios drop constraint %I', c.conname);
  execute format('alter table public.push_envios add constraint %I %s', c.conname, d);
end $$;

-- push_pendentes (0215, mexida por várias migrations): acrescenta o gatilho campanha_nova SEM reescrever a função — o trecho entra
-- antes de "), alvo as (" e a marcação de avisada antes de "), testes as (", na versão que estiver no ar.
do $$
declare d text := pg_get_functiondef('public.push_pendentes(text)'::regprocedure);
begin
  if position('campanha_nova' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, E'\n  ), alvo as (', ''))) <> length(E'\n  ), alvo as (')
     or (length(d) - length(replace(d, E'\n  ), testes as (', ''))) <> length(E'\n  ), testes as (') then
    raise exception '0406: push_pendentes mudou — refazer o trecho do aviso de campanha nova a partir da versão no ar';
  end if;
  d := replace(d, E'\n  ), alvo as (', E'
    union all
    -- 0406: campanha nova na conta da Meta, sem dono: o admin diz se é da agência. 1 aviso por campanha (avisada_em), só das 8h às 21h
    -- (fora disso sai às 8h), até 3 por dia.
    select * from (
      select ''campanha_nova''::text, d.campanha_id, null::uuid, null::uuid, ''📣 Campanha nova na Meta'',
             coalesce(d.campanha_nome, d.campanha_id) || '' — é da agência ou nossa? Toque para dizer.'',
             ''configuracoes.html?de=push#agencia'', true
        from public.meta_ads_campanhas_dono d
       where d.dono is null and d.avisada_em is null
         and extract(hour from now() at time zone ''America/Sao_Paulo'') between 8 and 20
       order by d.vista_em
       limit greatest(0, 3 - (select count(distinct p.chave)::int from public.push_envios p
                                where p.gatilho = ''campanha_nova''
                                  and p.criado_em >= ((now() at time zone ''America/Sao_Paulo'')::date::timestamp at time zone ''America/Sao_Paulo'')))
    ) cn
  ), alvo as (');
  -- o aviso de campanha nova vai na frente da fila da rodada (são no máximo 3 por dia)
  if position('when ''handoff_sem_resposta'' then 0' in d) = 0 then raise exception '0406: push_pendentes mudou (ordem da fila)'; end if;
  d := replace(d, 'when ''handoff_sem_resposta'' then 0', 'when ''handoff_sem_resposta'' then 0 when ''campanha_nova'' then 0');
  d := replace(d, E'\n  ), testes as (', E'
  ), campanha_avisada as (
    update public.meta_ads_campanhas_dono set avisada_em = now()
     where avisada_em is null and campanha_id in (select chave from novos where gatilho = ''campanha_nova'')
    returning 1
  ), testes as (');
  execute d;
end $$;

-- agencia_leituras_indevidas (0361/0362): Google saiu da lista; funções novas conferidas; policy da Meta sem o recorte acusa
CREATE OR REPLACE FUNCTION public.agencia_leituras_indevidas()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  achados text[] := '{}';
  tabelas_ok text[] := array['usuarios', 'meta_ads_diario', 'meta_ads_anuncios', 'meta_ads_conjuntos', 'meta_ads_posicionamento_diario',
                             'config_meta_ads_regras', 'config_metas', 'config_area', 'dfv_bairros_pronto'];   -- 0406: Google Ads saiu (não é da agência)
  visoes_ok text[] := array['v_jornada', 'v_canais_7d', 'v_contatos_limite'];   -- conferidas em 22/11 (v_contatos_limite filtrada na 0362)
  funcoes_ok text[] := array['sou_agencia', 'meta_ads_dia', 'meta_ads_resultado', 'meta_ads_motivos_saida', 'placar_conversas_dia',
                             'placar_agencia', 'tabela_agencia', 'painel_meta_ritmo', 'agencia_leituras_indevidas',
                             'agencia_campanhas', '_agencia_recorte', 'meta_ads_graficos', 'meta_ads_atendimento'];   -- 0406
  -- 0362: o que conta como porta no corpo de uma função, e as conferidas à mão em 23/11 que não têm porta no próprio corpo
  porta_re text := '(meu_perfil|_os_pode_gravar|auth\.role\(\)|parceiro_atual|parceiro_ativo_ou_erro|sou_agencia|session_user|request\.jwt\.claims|_pendencia_pode)';
  gravam_ok text[] := array[
    'fila_vero_clique',               -- pública de propósito: o link do template (fv.html), só marca o clique pelo código
    'parceiro_cadastrar',             -- pública de propósito: cadastro do Pocket, com limite de tentativas
    'app_sessao_registrar',           -- só grava a sessão do próprio login
    'backoffice_responder_citando',   -- a porta está no backoffice_responder__nucleo
    '_cutucada', '_os_agenda_aviso']; -- só leem (o filtro pega a atribuição ":= public.")
  r record;
begin
  if not public._os_pode_gravar() then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if (select p.prosrc from pg_proc p where p.oid = 'public.meu_perfil()'::regprocedure) !~ 'perfil\s*<>\s*''agencia''' then
    achados := achados || 'meu_perfil() voltou a devolver o perfil agencia'::text;
  end if;
  for r in
    select p.schemaname, p.tablename, p.policyname, p.cmd from pg_policies p
     where (coalesce(p.qual, '') ~ 'sou_agencia' or coalesce(p.with_check, '') ~ 'sou_agencia')
       and (p.cmd <> 'SELECT' or p.schemaname <> 'public' or p.tablename <> all (tabelas_ok))
  loop
    achados := achados || format('policy %s em %s.%s (%s) libera a agência fora da lista', r.policyname, r.schemaname, r.tablename, r.cmd);
  end loop;
  -- 0406: nas tabelas da Meta, a agência só lê linha de campanha que o Ricardo liberou (agencia_campanhas)
  for r in
    select p.tablename, p.policyname from pg_policies p
     where p.schemaname = 'public' and coalesce(p.qual, '') ~ 'sou_agencia'
       and p.tablename in ('meta_ads_diario', 'meta_ads_anuncios', 'meta_ads_conjuntos', 'meta_ads_posicionamento_diario')
       and coalesce(p.qual, '') !~ 'agencia_campanhas'
  loop
    achados := achados || format('policy %s em %s deixa a agência ver campanha que não é dela', r.policyname, r.tablename);
  end loop;
  if exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = 'meta_ads_campanhas_dono' and coalesce(p.qual, '') ~ 'sou_agencia') then
    achados := achados || 'a agência lê a lista de donos das campanhas'::text;
  end if;
  for r in
    select p.tablename, p.policyname from pg_policies p
     where p.schemaname = 'public' and p.permissive = 'PERMISSIVE' and p.cmd in ('SELECT', 'ALL')
       and p.roles && array['authenticated', 'public']::name[]
       and coalesce(p.qual, 'true') !~ '(meu_perfil|sou_agencia|parceiro_atual|usuario_id|perfil\s*=|EXISTS)'
       and exists (select 1 from information_schema.columns c
                    where c.table_schema = 'public' and c.table_name = p.tablename
                      and c.column_name ~ '(telefone|whatsapp|cpf|cnpj|email|^cep$|logradouro|endereco|cliente|nome_contato|conversa_id|venda_id|lead_id|payload|markdown)')
  loop
    achados := achados || format('tabela %s (policy %s) tem dado de cliente e é lida por qualquer login', r.tablename, r.policyname);
  end loop;
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       and not coalesce(c.reloptions::text, '') ~ 'security_invoker=(true|on)'
       and has_table_privilege('authenticated', c.oid, 'select')
       and c.relname <> all (visoes_ok)
  loop
    achados := achados || format('visão %s roda como dona (sem security_invoker): conferir o que ela mostra', r.relname);
  end loop;
  for r in
    select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosrc ~ 'sou_agencia' and p.proname <> all (funcoes_ok)
       and p.proname not in ('conferencia_itens')
  loop
    achados := achados || format('função %s atende a agência e não foi conferida', r.proname);
  end loop;
  -- 0362: função definer que grava (ou chama outra), executável por qualquer login ou sem login, sem porta no corpo.
  -- Não conta: casca da porta em sombra cujo __nucleo tem porta, casca que entrega à porta() (as peças _porta_* conferem o
  -- perfil) e as conferidas à mão (gravam_ok). Função interna nova: tire o EXECUTE de public, anon e authenticated.
  for r in
    select p.proname from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosecdef and p.prorettype <> 'trigger'::regtype
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))
       and p.prosrc ~* '(insert\s+into|update\s+(public\.)?[a-z_]+\s+set|delete\s+from|perform\s|net\.http_post|:=\s*public\.)'
       and p.prosrc !~* porta_re
       and p.prosrc !~ 'public\.porta\('
       and not exists (select 1 from pg_proc k where k.pronamespace = p.pronamespace and k.proname = p.proname || '__nucleo'
                          and p.prosrc ~ (p.proname || '__nucleo') and k.prosrc ~* porta_re)
       and p.proname <> all (gravam_ok)
     order by p.proname
  loop
    achados := achados || format('função %s grava, qualquer login executa e não tem porta de perfil', r.proname);
  end loop;
  -- 0362: porta que compara meu_perfil() sem tratar nulo — para login sem perfil a conta dá nulo e a recusa não dispara.
  for r in
    select p.proname from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname <> 'agencia_leituras_indevidas'
       and p.prosrc ~* '(meu_perfil\(\)\)?\s*(not\s+in|<>|!=)|not\s*\(\s*(public\.)?meu_perfil\(\)\s*=)'
     order by p.proname
  loop
    achados := achados || format('função %s compara meu_perfil() sem tratar perfil nulo (use coalesce): login sem perfil passa', r.proname);
  end loop;
  return to_jsonb(achados);
end $function$;

-- conferencia_itens: item novo antes do "return it;" da versão no ar (a função é mexida por várias sessões)
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('agencia_campanha_sem_dono' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, E'\n  return it;\nend', ''))) <> length(E'\n  return it;\nend') then
    raise exception '0406: conferencia_itens mudou — refazer o item da campanha sem dono a partir da versão no ar';
  end if;
  d := replace(d, E'\n  return it;\nend', E'
  -- 37. 0406 — campanha nova na conta da Meta sem dono há mais de 24 h (a agência só vê o que o Ricardo libera; até lá, ninguém decide)
  select count(*)::int, string_agg(coalesce(campanha_nome, campanha_id), '', '') into n, ex
    from public.meta_ads_campanhas_dono where dono is null and vista_em < now() - interval ''24 hours'';
  it := it || jsonb_build_object(''codigo'', ''agencia_campanha_sem_dono'', ''nome'', ''Campanha nova da Meta com dono'',
    ''nivel'', case when n > 0 then ''atencao'' else ''ok'' end, ''n'', n,
    ''texto'', case when n = 0 then ''toda campanha da conta tem dono (Dharma ou agência)''
                  else left(format(''%s campanha(s) sem dono há mais de 24 h: %s'', n, ex), 240) end,
    ''fazer'', case when n > 0 then ''Configurações › Agência: dizer se a campanha é da agência ou nossa.'' end);

  return it;
end');
  execute d;
end $$;

commit;
