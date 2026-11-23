-- NIOGEN | supabase/migrations/0361_perfil_agencia.sql | 23/11/2026 — Claude Code (Fable 5.2)
-- Prompt docs/Prompt_perfil_agencia_221126_2345.md (decisões do Ricardo em 22/11): perfil novo `agencia`, SÓ LEITURA, para a
-- agência que gere parte da Meta Ads. Ela vê Meta Ads, Placar e Tabela; não vê NENHUM dado de cliente, nem comissão, nem a
-- quebra por vendedor, nem o saldo em aberto da conta Meta.
--
-- O desenho, e por que ele é diferente do que o prompt supunha:
--   · O prompt dizia "meu_perfil() não muda". Levantado no banco em 22/11: 24 policies liberam leitura a "qualquer perfil
--     ativo" (meu_perfil() is not null), inclusive em tabelas que não são para gente de fora, e dezenas de funções usam a
--     mesma porta. Com meu_perfil() devolvendo 'agencia', tudo isso abriria sozinho, sem ninguém "acrescentar agencia" a nada.
--   · Por isso o perfil nasce FECHADO POR PADRÃO: meu_perfil() devolve NULL para quem é agencia. Toda policy e toda função
--     que já existe (e as que vierem, escritas do jeito de sempre) tratam a agência como um login sem perfil. O que ela pode
--     ler é dito em policies e funções NOVAS, explícitas, pela função nova sou_agencia().
--   · Oito tabelas eram legíveis por QUALQUER login (policy "true"). Passam a exigir perfil. Só aperta; ninguém do time
--     perde nada.
--   · Nada de dado de cliente sai em linha: as funções novas devolvem CONTAGENS por dia e por anúncio. O Placar da agência
--     recebe as vendas sem nome, telefone, CPF, endereço, vendedor, nº de pedido e comissão (só dia, plano, forma, cidade,
--     origem e situação), com um número de ordem no lugar do id.
--   · Fonte única (regra 20.4): Meta Ads e Placar passam a ler as MESMAS funções para todos os perfis no que vem das
--     conversas e das vendas de anúncio — a agência e o admin veem o mesmo número, calculado num lugar só.
--
-- Regra 15: nenhuma tabela nova. Regra 19: policies novas com (select …); as funções são definer (mesma razão da 0360).
-- Regra 20: (1)(2)(3) só leitura, nenhum estado, nenhuma gravação · (4) os números saem das mesmas tabelas e visões ·
-- (5) item novo na conferência: `agencia_leitura` (agencia_leituras_indevidas()).
-- Cenário X87.
begin;

-- ───────────── 1. o perfil ─────────────
alter table public.usuarios drop constraint usuarios_perfil_check;
alter table public.usuarios add constraint usuarios_perfil_check
  check (perfil in ('admin', 'vendedor', 'backoffice', 'agencia'));

-- Fechado por padrão: para tudo o que já existe, quem é agencia não tem perfil.
create or replace function public.meu_perfil()
returns text language sql stable security definer set search_path = public as $$
  select perfil from public.usuarios where id = auth.uid() and ativo and perfil <> 'agencia'
$$;

create or replace function public.sou_agencia()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.usuarios where id = auth.uid() and ativo and perfil = 'agencia')
$$;
revoke all on function public.sou_agencia() from public, anon;
grant execute on function public.sou_agencia() to authenticated;

-- ───────────── 2. o que a agência lê direto (policies novas, só SELECT) ─────────────
-- A própria linha (nome e perfil, para o menu). Não lê a equipe.
create policy usuarios_agencia_propria on public.usuarios for select to authenticated
  using (id = (select auth.uid()) and (select public.sou_agencia()));
-- O que a Meta devolve da campanha (nenhum dado de cliente) e os limites do agente.
create policy meta_ads_diario_agencia on public.meta_ads_diario for select to authenticated using ((select public.sou_agencia()));
create policy meta_ads_anuncios_agencia on public.meta_ads_anuncios for select to authenticated using ((select public.sou_agencia()));
create policy meta_ads_conjuntos_agencia on public.meta_ads_conjuntos for select to authenticated using ((select public.sou_agencia()));
create policy meta_ads_posic_agencia on public.meta_ads_posicionamento_diario for select to authenticated using ((select public.sou_agencia()));
create policy config_meta_ads_regras_agencia on public.config_meta_ads_regras for select to authenticated using ((select public.sou_agencia()));
-- A meta do mês, as cidades atendidas e os bairros por pontuação (para mirar o público).
create policy config_metas_agencia on public.config_metas for select to authenticated using ((select public.sou_agencia()));
create policy config_area_agencia on public.config_area for select to authenticated using ((select public.sou_agencia()));
create policy dfv_bairros_pronto_agencia on public.dfv_bairros_pronto for select to authenticated using ((select public.sou_agencia()));
-- De propósito SEM policy para a agência: o saldo da conta de anúncios, as tabelas com comissão, as de configuração interna
-- e tudo o que tem cliente.

-- ───────────── 3. o que era de "qualquer login" passa a exigir perfil ─────────────
alter policy conteudos_ler on public.conteudos using ((select public.meu_perfil()) is not null);
alter policy lead_estado_ler on public.lead_estado using ((select public.meu_perfil()) is not null);
alter policy lead_estado_mudancas_ler on public.lead_estado_mudancas using ((select public.meu_perfil()) is not null);
alter policy mari_portao_rodadas_ler on public.mari_portao_rodadas using ((select public.meu_perfil()) is not null);
alter policy meta_eventos_ler on public.meta_eventos using ((select public.meu_perfil()) is not null);
alter policy porta_sombra_ler on public.porta_sombra using ((select public.meu_perfil()) is not null);
alter policy projetor_sombra_ler on public.projetor_sombra using ((select public.meu_perfil()) is not null);
alter policy pulso_batimentos_ler on public.pulso_batimentos using ((select public.meu_perfil()) is not null);

-- ───────────── 4. funções de leitura (contagens) ─────────────
create or replace function public._dia_sp_txt(p timestamptz)
returns text language sql immutable as $$
  select to_char((p at time zone 'America/Sao_Paulo')::date, 'YYYY-MM-DD') || 'T12:00:00-03:00'
$$;

-- O dia a dia do Meta Ads (a v_meta_ads_dia sem as colunas de venda e de comissão). Meta Ads e Placar, todos os perfis.
create or replace function public.meta_ads_dia()
returns table (dia date, gasto numeric, impressoes integer, cliques integer, conversas_meta integer, conversas_mari integer,
               com_cep integer, fora_area integer, qualificadas integer, atualizado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select d.dia, d.gasto, d.impressoes, d.cliques, d.conversas_meta, d.conversas_mari, d.com_cep, d.fora_area, d.qualificadas, d.atualizado_em
    from public.v_meta_ads_dia d
   where (select public.meu_perfil()) is not null or (select public.sou_agencia())
$$;
revoke all on function public.meta_ads_dia() from public, anon;
grant execute on function public.meta_ads_dia() to authenticated;

-- O que a tela Meta Ads tira das conversas e das vendas de anúncio, já contado por dia e por anúncio. É a mesma conta que a
-- tela fazia no navegador com as linhas de mari_conversas, vendas e v_mari_conversa_anuncio (22/11) — agora num lugar só.
--   conversas: por dia da conversa × anúncio (ad_id nulo = o WhatsApp não disse de qual anúncio veio)
--   vendas:    venda de anúncio com OS gerada, pelo dia da OS × anúncio
--   cep_ok_ad / vendas_conjunto / inicio_atrib: a campanha desde o início (os limites do agente de tráfego)
--   capi:      o que a Meta recebeu de volta (a v_meta_capi_painel sem o id do dataset)
create or replace function public.meta_ads_resultado()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if public.meu_perfil() is null and not public.sou_agencia() then
    return null;
  end if;
  with atrib as (
    select a.conversa_id, a.ad_id, a.adset_id, a.referral_em, a.cep, a.dentro_area, a.venda_id
      from public.v_mari_conversa_anuncio a where a.ad_id is not null
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
     where c.origem = 'meta_ads'
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
         where vd.com_os and vd.dia_os is not null group by vd.dia_os, va.ad_id) x), '[]'::jsonb),
    'cep_ok_ad', coalesce((select jsonb_object_agg(ad_id, n) from (
        select a.ad_id, count(*)::int as n from atrib a where coalesce(a.cep, '') <> '' and a.dentro_area is true group by a.ad_id) x), '{}'::jsonb),
    'vendas_conjunto', coalesce((select jsonb_object_agg(adset_id, n) from (
        select a.adset_id, count(*)::int as n from atrib a join vend vd on vd.id = a.venda_id
         where vd.com_os and a.adset_id is not null group by a.adset_id) x), '{}'::jsonb),
    'tem_atrib', exists (select 1 from atrib),
    'inicio_atrib', (select (min(a.referral_em) at time zone 'UTC')::date from atrib a),
    'capi', (select to_jsonb(p) - 'dataset_id' from public.v_meta_capi_painel p)
  ) into r;
  return r;
end $$;
revoke all on function public.meta_ads_resultado() from public, anon;
grant execute on function public.meta_ads_resultado() to authenticated;

-- BLOCO NOVO — "Por que os leads saíram": leads de anúncio que CHEGARAM no período (o mesmo recorte da tela) e foram para
-- Saída, por anúncio × motivo da lista única (config_lead). Só contagem: nenhuma linha de conversa, nenhum identificador.
-- Lead marcado como teste ou duplicado fica fora. Admin, backoffice e agência.
create or replace function public.meta_ads_motivos_saida(p_de date default null, p_ate date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and not public.sou_agencia() then
    return null;
  end if;
  with l as (
    select a.ad_id, x.destino, x.saida_motivo, x.saida_nome
      from public.v_leads x
      left join public.v_mari_conversa_anuncio a on a.conversa_id = x.conversa_id and a.ad_id is not null
     where x.origem = 'meta_ads' and coalesce(x.destino, '') <> 'teste_duplicada'
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
revoke all on function public.meta_ads_motivos_saida(date, date) from public, anon;
grant execute on function public.meta_ads_motivos_saida(date, date) to authenticated;

-- Placar: conversas novas e qualificadas por dia (o que a tela contava com as linhas de mari_conversas). Todos os que abrem
-- o Placar (admin, backoffice e agência).
create or replace function public.placar_conversas_dia(p_desde date)
returns table (dia date, conversas integer, qualificadas integer)
language sql stable security definer set search_path = public as $$
  with c as (
    select created_at, handoff_motivo, handoff_em from public.mari_conversas
     where created_at >= (p_desde::timestamp at time zone 'America/Sao_Paulo')
       and (coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice') or (select public.sou_agencia()))
  ), a as (
    select (created_at at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as n from c group by 1
  ), q as (
    select (handoff_em at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as n from c
     where handoff_motivo = 'dados_completos' and handoff_em is not null group by 1
  )
  select coalesce(a.dia, q.dia), coalesce(a.n, 0), coalesce(q.n, 0) from a full join q on q.dia = a.dia
$$;
revoke all on function public.placar_conversas_dia(date) from public, anon;
grant execute on function public.placar_conversas_dia(date) to authenticated;

-- Placar da agência: as vendas com OS SEM nome, telefone, CPF, endereço, vendedor, nº de pedido e comissão. O `n` é só um
-- número de ordem (não é o id da venda); as datas vão como dia (meio-dia de Brasília), sem a hora.
-- A OS de cada venda segue a regra de assets/vendasos.js: o pedido que casa com o nº da OS; sem casar, o que mudou por último.
create or replace function public.placar_agencia()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.sou_agencia() and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return null;
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.n), '[]'::jsonb) into r from (
    select row_number() over (order by coalesce(v.nio_os_em, v.vendido_em, v.criado_em) desc, v.id)::int as n,
           v.status,
           public._dia_sp_txt(v.criado_em) as criado_em,
           public._dia_sp_txt(v.vendido_em) as vendido_em,
           public._dia_sp_txt(v.nio_os_em) as nio_os_em,
           public._dia_sp_txt(v.instalado_em) as instalado_em,
           public._dia_sp_txt(v.instalacao_agendada_para) as instalacao_agendada_para,
           public._dia_sp_txt(v.cancelada_apos_instalar_em) as cancelada_apos_instalar_em,
           v.origem, v.plano_id, v.plano_nome, p.nome_curto as plano_nome_curto, v.forma_pagamento, v.cidade,
           o.estado as os_estado, o.agendamento_data as os_agendamento_data
      from public.v_vendas v
      left join public.config_planos p on p.id = v.plano_id
      left join lateral (
        select oa.estado, oa.agendamento_data from public.v_os_andamento oa
         where oa.venda_id = v.id
         order by coalesce(public._so_digitos(v.nio_os) <> '' and public._so_digitos(oa.pedido) = public._so_digitos(v.nio_os), false) desc,
                  oa.mudou_em desc nulls last
         limit 1) o on true
     where v.nio_os is not null) x;
  return r;
end $$;
revoke all on function public.placar_agencia() from public, anon;
grant execute on function public.placar_agencia() to authenticated;

-- Tabela e política para a agência: planos e adicionais SEM a comissão (o resto do time lê as tabelas, com a comissão).
-- A observação do plano também fica fora: é anotação nossa e fala de comissão.
create or replace function public.tabela_agencia()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sou_agencia() and public.meu_perfil() is null then
    return null;
  end if;
  return jsonb_build_object(
    'planos', coalesce((select jsonb_agg(to_jsonb(p) - 'comissao' - 'observacao' order by p.preco) from public.config_planos p
                         where p.vigencia_inicio <= (now() at time zone 'America/Sao_Paulo')::date), '[]'::jsonb),
    'adicionais', coalesce((select jsonb_agg(to_jsonb(a) - 'comissao' order by a.id) from public.config_adicionais a), '[]'::jsonb));
end $$;
revoke all on function public.tabela_agencia() from public, anon;
grant execute on function public.tabela_agencia() to authenticated;

-- A meta do mês (instaladas × meta, só números): a agência também recebe.
CREATE OR REPLACE FUNCTION public.painel_meta_ritmo(p_hoje date DEFAULT ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ini date := date_trunc('month', p_hoje)::date;
  v_fim date := (date_trunc('month', p_hoje) + interval '1 month - 1 day')::date;
  v_meta int; v_inst int; v_faltam int; v_dias int; v_pass int; v_ritmo numeric;
begin
  if auth.role() <> 'service_role' and public.meu_perfil() is null and not public.sou_agencia() then
    return null;
  end if;
  select meta_vendas into v_meta from public.config_metas where mes = v_ini and parceiro_id = 'dharma';
  select count(*) into v_inst
    from public.vendas v
   where v.instalado_em is not null
     and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
     and (v.instalado_em at time zone 'America/Sao_Paulo')::date between v_ini and v_fim;
  v_meta := coalesce(v_meta, 0);
  v_faltam := greatest(v_meta - v_inst, 0);
  -- 0099: dias úteis = dias de contato (sem domingo e sem feriado nacional/estadual), de hoje ao fim do mês.
  select count(*) into v_dias from generate_series(p_hoje, v_fim, interval '1 day') g(d)
   where public.mari_dia_permitido(g.d::date, null);
  -- 0112: dias úteis já passados no mês (do dia 1 até ontem) → ritmo atual e projeção.
  select count(*) into v_pass from generate_series(v_ini, p_hoje - 1, interval '1 day') g(d)
   where public.mari_dia_permitido(g.d::date, null);
  v_ritmo := case when v_pass > 0 then v_inst::numeric / v_pass else null end;
  return jsonb_build_object(
    'mes', to_char(v_ini, 'YYYY-MM'),
    'meta', v_meta,
    'instaladas', v_inst,
    'faltam', v_faltam,
    'dias_restantes', v_dias,
    'dias_uteis', true,
    'por_dia', case when v_dias > 0 then round(v_faltam::numeric / v_dias, 1) else v_faltam end,
    'pct', case when v_meta > 0 then round(100.0 * v_inst / v_meta, 1) else null end,
    'dias_passados', v_pass,
    'dias_mes', v_pass + v_dias,
    'ritmo_dia', round(coalesce(v_ritmo, 0), 2),
    'projecao', round(v_inst + coalesce(v_ritmo, 0) * v_dias),
    'deveria_hoje', case when v_pass + v_dias > 0 then round(v_meta::numeric * v_pass / (v_pass + v_dias), 1) else 0 end
  );
end $function$;

-- ───────────── 5. a conta fecha todo dia (regra 20.5) ─────────────
-- Devolve a lista do que estiver ABERTO DEMAIS para a agência. Vazia = certo. Olha a estrutura (não espera existir usuário):
--   a) meu_perfil() continua escondendo a agência (senão todas as policies "qualquer perfil" abrem para ela);
--   b) policy que cita sou_agencia() fora da lista do que ela pode ler, ou que não é só SELECT;
--   c) tabela com dado de cliente (ou linha de lead) legível por qualquer login;
--   d) visão que roda como dona (sem security_invoker) e não está entre as conferidas;
--   e) função que cita sou_agencia() e não está entre as conferidas (função nova para a agência = conferir e pôr na lista).
create or replace function public.agencia_leituras_indevidas()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  achados text[] := '{}';
  tabelas_ok text[] := array['usuarios', 'meta_ads_diario', 'meta_ads_anuncios', 'meta_ads_conjuntos', 'meta_ads_posicionamento_diario',
                             'config_meta_ads_regras', 'config_metas', 'config_area', 'dfv_bairros_pronto'];
  visoes_ok text[] := array['v_jornada', 'v_canais_7d', 'v_contatos_limite'];   -- conferidas em 22/11: não devolvem cliente a quem não tem perfil
  funcoes_ok text[] := array['sou_agencia', 'meta_ads_dia', 'meta_ads_resultado', 'meta_ads_motivos_saida', 'placar_conversas_dia',
                             'placar_agencia', 'tabela_agencia', 'painel_meta_ritmo', 'agencia_leituras_indevidas'];
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
  return to_jsonb(achados);
end $$;
revoke all on function public.agencia_leituras_indevidas() from public, anon;
grant execute on function public.agencia_leituras_indevidas() to authenticated;

-- conferencia_itens(): a mesma da produção em 22/11 (0343) com o item 29 no fim.
CREATE OR REPLACE FUNCTION public.conferencia_itens(p_parceiro text DEFAULT 'dharma'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  it     jsonb := '[]'::jsonb;
  n      int;
  n2     int;
  ex     text;
  v_tot  int;
  v_soma int;
begin
  if not public._os_pode_gravar() then   -- admin, backoffice, chave de serviço ou CLI
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;

  -- 1. A soma dos destinos é o total de leads
  select count(*) into v_tot from public.v_leads;
  select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.v_leads where destino is not null group by destino) x;
  it := it || jsonb_build_object('codigo', 'soma_destinos', 'nome', 'Soma dos destinos = total de leads',
    'nivel', case when v_tot = v_soma then 'ok' else 'falha' end, 'n', v_tot - v_soma,
    'texto', format('%s leads; os destinos somam %s', v_tot, v_soma),
    'fazer', case when v_tot = v_soma then null else 'Há lead sem destino: avisar o Claude Code (é defeito da v_leads).' end);

  -- 2. Lead em andamento sem vez / sem status · saída sem motivo
  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'em_andamento' and (vez is null or status is null)) x;
  it := it || jsonb_build_object('codigo', 'lead_sem_vez', 'nome', 'Todo lead em andamento tem status e vez',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todos com status e de quem é a vez' else format('%s lead(s) sem status ou sem vez: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir cada um na Leads e registrar o que falta; se o sistema não deixar, avisar o Claude Code.' end);

  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'saida' and saida_motivo is null) x;
  it := it || jsonb_build_object('codigo', 'saida_sem_motivo', 'nome', 'Toda saída tem motivo',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as saídas com motivo da lista única' else format('%s saída(s) sem motivo: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha e registrar o motivo da Saída.' end);

  -- 3. Prazo vencido (ninguém parado em silêncio): fecha, mas é para olhar hoje
  select count(*) into n from public.v_leads where destino = 'em_andamento' and atrasado and not em_espera;
  it := it || jsonb_build_object('codigo', 'atrasados', 'nome', 'Leads com o prazo da vez vencido',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead com prazo vencido' else format('%s lead(s) com o prazo vencido', n) end,
    'fazer', case when n = 0 then null else 'Leads › aba Precisam de ação.' end);

  -- 4. NIOGEN × Nio — venda sem pedido
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select cliente_nome, row_number() over (order by criado_em desc) rn from public.vendas
           where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio')
             and coalesce(nullif(btrim(nio_os), ''), nullif(btrim(nio_pedido), '')) is null) x;
  it := it || jsonb_build_object('codigo', 'venda_sem_pedido', 'nome', 'Toda venda tem o nº do pedido da Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as vendas com pedido' else format('%s venda(s) sem nº de pedido: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Gravar o nº do pedido do portal na ficha.' end);

  -- 5. NIOGEN × Nio — OS aberta que o Operador de OS nunca leu (há mais de 6 h)
  select count(*), string_agg(ped, ', ') filter (where rn <= 5) into n, ex
    from (select coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) as ped,
                 row_number() over (order by v.criado_em desc) rn
            from public.vendas v
           where v.status in ('1_vendido', '2_aguardando_instalacao')
             and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) ~ '^\d{8}$'
             and coalesce(v.nio_os_em, v.nio_pedido_em, v.vendido_em, v.criado_em) < now() - interval '6 hours'
             and not exists (select 1 from public.os_andamento a where a.parceiro_id = p_parceiro
                              and a.pedido = coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')))) x;
  it := it || jsonb_build_object('codigo', 'os_sem_leitura', 'nome', 'Toda OS aberta foi lida na Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as OS abertas com leitura do Operador de OS' else format('%s OS sem nenhuma leitura: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Operações › ⟳ Varrer OS abertas. Se não ler, conferir o CPF e o nº da OS da venda.' end);

  -- 6. NIOGEN × Nio — a Nio enxerga pedido que o NIOGEN não tem
  select count(*) into n from public.portal_pedidos p
   where p.parceiro_id = p_parceiro and p.venda_id is null and upper(coalesce(p.tipo, '')) = 'VENDA'
     and p.ultima_leitura > now() - interval '30 days';
  select coalesce((i.resumo ->> 'sem_venda')::int, 0) into n2 from public.importacoes i
   where i.tipo = 'osab' and i.aplicado_em is not null order by i.aplicado_em desc limit 1;
  it := it || jsonb_build_object('codigo', 'pedido_sem_venda', 'nome', 'Pedido na Nio sem venda no NIOGEN',
    'nivel', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'ok' else 'atencao' end, 'n', coalesce(n, 0) + coalesce(n2, 0),
    'texto', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'nenhum pedido da Nio sem venda nossa'
                  else format('%s no Histórico do portal e %s no último OSAB', coalesce(n, 0), coalesce(n2, 0)) end,
    'fazer', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then null else 'Live › Conferir › casar o pedido com a venda (ou registrar a venda que falta).' end);

  -- 7. NIOGEN × Nio — texto novo da Nio sem tradução e exceção de OS parada há mais de 1 dia
  select count(*), string_agg(texto, ' · ') into n, ex from public.config_os_estados where parceiro_id = p_parceiro and estado is null;
  it := it || jsonb_build_object('codigo', 'os_texto_novo', 'nome', 'Textos da Nio traduzidos',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todos os textos da OS conhecidos' else format('%s texto(s) sem tradução: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Ricardo para traduzir (config_os_estados). Enquanto isso a venda não muda sozinha.' end);

  select count(*) into n from public.os_andamento where parceiro_id = p_parceiro and excecao and excecao_desde < now() - interval '1 day';
  it := it || jsonb_build_object('codigo', 'os_excecao_parada', 'nome', 'Exceção de OS tratada no mesmo dia',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma exceção de OS aberta há mais de 1 dia' else format('%s exceção(ões) de OS aberta(s) há mais de 1 dia', n) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › linhas "OS … na Nio".' end);

  -- 8. NIOGEN × Chatwoot — conversa mexida fora e ação que o Chatwoot não obedeceu
  select count(*) into n from public.mari_conversas c
   where c.canal = 'whatsapp' and c.funil_alerta is not null and coalesce(c.telefone, '') not like '5500000000%';
  select count(*) into n2 from public.chatwoot_acoes a
   where a.status = 'erro' and a.criada_em > now() - interval '7 days'
     and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                       and b.status = 'feita' and b.criada_em > a.criada_em);
  it := it || jsonb_build_object('codigo', 'chatwoot', 'nome', 'NIOGEN e Chatwoot dizem a mesma coisa',
    'nivel', case when n + n2 = 0 then 'ok' else 'atencao' end, 'n', n + n2,
    'texto', case when n + n2 = 0 then 'nenhuma conversa mexida fora e nenhuma ação em erro'
                  else format('%s conversa(s) mexida(s) direto no Chatwoot · %s ação(ões) que o Chatwoot não obedeceu', n, n2) end,
    'fazer', case when n + n2 = 0 then null else 'Live › Conferir.' end);

  -- 9. Dinheiro — toda instalada tem a comissão prevista lançada
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select v.cliente_nome, row_number() over (order by v.instalado_em desc) rn from public.vendas v
           where v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.instalado_em is not null
             and coalesce(v.comissao_prevista, 0) > 0
             and not exists (select 1 from public.comissao_lancamentos l where l.venda_id = v.id and l.tipo = 'prevista')) x;
  it := it || jsonb_build_object('codigo', 'instalada_sem_previsto', 'nome', 'Toda instalada tem a comissão prevista lançada',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as instaladas com o previsto na razão da comissão' else format('%s instalada(s) sem o previsto: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: a razão da comissão não lançou o previsto.' end);

  -- 10. Dinheiro — previsto × extrato (só quando houver Extrato importado e conciliado: etapa 5c)
  select count(*) into n from public.comissao_lancamentos where parceiro_id = p_parceiro and origem = 'extrato';
  it := it || jsonb_build_object('codigo', 'previsto_extrato', 'nome', 'Comissão prevista × Extrato da Nio',
    'nivel', case when n = 0 then 'sem_dado' else 'ok' end, 'n', n,
    'texto', case when n = 0 then 'o Extrato da Nio ainda não foi conciliado (etapa 5c do plano)' else format('%s lançamento(s) do extrato', n) end,
    'fazer', null);

  -- 11. 0182 — risco de recompra: venda em andamento com CPF ou endereço repetido e ainda sem o "Conferi" (só aviso)
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') into n, ex from public.v_venda_risco_recompra;
  it := it || jsonb_build_object('codigo', 'risco_recompra', 'nome', 'Venda em andamento sem risco de recompra',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma venda em andamento com CPF ou endereço repetido' else format('%s venda(s) com CPF ou endereço repetido: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Conferir no portal antes de gravar o pedido e marcar "Conferi" na ficha. Recompra = multa de R$ 500.' end);

  -- 12. 0183 — o vermelho do pulso tem dono: incidente "Mari parada" sem nenhum cliente esperando (últimas 24 h; sem crédito não conta)
  select count(*), string_agg(to_char(inicio_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ', ' order by inicio_em) into n, ex
    from public.pulso_incidentes
   where parceiro_id = p_parceiro and elo = 'mari' and nivel = 'parado' and clientes_esperando_max = 0
     and inicio_em > now() - interval '24 hours' and coalesce(motivo, '') not ilike 'sem crédito%';
  it := it || jsonb_build_object('codigo', 'pulso_mari_sem_espera', 'nome', 'Alarme da Mari só com cliente esperando',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum alarme vermelho da Mari sem cliente esperando nas últimas 24 h'
                  else format('%s alarme(s) vermelho(s) da Mari sem cliente esperando: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o pulso acusou a Mari sem ninguém esperando (ver pulso_incidentes e Mari › Erros).' end);

  -- 13. 0186 — o caminho de volta para a Meta: evento na fila com erro, ou venda de anuncio cuja OS nao virou Purchase enviado
  select count(*), string_agg(distinct evento, ', ') into n, ex from public.meta_eventos
   where parceiro_id = p_parceiro and status = 'erro';
  -- só conta o que já passou de 1 h: a fila normal esvazia de 5 em 5 min
  select count(*) into n2 from public.v_venda_meta vm
   where vm.tem_os and vm.meta_status = 'sem_evento'
      or (vm.tem_os and vm.meta_status = 'pendente'
          and exists (select 1 from public.meta_eventos e where e.venda_id = vm.venda_id and e.evento = 'Purchase'
                        and e.criado_em < now() - interval '1 hour'));
  it := it || jsonb_build_object('codigo', 'meta_capi', 'nome', 'A Meta recebeu o que o NIOGEN gravou',
    'nivel', case when n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', n + n2,
    'texto', case when n > 0 then format('%s evento(s) com erro de envio (%s)', n, left(coalesce(ex, ''), 60))
                  when n2 > 0 then format('%s venda(s) de anuncio esperando o Purchase na fila', n2)
                  else 'nenhum erro de envio e nenhuma venda de anuncio parada na fila' end,
    'fazer', case when n > 0 then 'Avisar o Claude Code: ver meta_eventos (resposta e fbtrace_id) e o workflow meta_capi_envio. Nao reenviar a mao.'
                  when n2 > 0 then 'Se passar de 1 h, o workflow meta_capi_envio pode estar parado: avisar o Claude Code.'
                  else null end);


  -- 14. 0202 — conferir a rua: o portal consultou outra rua e ninguém conferiu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where rua_conferir_em is not null and rua_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_rua', 'nome', 'Rua conferida em até 4 h quando o portal consulta outra rua',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma conferência de rua parada há mais de 4 h' else format('%s conversa(s) com a rua por conferir há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Portal: outra rua": refazer na Cobertura escolhendo a rua do cliente e marcar "Conferi".' end);

  -- 15. 0202 — a DFV ao vivo sai pela API do Power BI (o operador da VPS é só reserva)
  select count(*), count(*) filter (where coalesce(detalhe ->> 'fonte', '') <> 'api') into n, n2
    from public.operador_consultas where tipo = 'dfv'
     and criado_em > greatest(now() - interval '24 hours', timestamptz '2026-11-14 20:10-03');   -- API no ar desde 14/11 20h10
  it := it || jsonb_build_object('codigo', 'dfv_pela_api', 'nome', 'DFV consultada pela API do Power BI',
    'nivel', case when n = 0 or n2 * 100 <= n * 5 then 'ok' else 'atencao' end, 'n', n2,
    'texto', case when n = 0 then 'nenhuma consulta DFV nas últimas 24 h' else format('%s de %s consulta(s) DFV nas últimas 24 h fora da API', n2, n) end,
    'fazer', case when n = 0 or n2 * 100 <= n * 5 then null else 'A Nio pode ter republicado o relatório (chave/modelId mudaram): avisar o Claude Code — config_regras.dfv_api.' end);

  -- 16. 0218 — ninguém parado em silêncio: vez da Mari, conversa ativa, sem próximo toque e sem prazo
  select count(*), string_agg(coalesce(nullif(btrim(l.nome), ''), 'sem nome'), ', ' order by l.ultima_em desc) into n, ex
    from public._lead_em_silencio() s join public.v_leads l on l.conversa_id = s.conversa_id;
  it := it || jsonb_build_object('codigo', 'lead_em_silencio', 'nome', 'Ninguém parado em silêncio (vez da Mari sem próximo toque)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todo lead com a vez da Mari tem o próximo toque marcado ou um prazo'
                  else format('%s lead(s) com a vez da Mari, sem próximo toque e sem prazo: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir na Live e dar saída, esquentar (🔥) ou assumir. Se a cadência deveria ter marcado o próximo toque, avisar o Claude Code.' end);

  -- 17. 0228 (revisão dos fluxos) — Saída com dono: lead em Saída cuja conversa segue aberta com pessoa ou time no Chatwoot
  -- há mais de 1 h (a Saída devolve para a Mari na hora; "já é cliente Nio" e "não contatar" ficam de fora).
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and (v.status = 'saida' or (c.venda_id is null and c.saida_em is not null and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')))
     and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente') and not coalesce(c.nao_contatar, false)
     and c.chatwoot_status in ('open', 'pending') and (c.chatwoot_agente is not null or c.chatwoot_time is not null)
     and coalesce(c.saida_em, c.funil_destino_em, c.created_at) < now() - interval '1 hour';
  it := it || jsonb_build_object('codigo', 'saida_com_dono', 'nome', 'Lead em Saída sem dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead em Saída com a conversa aberta e com dono' else format('%s lead(s) em Saída ainda com pessoa ou time no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha: se o cliente ainda quer seguir, Reabrir; senão "Devolver para a Mari". Se voltar a acontecer, avisar o Claude Code.' end);

  -- 18. 0228 — mensagem automática com a conversa assumida por uma pessoa (pela fila do NIOGEN, na voz da Mari, ou a Mari
  -- respondendo o cliente), nas últimas 24 h. "Assumida" = a última ação de pessoa feita pelo NIOGEN foi atribuir.
  select count(*), string_agg(distinct nome, ', ') into n, ex from (
    select c.nome_contato as nome from public.chatwoot_acoes a join public.mari_conversas c on c.id = a.conversa_id
     where a.tipo = 'mensagem' and a.status = 'feita' and a.criada_em > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')
       and coalesce(a.payload ->> 'como', '') <> 'humano' and coalesce(c.telefone, '') not like '5500000000%'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < a.criada_em order by b.criada_em desc limit 1) = 'atribuir'
    union all
    select c.nome_contato from public.mari_turnos t join public.mari_conversas c on c.id = t.conversa_id
     where t.papel = 'mari' and t.created_at > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')   -- correções no ar desde 15/11 ~20h and coalesce(c.telefone, '') not like '5500000000%'
       and (select p.papel from public.mari_turnos p where p.conversa_id = t.conversa_id and p.papel <> 'sistema' and p.created_at < t.created_at
              order by p.created_at desc limit 1) = 'lead'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = t.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < t.created_at order by b.criada_em desc limit 1) = 'atribuir') x;
  it := it || jsonb_build_object('codigo', 'msg_auto_assumida', 'nome', 'Nada automático fala por cima de quem assumiu',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma mensagem automática com a conversa assumida nas últimas 24 h' else format('%s mensagem(ns) automática(s) com a conversa assumida: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code (guard da Mari ou botão sem o "em nome da pessoa"). Ver a conversa e, se precisar, corrigir com o cliente.' end);

  -- 19. 0228 — o banco diz "pessoa/time atribuído" e o Chatwoot diz sem dono (a 0227 espelha; isto acha o que escapar)
  select count(*), string_agg(coalesce(c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' and c.chatwoot_sync_em < now() - interval '10 minutes'
     and ((c.humano_atribuido and c.chatwoot_agente is null) or (c.time_atribuido and c.chatwoot_time is null and c.chatwoot_agente is null))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir' and a.status in ('pendente', 'executando'));
  it := it || jsonb_build_object('codigo', 'dono_banco_chatwoot', 'nome', 'Dono no NIOGEN = dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todo dono no banco também está no Chatwoot' else format('%s conversa(s) com dono no banco e sem dono no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o espelho do Chatwoot (0227) deixou passar. Enquanto isso a cadência dessas conversas fica parada.' end);

  -- 20. 0233 — unidade a confirmar: a unidade do cliente não está na lista da Nio e ninguém resolveu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where unidade_conferir_em is not null and unidade_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_unidade', 'nome', 'Unidade confirmada em até 4 h quando não bate com a lista da Nio',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma unidade por confirmar há mais de 4 h' else format('%s conversa(s) com a unidade por confirmar há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Unidade a confirmar": confirmar a unidade com o cliente ou pedir o cadastro à Nio e marcar "Conferi".' end);

  -- 21. 0239 — Fila Vero (módulo desligável): a conta da fila fecha
  if to_regclass('public.fila_vero') is not null then
    select count(*) into v_tot from public.fila_vero;
    select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.fila_vero group by status) x;
    select count(*) into n from public.fila_vero
     where (status in ('ja_cliente_nio') and toques > 0)
        or (status = 'opt_out' and ultimo_toque_em > (select max(e.em) from public.fila_vero_eventos e
                                                       where e.fila_id = fila_vero.id and e.para = 'opt_out'));
    select count(*) into n2 from public.fila_vero
     where status = 'enviado' and coalesce(meta_status, 'accepted') = 'accepted' and ultimo_toque_em < now() - interval '24 hours';
    it := it || jsonb_build_object('codigo', 'fila_vero', 'nome', 'Fila Vero: soma por status = total · nenhum toque proibido · status da Meta em 24 h',
      'nivel', case when v_tot <> v_soma or n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', (v_tot - v_soma) + n + n2,
      'texto', format('%s na fila (status somam %s) · %s toque(s) em já cliente/opt-out · %s enviado(s) sem status da Meta há mais de 24 h',
                      v_tot, v_soma, n, n2),
      'fazer', case when v_tot <> v_soma or n > 0 then 'Avisar o Claude Code: a fila da Vero tocou quem não podia ou perdeu linha.'
                    when n2 > 0 then 'Conferir o webhook do número do disparo (n8n fila_vero_webhook).' else null end);
    -- 0242: cota do dia e apto parado com o disparo ligado
    select count(*) into n from public.contatos_cliente where toque = 'fila_vero' and direcao = 'saida'
       and (em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
    n2 := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'fila_vero_ritmo_dia'), 100);
    it := it || jsonb_build_object('codigo', 'fila_vero_cota', 'nome', 'Fila Vero: envios de hoje dentro do ritmo do dia',
      'nivel', case when n <= n2 then 'ok' else 'falha' end, 'n', greatest(0, n - n2),
      'texto', format('%s envio(s) hoje · ritmo %s/dia', n, n2),
      'fazer', case when n <= n2 then null else 'Pausar a Fila Vero na tela e avisar o Claude Code.' end);
    select count(*) into n from public.fila_vero where status = 'apto' and atualizado_em < now() - interval '7 days'
       and coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'fila_vero_ativo'), false);
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_apto_parado', 'nome', 'Fila Vero: apto parado há mais de 7 dias com o disparo ligado',
        'nivel', 'atencao', 'n', n, 'texto', format('%s apto(s) esperando há mais de 7 dias', n),
        'fazer', 'Ver na tela Fila Vero se o ritmo está baixo ou se a faixa B está fora do disparo.');
    end if;
    select count(*) into n from public.fila_vero where status = 'respondeu' and conversa_id is null;
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_sem_conversa', 'nome', 'Fila Vero: quem respondeu tem conversa na Mari',
        'nivel', 'falha', 'n', n, 'texto', format('%s resposta(s) sem conversa ligada', n),
        'fazer', 'Avisar o Claude Code (gatilho mari_turnos_fila_vero).');
    end if;
  end if;


  -- 22. 0302 — origem conhecida: lead das últimas 24 h com a origem desconhecida (dono: backoffice; sai quando a origem é corrigida)
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ' order by c.created_at desc) into n, ex
    from public.mari_conversas c
   where c.origem = 'desconhecida' and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and coalesce(c.funil_destino, '') <> 'teste_duplicada' and c.created_at > now() - interval '24 hours';
  it := it || jsonb_build_object('codigo', 'origem_desconhecida', 'nome', 'Todo lead novo tem a origem conhecida (últimas 24 h)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead das últimas 24 h com a origem desconhecida'
                  else format('%s lead(s) das últimas 24 h sem origem: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Backoffice: perguntar ao cliente por onde chegou e corrigir em Configurações › Canais › Origem a conferir.' end);

  -- 23. 0302 — o card "Canais" fecha com a v_margem_canal (vendas por origem, desde sempre)
  select count(*), string_agg(format('%s: card %s × margem %s', coalesce(m.origem, '(sem origem)'), coalesce(r.vendas, 0), m.vendas), ' · ') into n, ex
    from public.v_margem_canal m
    left join public.canais_resumo(3650) r on r.canal = m.origem
   where coalesce(r.vendas, 0) <> m.vendas;
  it := it || jsonb_build_object('codigo', 'canais_conta', 'nome', 'Card Canais = v_margem_canal (vendas por origem)',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'as vendas por canal do card batem com a margem por canal' else left(ex, 200) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o card Canais e a v_margem_canal contam diferente (é defeito).' end);

  -- 24. 0303 — pedido de indicação: nenhum aberto além da validade (a rotina indicacao_rotina fecha)
  if to_regclass('public.indicacao_pedidos') is not null then
    select count(*) into n from public.indicacao_pedidos where estado = 'pediu' and pedido_em < now() - interval '8 days';
    select count(*) into n2 from public.indicacao_pedidos where pedido_em > now() - interval '7 days';
    select count(*) into v_tot from public.indicacoes where criado_em > now() - interval '7 days' and estado <> 'invalida';
    it := it || jsonb_build_object('codigo', 'indicacao_pedidos', 'nome', 'Pedido de indicação: nenhum aberto além da validade',
      'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
      'texto', format('%s pedido(s) de indicação em 7 dias · %s indicação(ões) recebida(s) · %s aberto(s) além da validade', n2, v_tot, n),
      'fazer', case when n = 0 then null else 'Avisar o Claude Code: a rotina indicacao_rotina não fechou os pedidos vencidos.' end);
  end if;

  -- 25. 0330 — crédito num lugar só: a venda diz o mesmo que a conversa (o espelho grava os dois; divergência = alguém precisa olhar:
  -- "aprovado" do botão sobre o "só cartão" lido pelo operador, venda com aviso de recompra esperando a conferência, erro do espelho)
  select count(*), string_agg(format('%s (venda %s × portal %s)', coalesce(nullif(btrim(v.cliente_nome), ''), 'sem nome'), v.credito_resultado,
           c.credito_resultado), ', ' order by v.criado_em desc) into n, ex
    from public.vendas v
    join lateral (select * from public.mari_conversas mc where mc.venda_id = v.id order by mc.created_at desc limit 1) c on true
   where v.status not in ('saida')
     and public._credito_categoria(c.credito_resultado) is not null
     and v.credito_resultado is distinct from public._credito_categoria(c.credito_resultado);
  it := it || jsonb_build_object('codigo', 'credito_um_lugar', 'nome', 'Crédito da venda = crédito lido do portal',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'toda venda em andamento com o mesmo crédito da conversa' else left(format('%s venda(s) com o crédito diferente: %s', n, ex), 240) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha › Crédito: conferir no portal e Corrigir com o motivo (vale a leitura mais nova do portal).' end);

  -- 26. 0330 — correções do crédito à mão (7 dias): muitas "o robô leu errado" = conserto no robô, não mais cliques
  select count(*), count(*) filter (where e.detalhe ->> 'motivo' = 'robo_errou') into n, n2
    from public.eventos_venda e where e.tipo = 'credito_corrigido' and e.criado_em > now() - interval '7 days';
  it := it || jsonb_build_object('codigo', 'credito_corrigido', 'nome', 'Correções do crédito à mão (7 dias)',
    'nivel', case when n2 >= 2 then 'atencao' else 'ok' end, 'n', n2,
    'texto', format('%s correção(ões) em 7 dias · %s por "o robô leu errado"', n, n2),
    'fazer', case when n2 >= 2 then 'Avisar o Claude Code: o operador de crédito leu errado mais de uma vez na semana.' else null end);

  -- 27. 0339 — leitura do atendimento pelas mensagens (v_atendimento_fatos): o cliente escreveu por último e ninguém respondeu.
  -- É a ÚNICA prova de falha de atendimento. Conta só lead em andamento, há mais de 15 min (a Mari responde em segundos).
  select count(*), string_agg(format('%s (%s min)', coalesce(nullif(btrim(f.nome), ''), 'sem nome'), f.esperando_nos_min), ', ' order by f.esperando_nos_min desc)
    into n, ex
    from public.v_atendimento_fatos f where f.caixa = 'esperando_nos' and f.esperando_nos_min > 15;
  it := it || jsonb_build_object('codigo', 'esperando_nos', 'nome', 'Ninguém esperando resposta nossa (pelas mensagens)',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todo cliente que escreveu foi respondido (mensagem a mensagem)'
                  else left(format('%s cliente(s) escreveram por último e estão sem resposta: %s', n, ex), 240) end,
    'fazer', case when n = 0 then null else 'Abrir a conversa e responder agora. Se a Mari deveria ter respondido, avisar o Claude Code.' end);

  -- 28. 0339 — calado e esquecido: em andamento, sem venda, cliente calado há mais de 24 h, sem toque marcado, sem Retomada,
  -- sem dono e sem espera. Pela regra 20 não pode existir. Complementa o 'lead_em_silencio' (que lê pela vez).
  select count(*), string_agg(coalesce(nullif(btrim(f.nome), ''), 'sem nome'), ', ' order by f.ult_cliente_em desc nulls last) into n, ex
    from public.v_atendimento_fatos f where f.caixa = 'calado_esquecido';
  it := it || jsonb_build_object('codigo', 'calado_esquecido', 'nome', 'Ninguém calado sem cadência (pelas mensagens)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todo cliente calado tem cadência, Retomada, dono ou espera'
                  else left(format('%s lead(s) calado(s) sem nenhum próximo toque: %s', n, ex), 240) end,
    'fazer', case when n = 0 then null else 'Abrir na Live e dar saída, esquentar (🔥) ou assumir. Se a cadência deveria ter marcado o toque, avisar o Claude Code.' end);

  -- 29. 0361 — perfil agencia: só lê o que é dela. A lista do que estiver aberto demais vem de agencia_leituras_indevidas()
  -- (meu_perfil() escondendo a agência, policies fora da lista, tabela com dado de cliente aberta a qualquer login).
  select coalesce(jsonb_array_length(a.j), 0), (select string_agg(x, ' · ') from jsonb_array_elements_text(a.j) x) into n, ex
    from (select public.agencia_leituras_indevidas() as j) a;
  it := it || jsonb_build_object('codigo', 'agencia_leitura', 'nome', 'Perfil agência não lê dado de cliente',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'a agência só lê Meta Ads, Placar e Tabela, em contagens'
                  else left(format('%s abertura(s) a mais: %s', n, ex), 240) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code hoje: alguma permissão foi afrouxada e a agência pode estar vendo o que não deve.' end);

  return it;
end;
$function$;

commit;
