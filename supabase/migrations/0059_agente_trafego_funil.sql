-- NIOGEN | supabase/migrations/0059_agente_trafego_funil.sql | 07/11/2026 — Claude Code, prompt 30 (rota do Agente de Tráfego)
-- Por quê: o "Agente de Tráfego Nio" (tarefa agendada do claude.ai, 8h47/18h47) lê a Meta (gasto, conversas), mas não sabe
-- quantas conversas viraram CEP válido, qualificada, pedido, biometria ou instalação. A máquina dele não alcança o Supabase
-- nem o n8n — só a pasta dharmapro-nio (Google Drive). Então o n8n (workflow agente_trafego_snapshot) grava um RETRATO
-- AGREGADO em agente/funil_agente_trafego.json. Só contagens: nenhum nome, CPF, telefone, endereço, CEP ou bairro.
-- (O prompt 30 chamava esta migration de 0058; o número foi usado pelo prompt 29 — 0058_meta_ads_c2_verba.)
--   1. _agente_trafego_base(p_dias)  — 1 linha por conversa da Mari (WhatsApp, sem o canal de teste) na janela, com o anúncio que
--      a abriu (mesma regra da v_mari_conversa_anuncio: referral do mesmo telefone ±10 min) e os marcos do funil. Sem dado pessoal.
--   2. agente_trafego_funil(p_dias)  — linhas por dia × campanha × conjunto × anúncio × cidade × cluster (+ origem quando não há
--      anúncio), com as contagens do funil e os jsonb motivo/plano/pagamento → contagem.
--   3. agente_trafego_retrato(p_dias) — o JSON inteiro que o n8n grava: totais, por_dia, por_anuncio, por_conjunto, por_cidade,
--      por_origem e custo_por (conversa, CEP válido, qualificada, venda), lado a lado com o gasto da Meta (meta_ads_diario).
-- Tudo SECURITY DEFINER com search_path fixo e execute só para service_role (regra: não abrir para anon nem criar rota pública).
-- parceiro_id em tudo (regra 15) — hoje só 'dharma', o mesmo valor de meta_referrals/config_meta_ads_regras.

-- ─────────────────────────────── 0. contador jsonb ───────────────────────────────
create or replace function public._agente_trafego_contar(p text[])
returns jsonb language sql immutable set search_path = public as $$
  select coalesce(jsonb_object_agg(k, n order by n desc, k), '{}'::jsonb)
    from (select k, count(*)::int as n from unnest(p) k where k is not null and k <> '' group by k) s
$$;
revoke execute on function public._agente_trafego_contar(text[]) from public, anon, authenticated;
grant execute on function public._agente_trafego_contar(text[]) to service_role;

-- ─────────────────────────────── 1. base por conversa ───────────────────────────────
create or replace function public._agente_trafego_base(p_dias int default 14)
returns table (
  parceiro_id text, dia date, origem text,
  campanha_id text, campanha_nome text, conjunto_id text, conjunto_nome text, ad_id text, ad_nome text,
  cidade text, cluster text,
  respondeu boolean, cep_informado boolean, cep_valido_area boolean, fora_area boolean, ja_cliente_nio boolean,
  sem_cobertura boolean, qualificada boolean, pedido_aberto boolean, biometria_aprovada boolean, instalada boolean,
  saida text, plano text, forma_pagamento text
)
language sql stable security definer set search_path = public as $$
  with janela as (
    select ((now() at time zone 'America/Sao_Paulo')::date - (greatest(1, least(coalesce(p_dias, 14), 90)) - 1)) as de
  )
  select 'dharma'::text,
         (c.created_at at time zone 'America/Sao_Paulo')::date,
         case when r.ad_id is not null then 'meta_ads' else coalesce(nullif(c.origem, ''), 'direto') end,
         a.campanha_id, a.campanha_nome, a.adset_id, a.adset_nome, r.ad_id, a.ad_nome,
         coalesce(nullif(trim(c.cidade), ''), 'sem cidade'),
         coalesce(nullif(c.cluster, ''), 'sem cluster'),
         coalesce(t.lead_msgs, 0) >= 2,
         c.cep is not null,
         c.cep is not null and c.dentro_area is true,
         c.dentro_area is false or c.elegibilidade = 'fora_area',
         c.handoff_motivo = 'ja_cliente_nio' or c.elegibilidade = 'ja_cliente',
         v.motivo_saida = 'Sem cobertura' or c.nio_viab_resultado in ('sem_viabilidade', 'indisponivel')
           or v.nio_viab_resultado in ('sem_viabilidade', 'indisponivel'),
         c.handoff_motivo = 'dados_completos',
         v.nio_pedido is not null
           or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'),
         v.biometria_status = 'aprovada',
         v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme'),
         case when v.status = 'saida' then coalesce(nullif(v.motivo_saida, ''), 'saída sem motivo')
              when c.handoff_motivo is not null and c.handoff_motivo <> 'dados_completos' then c.handoff_motivo
              when c.elegibilidade is not null and c.elegibilidade <> 'ok' then c.elegibilidade end,
         nullif(c.plano_escolhido, ''),
         nullif(c.forma_pagamento, '')
    from public.mari_conversas c
    cross join janela j
    left join lateral (
      select count(*)::int as lead_msgs from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead'
    ) t on true
    left join lateral (
      select r.ad_id from public.meta_referrals r
       where r.telefone = c.telefone and r.ad_id is not null
         and r.recebido_em between c.created_at - interval '10 minutes' and c.created_at + interval '10 minutes'
       order by r.recebido_em
       limit 1
    ) r on true
    left join public.meta_ads_anuncios a on a.ad_id = r.ad_id
    left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp'
     and (c.created_at at time zone 'America/Sao_Paulo')::date >= j.de
$$;
revoke execute on function public._agente_trafego_base(int) from public, anon, authenticated;
grant execute on function public._agente_trafego_base(int) to service_role;
comment on function public._agente_trafego_base(int) is
  'Uma linha por conversa da Mari (WhatsApp) nos últimos p_dias, com o anúncio que a abriu e os marcos do funil. Sem dado pessoal. Só service_role. 0059.';

-- ─────────────────────────────── 2. funil por dia × anúncio × cidade × cluster ───────────────────────────────
create or replace function public.agente_trafego_funil(p_dias int default 14)
returns table (
  parceiro_id text, dia date, origem text,
  campanha_id text, campanha_nome text, conjunto_id text, conjunto_nome text, ad_id text, ad_nome text,
  cidade text, cluster text,
  conversas int, responderam int, cep_informado int, cep_valido_area int, fora_area int, ja_cliente_nio int, sem_cobertura int,
  qualificadas int, pedidos_abertos int, biometria_aprovada int, instaladas int,
  saidas jsonb, plano_escolhido jsonb, forma_pagamento jsonb
)
language sql stable security definer set search_path = public as $$
  select b.parceiro_id, b.dia, b.origem, b.campanha_id, b.campanha_nome, b.conjunto_id, b.conjunto_nome, b.ad_id, b.ad_nome,
         b.cidade, b.cluster,
         count(*)::int,
         count(*) filter (where b.respondeu)::int,
         count(*) filter (where b.cep_informado)::int,
         count(*) filter (where b.cep_valido_area)::int,
         count(*) filter (where b.fora_area)::int,
         count(*) filter (where b.ja_cliente_nio)::int,
         count(*) filter (where b.sem_cobertura)::int,
         count(*) filter (where b.qualificada)::int,
         count(*) filter (where b.pedido_aberto)::int,
         count(*) filter (where b.biometria_aprovada)::int,
         count(*) filter (where b.instalada)::int,
         public._agente_trafego_contar(array_agg(b.saida)),
         public._agente_trafego_contar(array_agg(b.plano)),
         public._agente_trafego_contar(array_agg(b.forma_pagamento))
    from public._agente_trafego_base(p_dias) b
   group by b.parceiro_id, b.dia, b.origem, b.campanha_id, b.campanha_nome, b.conjunto_id, b.conjunto_nome, b.ad_id, b.ad_nome,
            b.cidade, b.cluster
   order by b.dia, b.campanha_id nulls last, b.conjunto_id nulls last, b.ad_id nulls last, b.cidade, b.cluster
$$;
revoke execute on function public.agente_trafego_funil(int) from public, anon, authenticated;
grant execute on function public.agente_trafego_funil(int) to service_role;
comment on function public.agente_trafego_funil(int) is
  'Funil da Mari por dia × campanha × conjunto × anúncio × cidade × cluster (ad_id nulo = sem referral; ver origem). Só contagens. Só service_role (n8n agente_trafego_snapshot). 0059.';

-- ─────────────────────────────── 3. retrato completo (o JSON do arquivo) ───────────────────────────────
create or replace function public.agente_trafego_retrato(p_dias int default 14)
returns jsonb language sql stable security definer set search_path = public as $$
  with
  par as (
    select greatest(1, least(coalesce(p_dias, 14), 90)) as dias,
           (now() at time zone 'America/Sao_Paulo')::date as ate
  ),
  jan as (select dias, ate, ate - (dias - 1) as de from par),
  base as (select * from public._agente_trafego_base((select dias from jan))),
  -- funil em vários recortes de uma vez; g_* diz qual recorte é a linha
  f as (
    select grouping(b.dia) = 0 as g_dia, grouping(b.ad_id) = 0 as g_ad, grouping(b.conjunto_id) = 0 as g_conj,
           grouping(b.cidade) = 0 as g_cid, grouping(b.origem) = 0 as g_ori,
           b.dia, b.ad_id, b.conjunto_id, b.cidade, b.origem,
           jsonb_build_object(
             'conversas', count(*), 'responderam', count(*) filter (where b.respondeu),
             'cep_informado', count(*) filter (where b.cep_informado), 'cep_valido_area', count(*) filter (where b.cep_valido_area),
             'fora_area', count(*) filter (where b.fora_area), 'ja_cliente_nio', count(*) filter (where b.ja_cliente_nio),
             'sem_cobertura', count(*) filter (where b.sem_cobertura), 'qualificadas', count(*) filter (where b.qualificada),
             'pedidos_abertos', count(*) filter (where b.pedido_aberto), 'biometria_aprovada', count(*) filter (where b.biometria_aprovada),
             'instaladas', count(*) filter (where b.instalada),
             'saidas', public._agente_trafego_contar(array_agg(b.saida)),
             'plano_escolhido', public._agente_trafego_contar(array_agg(b.plano)),
             'forma_pagamento', public._agente_trafego_contar(array_agg(b.forma_pagamento))) as funil
      from base b
     group by grouping sets ((), (b.dia), (b.ad_id), (b.conjunto_id), (b.cidade), (b.origem))
  ),
  -- gasto da Meta nos mesmos recortes (dia, anúncio, conjunto, total)
  m as (
    select grouping(d.dia) = 0 as g_dia, grouping(d.ad_id) = 0 as g_ad, grouping(d.adset_id) = 0 as g_conj,
           d.dia, d.ad_id, d.adset_id,
           round(sum(d.gasto), 2) as gasto, sum(d.impressoes)::int as impressoes, sum(d.cliques)::int as cliques,
           sum(d.conversas)::int as conversas_meta
      from public.meta_ads_diario d, jan
     where d.dia between jan.de and jan.ate
     group by grouping sets ((), (d.dia), (d.ad_id), (d.adset_id))
  ),
  zero as (
    select jsonb_build_object('conversas', 0, 'responderam', 0, 'cep_informado', 0, 'cep_valido_area', 0, 'fora_area', 0,
                              'ja_cliente_nio', 0, 'sem_cobertura', 0, 'qualificadas', 0, 'pedidos_abertos', 0,
                              'biometria_aprovada', 0, 'instaladas', 0, 'saidas', '{}'::jsonb,
                              'plano_escolhido', '{}'::jsonb, 'forma_pagamento', '{}'::jsonb) as z
  ),
  mt as (  -- total da Meta (sempre 1 linha)
    select coalesce((select gasto from m where not (g_dia or g_ad or g_conj)), 0) as gasto,
           coalesce((select impressoes from m where not (g_dia or g_ad or g_conj)), 0) as impressoes,
           coalesce((select cliques from m where not (g_dia or g_ad or g_conj)), 0) as cliques,
           coalesce((select conversas_meta from m where not (g_dia or g_ad or g_conj)), 0) as conversas_meta
  ),
  ft as (select coalesce((select funil from f where not (g_dia or g_ad or g_conj or g_cid or g_ori)), (select z from zero)) as funil),
  fm as (select coalesce((select funil from f where g_ori and origem = 'meta_ads'), (select z from zero)) as funil)
  select jsonb_build_object(
    'gerado_em', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"'),
    'parceiro_id', 'dharma',
    'janela_dias', jan.dias, 'de', jan.de, 'ate', jan.ate,
    'meta_coletado_em', (select to_char(max(d.atualizado_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"')
                           from public.meta_ads_diario d where d.dia between jan.de and jan.ate),
    'atribuicao_desde', (select to_char(min(r.recebido_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD')
                           from public.meta_referrals r where r.ad_id is not null),
    'legenda', jsonb_build_object(
      'conversas_meta', 'conversas iniciadas no WhatsApp contadas pela Meta (meta_ads_diario, janela de 7 d da Meta)',
      'conversas', 'conversas que chegaram na Mari pelo WhatsApp (canal de teste fora), pelo dia em que nasceram',
      'responderam', 'cliente mandou 2 ou mais mensagens',
      'cep_valido_area', 'CEP informado e dentro da área de atuação',
      'fora_area', 'fora da área de atuação (CEP ou elegibilidade)',
      'sem_cobertura', 'venda saiu por "Sem cobertura" ou viabilidade do portal sem_viabilidade/indisponível',
      'qualificadas', 'Mari passou para o time com dados completos (handoff dados_completos)',
      'pedidos_abertos', 'venda com pedido no portal Nio ou status vendido em diante',
      'biometria_aprovada', 'venda com biometria aprovada = a venda que decide (custo_por.venda)',
      'saidas', 'motivo → contagem: saída da venda, handoff que não é dados_completos, ou elegibilidade diferente de ok',
      'por_anuncio', 'funil só das conversas com referral do anúncio (ad_id); antes de atribuicao_desde nenhuma conversa tinha anúncio, então anúncio com gasto e 0 conversas aqui pode ser só falta de atribuição',
      'custo_por', 'gasto da Meta na janela ÷ conversas_meta; os demais ÷ marcos das conversas com origem meta_ads (atribuídas ou não)',
      'privacidade', 'só contagens; sem nome, CPF, telefone, endereço, CEP ou bairro'),
    'totais', jsonb_build_object('gasto', mt.gasto, 'impressoes', mt.impressoes, 'cliques', mt.cliques,
                                 'conversas_meta', mt.conversas_meta,
                                 'conversas_atribuidas', (select count(*) from base where ad_id is not null)) || ft.funil,
    'custo_por', jsonb_build_object(
      'conversa', case when mt.conversas_meta > 0 then round(mt.gasto / mt.conversas_meta, 2) end,
      'cep_valido', case when (fm.funil ->> 'cep_valido_area')::int > 0 then round(mt.gasto / (fm.funil ->> 'cep_valido_area')::int, 2) end,
      'qualificada', case when (fm.funil ->> 'qualificadas')::int > 0 then round(mt.gasto / (fm.funil ->> 'qualificadas')::int, 2) end,
      'venda', case when (fm.funil ->> 'biometria_aprovada')::int > 0 then round(mt.gasto / (fm.funil ->> 'biometria_aprovada')::int, 2) end),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object('dia', k.dia, 'gasto', coalesce(md.gasto, 0), 'conversas_meta', coalesce(md.conversas_meta, 0))
                       || coalesce(fd.funil, (select z from zero)) order by k.dia)
        from (select dia from m where g_dia union select dia from f where g_dia) k
        left join m md on md.g_dia and md.dia = k.dia
        left join f fd on fd.g_dia and fd.dia = k.dia), '[]'::jsonb),
    'por_anuncio', coalesce((
      select jsonb_agg(jsonb_build_object('ad_id', k.ad_id, 'ad_nome', a.ad_nome, 'conjunto_id', a.adset_id, 'conjunto', a.adset_nome,
                                          'campanha', a.campanha_nome, 'status', a.status_efetivo,
                                          'gasto', coalesce(ma.gasto, 0), 'impressoes', coalesce(ma.impressoes, 0),
                                          'conversas_meta', coalesce(ma.conversas_meta, 0),
                                          'custo_cep_valido', case when (fa.funil ->> 'cep_valido_area')::int > 0
                                                                   then round(ma.gasto / (fa.funil ->> 'cep_valido_area')::int, 2) end,
                                          'custo_venda', case when (fa.funil ->> 'biometria_aprovada')::int > 0
                                                              then round(ma.gasto / (fa.funil ->> 'biometria_aprovada')::int, 2) end)
                       || coalesce(fa.funil, (select z from zero))
                       order by coalesce(ma.gasto, 0) desc, k.ad_id)
        from (select ad_id from m where g_ad and ad_id is not null union select ad_id from f where g_ad and ad_id is not null) k
        left join public.meta_ads_anuncios a on a.ad_id = k.ad_id
        left join m ma on ma.g_ad and ma.ad_id = k.ad_id
        left join f fa on fa.g_ad and fa.ad_id = k.ad_id), '[]'::jsonb),
    'por_conjunto', coalesce((
      select jsonb_agg(jsonb_build_object('conjunto_id', k.adset_id, 'conjunto', c.adset_nome, 'campanha', c.campanha_nome,
                                          'gasto', coalesce(mc.gasto, 0), 'conversas_meta', coalesce(mc.conversas_meta, 0),
                                          'custo_cep_valido', case when (fc.funil ->> 'cep_valido_area')::int > 0
                                                                   then round(mc.gasto / (fc.funil ->> 'cep_valido_area')::int, 2) end,
                                          'custo_venda', case when (fc.funil ->> 'biometria_aprovada')::int > 0
                                                              then round(mc.gasto / (fc.funil ->> 'biometria_aprovada')::int, 2) end)
                       || coalesce(fc.funil, (select z from zero))
                       order by coalesce(mc.gasto, 0) desc, k.adset_id)
        from (select adset_id from m where g_conj and adset_id is not null
              union select conjunto_id from f where g_conj and conjunto_id is not null) k
        left join lateral (select a.adset_nome, a.campanha_nome from public.meta_ads_anuncios a
                            where a.adset_id = k.adset_id order by a.atualizado_em desc limit 1) c on true
        left join m mc on mc.g_conj and mc.adset_id = k.adset_id
        left join f fc on fc.g_conj and fc.conjunto_id = k.adset_id), '[]'::jsonb),
    'por_cidade', coalesce((
      select jsonb_agg(jsonb_build_object('cidade', x.cidade) || x.funil order by (x.funil ->> 'conversas')::int desc, x.cidade)
        from f x where x.g_cid), '[]'::jsonb),
    'por_origem', coalesce((
      select jsonb_agg(jsonb_build_object('origem', x.origem) || x.funil order by (x.funil ->> 'conversas')::int desc, x.origem)
        from f x where x.g_ori), '[]'::jsonb)
  )
  from jan, mt, ft, fm
$$;
revoke execute on function public.agente_trafego_retrato(int) from public, anon, authenticated;
grant execute on function public.agente_trafego_retrato(int) to service_role;
comment on function public.agente_trafego_retrato(int) is
  'Retrato agregado do funil (Meta × Mari × vendas) para o Agente de Tráfego: o JSON que o n8n agente_trafego_snapshot grava em agente/funil_agente_trafego.json no Drive. Só contagens. Só service_role. 0059.';
