-- NIOGEN | supabase/migrations/0161_menos_escrita.sql | 13/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 13/11 ~01h50: "Vamos aliviar isso também" — depois do e-mail da Supabase (orçamento de Disk IO esgotando, plano Free).
-- Resultado buscado: o banco parar de regravar o que não mudou. Nenhum dado, coluna, tela ou fluxo muda de comportamento.
--
-- 1. Meta Ads (n8n meta_ads_coleta, a cada 15 min, lê hoje e os 2 dias anteriores): meta_ads_gravar, meta_ads_gravar_posicionamentos
--    e meta_ads_gravar_conjuntos regravavam TODAS as linhas a cada rodada, mudasse ou não — 45 mil atualizações em
--    meta_ads_posicionamento_diario, 23 mil em meta_ads_diario e 15 mil em meta_ads_anuncios desde 04/11. Agora só entra no
--    upsert a linha nova ou a que mudou de valor; a igual nem é tocada (nem trava de linha). atualizado_em passa a dizer quando o
--    número mudou. O "lido há" do pulso não depende disso: ele usa meta_ads_conta_saldo.coletado_em, que segue a cada rodada.
-- 2. parceiro_oportunidades_abertas (canal parceiro da Live, ~1×/min por aba aberta): criava e apagava uma tabela temporária a
--    cada chamada — escrita no catálogo do banco (~25 KB de WAL por chamada). Agora é uma consulta só, com o mesmo resultado,
--    o mesmo filtro de "enviada/dispensada nas últimas N horas" e o mesmo registro de "mostrada".
-- Ensaio em transação desfeita: payload montado das linhas de hoje → 0 linhas regravadas; um valor trocado → 1; canal parceiro:
-- função nova = função antiga.

-- ───────────────────────── 1a. anúncio × dia + status dos anúncios ─────────────────────────
create or replace function public.meta_ads_gravar(p_insights jsonb, p_anuncios jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  v_ins int := 0;
  v_ads int := 0;
begin
  if jsonb_typeof(coalesce(p_insights, '[]'::jsonb)) <> 'array' or jsonb_typeof(coalesce(p_anuncios, '[]'::jsonb)) <> 'array' then
    raise exception 'p_insights e p_anuncios precisam ser arrays (o "data" da Graph API)' using errcode = '22023';
  end if;

  with novos as (
    select (r ->> 'date_start')::date as dia, r ->> 'ad_id' as ad_id, r ->> 'ad_name' as ad_nome, r ->> 'adset_id' as adset_id,
           r ->> 'adset_name' as adset_nome, r ->> 'campaign_id' as campanha_id, r ->> 'campaign_name' as campanha_nome,
           coalesce((r ->> 'spend')::numeric, 0) as gasto, coalesce((r ->> 'impressions')::int, 0) as impressoes,
           coalesce((r ->> 'reach')::int, 0) as alcance, coalesce((r ->> 'clicks')::int, 0) as cliques,
           coalesce((select sum((a ->> 'value')::numeric)::int from jsonb_array_elements(coalesce(r -> 'actions', '[]'::jsonb)) a
                      where a ->> 'action_type' = 'onsite_conversion.messaging_conversation_started_7d'), 0) as conversas,
           r -> 'actions' as acoes
      from jsonb_array_elements(coalesce(p_insights, '[]'::jsonb)) r
     where r ->> 'ad_id' is not null and r ->> 'date_start' is not null
  ), mudou as (
    select n.* from novos n
     where not exists (
       select 1 from public.meta_ads_diario x
        where x.dia = n.dia and x.ad_id = n.ad_id
          and (x.ad_nome, x.adset_id, x.adset_nome, x.campanha_id, x.campanha_nome, x.gasto, x.impressoes, x.alcance, x.cliques, x.conversas)
              is not distinct from (n.ad_nome, n.adset_id, n.adset_nome, n.campanha_id, n.campanha_nome, n.gasto, n.impressoes, n.alcance, n.cliques, n.conversas)
          and x.acoes is not distinct from n.acoes)
  )
  insert into public.meta_ads_diario as d
    (dia, ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome,
     gasto, impressoes, alcance, cliques, conversas, acoes, atualizado_em)
  select m.dia, m.ad_id, m.ad_nome, m.adset_id, m.adset_nome, m.campanha_id, m.campanha_nome,
         m.gasto, m.impressoes, m.alcance, m.cliques, m.conversas, m.acoes, now()
    from mudou m
  on conflict (dia, ad_id) do update set
    ad_nome = excluded.ad_nome, adset_id = excluded.adset_id, adset_nome = excluded.adset_nome,
    campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    gasto = excluded.gasto, impressoes = excluded.impressoes, alcance = excluded.alcance,
    cliques = excluded.cliques, conversas = excluded.conversas, acoes = excluded.acoes, atualizado_em = now();
  get diagnostics v_ins = row_count;

  with novos as (
    select r ->> 'id' as ad_id, r ->> 'name' as ad_nome, r ->> 'adset_id' as adset_id, r -> 'adset' ->> 'name' as adset_nome,
           r ->> 'campaign_id' as campanha_id, r -> 'campaign' ->> 'name' as campanha_nome, r ->> 'effective_status' as status_efetivo
      from jsonb_array_elements(coalesce(p_anuncios, '[]'::jsonb)) r
     where r ->> 'id' is not null
  ), mudou as (
    select n.* from novos n
     where not exists (
       select 1 from public.meta_ads_anuncios x
        where x.ad_id = n.ad_id
          and (x.ad_nome, x.adset_id, x.adset_nome, x.campanha_id, x.campanha_nome, x.status_efetivo)
              is not distinct from (n.ad_nome, n.adset_id, n.adset_nome, n.campanha_id, n.campanha_nome, n.status_efetivo))
  )
  insert into public.meta_ads_anuncios as a
    (ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, status_efetivo, atualizado_em)
  select m.ad_id, m.ad_nome, m.adset_id, m.adset_nome, m.campanha_id, m.campanha_nome, m.status_efetivo, now()
    from mudou m
  on conflict (ad_id) do update set
    ad_nome = excluded.ad_nome, adset_id = excluded.adset_id, adset_nome = excluded.adset_nome,
    campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    status_efetivo = excluded.status_efetivo, atualizado_em = now();
  get diagnostics v_ads = row_count;

  return jsonb_build_object('ok', true, 'insights', v_ins, 'anuncios', v_ads,
                            'recebidos', jsonb_array_length(coalesce(p_insights, '[]'::jsonb)) + jsonb_array_length(coalesce(p_anuncios, '[]'::jsonb)),
                            'em', now());
end $function$;

-- ───────────────────────── 1b. conjunto × posicionamento × dia ─────────────────────────
create or replace function public.meta_ads_gravar_posicionamentos(p_insights jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  v_n int := 0;
begin
  if jsonb_typeof(coalesce(p_insights, '[]'::jsonb)) <> 'array' then
    raise exception 'p_insights precisa ser array (o "data" da Graph API)' using errcode = '22023';
  end if;

  with novos as (
    select (r ->> 'date_start')::date as dia, r ->> 'adset_id' as adset_id, r ->> 'adset_name' as adset_nome, r ->> 'campaign_id' as campanha_id,
           r ->> 'campaign_name' as campanha_nome, r ->> 'publisher_platform' as plataforma, r ->> 'platform_position' as posicao,
           coalesce((r ->> 'spend')::numeric, 0) as gasto, coalesce((r ->> 'impressions')::int, 0) as impressoes,
           coalesce((r ->> 'clicks')::int, 0) as cliques, coalesce((r ->> 'inline_link_clicks')::int, 0) as cliques_link,
           coalesce((select sum((a ->> 'value')::numeric)::int from jsonb_array_elements(coalesce(r -> 'actions', '[]'::jsonb)) a
                      where a ->> 'action_type' = 'onsite_conversion.messaging_conversation_started_7d'), 0) as conversas,
           r -> 'actions' as acoes
      from jsonb_array_elements(coalesce(p_insights, '[]'::jsonb)) r
     where r ->> 'adset_id' is not null and r ->> 'date_start' is not null
       and r ->> 'publisher_platform' is not null and r ->> 'platform_position' is not null
  ), mudou as (
    select n.* from novos n
     where not exists (
       select 1 from public.meta_ads_posicionamento_diario x
        where x.dia = n.dia and x.adset_id = n.adset_id and x.plataforma = n.plataforma and x.posicao = n.posicao
          and (x.adset_nome, x.campanha_id, x.campanha_nome, x.gasto, x.impressoes, x.cliques, x.cliques_link, x.conversas)
              is not distinct from (n.adset_nome, n.campanha_id, n.campanha_nome, n.gasto, n.impressoes, n.cliques, n.cliques_link, n.conversas)
          and x.acoes is not distinct from n.acoes)
  )
  insert into public.meta_ads_posicionamento_diario as d
    (dia, adset_id, adset_nome, campanha_id, campanha_nome, plataforma, posicao,
     gasto, impressoes, cliques, cliques_link, conversas, acoes, atualizado_em)
  select m.dia, m.adset_id, m.adset_nome, m.campanha_id, m.campanha_nome, m.plataforma, m.posicao,
         m.gasto, m.impressoes, m.cliques, m.cliques_link, m.conversas, m.acoes, now()
    from mudou m
  on conflict (dia, adset_id, plataforma, posicao) do update set
    adset_nome = excluded.adset_nome, campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    gasto = excluded.gasto, impressoes = excluded.impressoes, cliques = excluded.cliques,
    cliques_link = excluded.cliques_link, conversas = excluded.conversas, acoes = excluded.acoes, atualizado_em = now();
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'posicionamentos', v_n, 'recebidos', jsonb_array_length(coalesce(p_insights, '[]'::jsonb)), 'em', now());
end $function$;

-- ───────────────────────── 1c. conjuntos (onde cada um pode aparecer) ─────────────────────────
create or replace function public.meta_ads_gravar_conjuntos(p_conjuntos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  v_n int := 0;
begin
  if jsonb_typeof(coalesce(p_conjuntos, '[]'::jsonb)) <> 'array' then
    raise exception 'p_conjuntos precisa ser array (o "data" da Graph API)' using errcode = '22023';
  end if;

  with novos as (
    select r ->> 'id' as adset_id, r ->> 'name' as adset_nome, r ->> 'campaign_id' as campanha_id, r -> 'campaign' ->> 'name' as campanha_nome,
           r ->> 'effective_status' as status_efetivo,
           coalesce(array(select jsonb_array_elements_text(r -> 'targeting' -> 'publisher_platforms')), '{}') as publisher_platforms,
           (select jsonb_object_agg(k, v) from jsonb_each(coalesce(r -> 'targeting', '{}'::jsonb)) as t(k, v)
             where k like '%\_positions' escape '\' and k not like 'effective\_%' escape '\') as posicoes
      from jsonb_array_elements(coalesce(p_conjuntos, '[]'::jsonb)) r
     where r ->> 'id' is not null
  ), mudou as (
    select n.* from novos n
     where not exists (
       select 1 from public.meta_ads_conjuntos x
        where x.adset_id = n.adset_id
          and (x.adset_nome, x.campanha_id, x.campanha_nome, x.status_efetivo, x.publisher_platforms)
              is not distinct from (n.adset_nome, n.campanha_id, n.campanha_nome, n.status_efetivo, n.publisher_platforms)
          and x.posicoes is not distinct from n.posicoes)
  )
  insert into public.meta_ads_conjuntos as c
    (adset_id, adset_nome, campanha_id, campanha_nome, status_efetivo, publisher_platforms, posicoes, atualizado_em)
  select m.adset_id, m.adset_nome, m.campanha_id, m.campanha_nome, m.status_efetivo, m.publisher_platforms, m.posicoes, now()
    from mudou m
  on conflict (adset_id) do update set
    adset_nome = excluded.adset_nome, campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    status_efetivo = excluded.status_efetivo, publisher_platforms = excluded.publisher_platforms,
    posicoes = excluded.posicoes, atualizado_em = now();
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'conjuntos', v_n, 'recebidos', jsonb_array_length(coalesce(p_conjuntos, '[]'::jsonb)), 'em', now());
end $function$;

-- ───────────────────────── 2. canal parceiro da Live, sem tabela temporária ─────────────────────────
create or replace function public.parceiro_oportunidades_abertas()
returns table(codigo text, nome text, pontos integer, parceiro_pap_id uuid, parceiro_nome text, whatsapp text, venda_id uuid, motivo text,
              valor numeric, acao text, texto_sugerido text, desde timestamp with time zone)
language plpgsql security definer set search_path = public as $function$
declare
  c    jsonb := coalesce(public.config_regra('parceiro_oportunidades', '{}'::jsonb), '{}'::jsonb);
  cfg  public.config_parceiros%rowtype;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  fim  date := (date_trunc('month', now() at time zone 'America/Sao_Paulo') + interval '1 month - 1 day')::date;
  disp int := coalesce((c ->> 'dispensa_horas')::int, 24);
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') or not coalesce((c ->> 'ligado')::boolean, true) then return; end if;
  select * into cfg from public.config_parceiros;

  return query
  with pop as (
    -- P1 · perto do próximo degrau
    select 'P1'::text as o_cod, c #>> '{P1,nome}' as o_nome, coalesce((c #>> '{P1,pontos}')::int, 0) as o_pts, p.id as o_parc, p.nome as o_pnome,
           p.whatsapp as o_zap, null::uuid as o_venda,
           'Faltam ' || to_char((s ->> 'faltam')::numeric, 'FM999G990') || ' pts' || coalesce(' (' || (s ->> 'exemplo') || ')', '')
             || ' para ' || coalesce(s ->> 'proximo_nome', 'o próximo degrau') || ' · R$ ' || to_char((s ->> 'proximo_premio')::numeric, 'FM999G990') || ' de ajuda' as o_mot,
           (s ->> 'proximo_premio')::numeric - public.parceiro_ajuda_prevista(p.id) as o_valor,
           'whatsapp'::text as o_acao,
           public._oport_texto(c #>> '{P1,texto}', jsonb_build_object('nome', split_part(p.nome, ' ', 1), 'faltam', to_char((s ->> 'faltam')::numeric, 'FM999G990'),
             'exemplo', s ->> 'exemplo', 'premio', 'R$ ' || to_char((s ->> 'proximo_premio')::numeric, 'FM999G990'))) as o_texto,
           null::timestamptz as o_desde
      from public.parceiros p cross join lateral (select public.parceiro_situacao_mes(p.id) as s) x
     where coalesce((c #>> '{P1,ativo}')::boolean, false)
       and p.status = 'ativo' and (s ->> 'faltam') is not null and (s ->> 'pontos')::numeric > 0
       and (s ->> 'faltam')::numeric <= coalesce((c #>> '{P1,faltam_max}')::numeric, 200)
    union all
    -- P2 · ativo sem venda enviada há N dias (conta da aprovação, para não acusar quem acabou de entrar)
    select 'P2', c #>> '{P2,nome}', coalesce((c #>> '{P2,pontos}')::int, 0), p.id, p.nome, p.whatsapp, null,
           case when u.ult is null then 'Nunca enviou venda · aprovado há ' || (hoje - (coalesce(p.aprovado_em, p.criado_em) at time zone 'America/Sao_Paulo')::date) || ' dias'
                else 'Sem enviar venda há ' || (hoje - (u.ult at time zone 'America/Sao_Paulo')::date) || ' dias' end,
           coalesce(u.media, (c #>> '{P2,valor_padrao}')::numeric),
           'whatsapp',
           public._oport_texto(c #>> '{P2,texto}', jsonb_build_object('nome', split_part(p.nome, ' ', 1),
             'dias', (hoje - (coalesce(u.ult, p.aprovado_em, p.criado_em) at time zone 'America/Sao_Paulo')::date)::text)),
           coalesce(u.ult, p.aprovado_em, p.criado_em)
      from public.parceiros p
      cross join lateral (select max(v.criado_em) as ult, avg(nullif(v.comissao_prevista, 0)) as media from public.vendas v where v.parceiro_id = p.id) u
     where coalesce((c #>> '{P2,ativo}')::boolean, false)
       and p.status = 'ativo'
       and coalesce(u.ult, p.aprovado_em, p.criado_em) < now() - make_interval(days => coalesce((c #>> '{P2,dias}')::int, 7))
    union all
    -- P3 · garantia ativa, abaixo do mínimo, faltando ≤ N dias para o mês virar
    select 'P3', c #>> '{P3,nome}', coalesce((c #>> '{P3,pontos}')::int, 0), p.id, p.nome, p.whatsapp, null,
           'Garantia de R$ ' || to_char(cfg.garantia_piso, 'FM999G990') || ' em risco: ' || to_char((s ->> 'pontos')::numeric, 'FM999G990') || ' de '
             || to_char(cfg.garantia_min_pontos, 'FM999G990') || ' pts · o mês vira em ' || (fim - hoje + 1) || ' dias',
           cfg.garantia_piso,
           'whatsapp',
           public._oport_texto(c #>> '{P3,texto}', jsonb_build_object('nome', split_part(p.nome, ' ', 1), 'piso', 'R$ ' || to_char(cfg.garantia_piso, 'FM999G990'),
             'minimo', to_char(cfg.garantia_min_pontos, 'FM999G990'), 'pontos', to_char((s ->> 'pontos')::numeric, 'FM999G990'),
             'faltam', to_char(cfg.garantia_min_pontos - (s ->> 'pontos')::numeric, 'FM999G990'),
             'exemplo', public.parceiro_exemplo_plano(p.id, cfg.garantia_min_pontos - (s ->> 'pontos')::numeric))),
           null
      from public.parceiros p cross join lateral (select public.parceiro_situacao_mes(p.id) as s) x
     where coalesce((c #>> '{P3,ativo}')::boolean, false) and (fim - hoje) <= coalesce((c #>> '{P3,dias_para_virar}')::int, 10)
       and p.status = 'ativo' and (s ->> 'garantia_vale')::boolean and (s ->> 'pontos')::numeric < cfg.garantia_min_pontos
    union all
    -- P4 · venda de parceiro parada na conferência além do prazo (valor = comissão Nio da venda)
    select 'P4', c #>> '{P4,nome}', coalesce((c #>> '{P4,pontos}')::int, 0), p.id, p.nome, null, v.id,
           split_part(btrim(v.cliente_nome), ' ', 1) || coalesce(' · ' || v.bairro, '') || ' · conferência atrasada '
             || public._oport_dur(now() - v.conferencia_prazo_ate),
           v.comissao_prevista, 'venda', null, v.conferencia_prazo_ate
      from public.vendas v join public.parceiros p on p.id = v.parceiro_id
     where coalesce((c #>> '{P4,ativo}')::boolean, false)
       and v.origem = 'parceiro_pap' and v.status = '0_qualificado' and v.conferencia_status = 'pendente' and v.conferencia_prazo_ate < now()
    union all
    -- P5 · cadastro aguardando aprovação há mais de N horas
    select 'P5', c #>> '{P5,nome}', coalesce((c #>> '{P5,pontos}')::int, 0), p.id, p.nome, p.whatsapp, null,
           'Cadastro esperando aprovação há ' || public._oport_dur(now() - p.criado_em) || coalesce(' · ' || p.cidade, ''),
           coalesce((c #>> '{P2,valor_padrao}')::numeric, 0), 'parceiro', null, p.criado_em
      from public.parceiros p
     where coalesce((c #>> '{P5,ativo}')::boolean, false)
       and p.status = 'aguardando' and p.criado_em < now() - make_interval(hours => coalesce((c #>> '{P5,horas}')::int, 24))
  ), aberta as (
    -- Fora o que foi enviado ou dispensado nas últimas N horas (mesmo parceiro, código e venda).
    select o.* from pop o
     where not exists (select 1 from public.parceiro_oportunidades_log l
                        where l.tipo in ('enviada', 'dispensada') and l.codigo = o.o_cod and l.parceiro_pap_id = o.o_parc
                          and l.venda_id is not distinct from o.o_venda and l.criado_em > now() - make_interval(hours => disp))
  ), mostrada as (
    insert into public.parceiro_oportunidades_log (parceiro_pap_id, venda_id, codigo, tipo, motivo, valor)
    select a.o_parc, a.o_venda, a.o_cod, 'mostrada', a.o_mot, a.o_valor from aberta a
    on conflict do nothing
  )
  select a.o_cod, a.o_nome, a.o_pts, a.o_parc, a.o_pnome, a.o_zap, a.o_venda, a.o_mot, a.o_valor, a.o_acao, a.o_texto, a.o_desde
    from aberta a
   order by 3 desc, 9 desc nulls last;
end;
$function$;
