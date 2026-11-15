-- NIOGEN | supabase/migrations/0221_retrato_caixas.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11): "precisamos conferir a skill do agente de tráfego para ver se está de acordo com as novas definições".
-- As 7 caixas (0219) entram no retrato do Agente de Tráfego: escada.caixas {janela, agora}, sempre as 7, com 0 quando vazias —
-- os mesmos números da Live (v_lead_caixa). Legenda nova "caixas" e "abertos.em_silencio" = caixa 5.
-- Única mudança no agente_trafego_retrato (0218): a chave escada.caixas e a legenda. O n8n (agente_trafego_snapshot) grava a
-- saída inteira: sem mudança lá. Privacidade: só contagens. Regra 20: leitura; sem estado novo.
begin;

create or replace function public._agente_trafego_caixas(p_de date)
returns jsonb language sql stable security definer set search_path = public as $$
  with cx(n) as (values (1), (2), (3), (4), (5), (6), (7)),
       l as materialized (select caixa, criado_em from public.v_lead_caixa)
  select jsonb_build_object(
    'janela', (select jsonb_object_agg(public._caixa_nome(cx.n), (select count(*) from l where l.caixa = cx.n
                                        and (l.criado_em at time zone 'America/Sao_Paulo')::date >= p_de)) from cx),
    'agora',  (select jsonb_object_agg(public._caixa_nome(cx.n), (select count(*) from l where l.caixa = cx.n)) from cx))
$$;
revoke all on function public._agente_trafego_caixas(date) from public, anon, authenticated;
grant execute on function public._agente_trafego_caixas(date) to service_role;

CREATE OR REPLACE FUNCTION public.agente_trafego_retrato(p_dias integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
             'qualificadas_reais', count(*) filter (where b.qualificada_real),
             'por_destino', public._agente_trafego_contar(array_agg(b.destino)),
             'por_etapa', public._agente_trafego_contar(array_agg(b.etapa)),
             'pedidos_abertos', count(*) filter (where b.pedido_aberto), 'biometria_aprovada', count(*) filter (where b.biometria_aprovada),
             'instaladas', count(*) filter (where b.instalada), 'vendas_os', count(*) filter (where b.venda_os),
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
                              'ja_cliente_nio', 0, 'sem_cobertura', 0, 'qualificadas', 0, 'qualificadas_reais', 0,
                              'por_destino', '{}'::jsonb, 'por_etapa', '{}'::jsonb, 'pedidos_abertos', 0,
                              'biometria_aprovada', 0, 'instaladas', 0, 'vendas_os', 0, 'saidas', '{}'::jsonb,
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
      'conversas', 'conversas que chegaram na Mari pelo WhatsApp, pelo dia em que nasceram (canal e telefones de teste fora desde 12/11, 0147)',
      'responderam', 'cliente mandou 2 ou mais mensagens',
      'cep_valido_area', 'CEP informado e dentro da área de atuação',
      'fora_area', 'fora da área de atuação (CEP ou elegibilidade)',
      'sem_cobertura', 'destino sem_cobertura (portal ou operador sem viabilidade, Saída Sem cobertura); fora_area e ja_cliente_nio também são o destino único desde 0147',
      'qualificadas', 'LEGADO: Mari passou para o time com dados completos (handoff dados_completos), sem olhar viabilidade nem cliente Nio',
      'qualificadas_reais', 'USE ESTA: etapa qualificada ou além (dados completos + viável + não é cliente Nio + crédito não negado), sem já cliente ou crédito negado depois (0147)',
      'por_destino', 'destino único de cada conversa, soma = conversas: em_andamento, instalada, reprovado_biometria, credito_negado, ja_cliente_nio, fora_area, sem_cobertura, recusou, sem_resposta',
      'por_etapa', 'etapa mais alta alcançada: nova, respondeu, cep, area_ok, viavel, viu_planos, qualificada, pedido, biometria, agendada, instalada. sem cidade em por_cidade = quem ainda não deu o CEP',
      'pedidos_abertos', 'venda com pedido no portal Nio ou status vendido em diante',
      'biometria_aprovada', 'venda com biometria validada. LEGADO desde 13/11 como "a venda que decide": custo_por.venda e custo_venda seguem calculados por ela, para comparar com o histórico',
      'vendas_os', 'USE ESTA PARA VENDA (decisão D3 do Ricardo, 12/11): venda = OS gravada na Nio (nº da OS, ou status vendido em diante). Custos: custo_por.venda_os e custo_venda_os (por conjunto e por anúncio)',
      'instaladas', 'venda instalada (o resultado). Desde 13/11 chega no mesmo dia: o Operador de OS lê a Nio a cada 30 min e a venda vira Instalada sozinha. Custos: custo_por.instalada e custo_instalada',
      'escada', 'a escada única do NIOGEN, janela inteira: leads, vendas_os, instaladas, instaladas_liquidas (sem as canceladas depois de instalar), por_destino, chegaram_ate (atendimento, viabilidade, pre_qualificado, qualificado, instalacao = degrau "OS aberta", instalada), saidas_por_motivo (lista única: cidade_nao_atendida, fachada_nao_atendida, ja_cliente_nio, recusou, credito_negado, reprovado_biometria, nio_nao_instalou, sem_resposta, nao_contatar…), saidas_por_etapa, em_andamento_por_status e em_andamento_por_vez (mari, time, cliente, nio)',
      'saidas', 'destino de saída → contagem, uma por conversa (pedido_humano e multiplos_decisores não são saída)',
      'por_anuncio', 'funil só das conversas com referral do anúncio (ad_id); antes de atribuicao_desde nenhuma conversa tinha anúncio, então anúncio com gasto e 0 conversas aqui pode ser só falta de atribuição',
      'custo_por', 'gasto da Meta na janela ÷ conversas_meta; os demais ÷ marcos das conversas com origem meta_ads (atribuídas ou não)',
      'cobertura_resumo', 'conversas novas desde max(janela, 05/11) e quantas tiveram destino sem_cobertura; meta: pct_sem_cobertura < 10 até 19/11 (era 21 % em 12/11). dfv_base = data da base do DFV usada (0149)',
      'cobertura_por_cidade', 'as 35 cidades da C2 no DFV da Nio: fachadas_viaveis (logradouro + número distintos), domicilios_viaveis (HPs), bairros_com_fachada e os 10 bairros com mais fachadas com lat/lon média (centro para anunciar por raio); conversas e sem_cobertura = conversas novas da cidade no mesmo período do cobertura_resumo. Atualiza quando roda dfv/cobertura_cidades.py cidades',
      'sem_cobertura_por_bairro', 'conversas com destino sem_cobertura por cidade + bairro (bairro do ViaCEP; sem CEP, rua ou nome). dfv_tem_fachada_no_bairro: o DFV tem fachada viável com o mesmo nome de bairro (null = cidade fora das 35 medidas). distancia_fachada_viavel: do ponto do CEP (não do número) até a fachada viável mais próxima do DFV — ate_200m (perto: conferir a regra dos 200 m e o portal), 200m_a_1km, mais_1km (raio do anúncio está pegando gente longe da rede); sem_medida = ainda não calculado (roda dfv/cobertura_cidades.py distancias)',
      'privacidade', 'só contagens; sem nome, CPF, telefone, endereço, CEP ou rua (bairro só em sem_cobertura_por_bairro e top_bairros, que é dado do DFV)',
      'caixas', 'escada.caixas (0219): a CAIXA de cada lead — a mesma que a Live mostra, calculada só no banco (v_lead_caixa). 1 Mari conduzindo · 2 Time precisa agir · 3 Com o time, esperando o cliente · 4 Venda andando (Nio/cliente) · 5 Sem caixa (ninguém vai falar com o lead: falha de operação, não de tráfego) · 6 Saída · 7 Instalada. janela = leads que nasceram na janela; agora = todos os leads hoje. As 7 caixas vêm sempre, 0 quando vazias; a soma de janela é igual a escada.leads. Use as caixas para dizer onde os leads estão; para o motivo de saída use saidas_por_motivo/por_destino',
      'abertos', 'escada.abertos (0218): os leads em andamento da janela. por_idade = desde que a conversa nasceu; por_parado = desde a última mensagem do CLIENTE (ou desde que nasceu, se ele nunca escreveu): toque da Mari sem resposta não conta como movimento. Faixas sempre presentes, 0 quando vazias: ate_24h · 1_3d · 3_7d · mais_7d. por_status_idade, por_status_parado e por_vez_parado cruzam as faixas com status e vez. em_silencio = caixa 5 "Sem caixa" (desde 0219): ninguém vai falar com o lead (mesma regra da Live e do item lead_em_silencio da conferência). Ponto cego: conta conversa, não pessoa; e parado não diz de quem é a vez — cruze com por_vez_parado',
      'capi', 'capi (0218): eventos à Meta pelo lado do NIOGEN (meta_eventos), desde contado_desde = max(início da janela, config meta_capi.desde — sem backfill). por_evento traz os 4 sempre: gerados = enviados + sem_clique + erros + pendentes. enviado = a Meta respondeu 200, NÃO quer dizer atribuído a anúncio. sem_clique = conversa sem ctwa_clid, nunca vai à Meta. QualifiedLead (o viável) só é contado aqui: a Meta Ads API desta conta não tem campo para ele. Fila: na_fila, atrasados (> 1 h), ultimo_envio',
      'meta_coletado_em', 'hora da última coleta da Meta (meta_ads_diario). gerado_em é a hora em que o retrato foi montado: retrato fresco com meta_coletado_em velho = gasto e conversas_meta parados',
      'atribuicao_desde', 'primeiro dia com referral de anúncio. Por anúncio e por conjunto, o gasto é da janela inteira, mas conversas só existem desde esta data e só para as que casaram referral (totais.conversas_atribuidas)'),
    'totais', jsonb_build_object('gasto', mt.gasto, 'impressoes', mt.impressoes, 'cliques', mt.cliques,
                                 'conversas_meta', mt.conversas_meta,
                                 'conversas_atribuidas', (select count(*) from base where ad_id is not null),
                                 'conversas_teste_excluidas', (select count(*) from public.mari_conversas x
                                                                where x.canal = 'whatsapp' and x.funil_destino = 'teste_duplicada'
                                                                  and (x.created_at at time zone 'America/Sao_Paulo')::date >= jan.de)) || ft.funil,
    'custo_por', jsonb_build_object(
      'conversa', case when mt.conversas_meta > 0 then round(mt.gasto / mt.conversas_meta, 2) end,
      'cep_valido', case when (fm.funil ->> 'cep_valido_area')::int > 0 then round(mt.gasto / (fm.funil ->> 'cep_valido_area')::int, 2) end,
      'qualificada', case when (fm.funil ->> 'qualificadas')::int > 0 then round(mt.gasto / (fm.funil ->> 'qualificadas')::int, 2) end,
      'qualificada_real', case when (fm.funil ->> 'qualificadas_reais')::int > 0 then round(mt.gasto / (fm.funil ->> 'qualificadas_reais')::int, 2) end,
      'venda', case when (fm.funil ->> 'biometria_aprovada')::int > 0 then round(mt.gasto / (fm.funil ->> 'biometria_aprovada')::int, 2) end,
      'venda_os', case when (fm.funil ->> 'vendas_os')::int > 0 then round(mt.gasto / (fm.funil ->> 'vendas_os')::int, 2) end,
      'instalada', case when (fm.funil ->> 'instaladas')::int > 0 then round(mt.gasto / (fm.funil ->> 'instaladas')::int, 2) end),
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
                                                              then round(ma.gasto / (fa.funil ->> 'biometria_aprovada')::int, 2) end,
                                          'custo_venda_os', case when (fa.funil ->> 'vendas_os')::int > 0 then round(ma.gasto / (fa.funil ->> 'vendas_os')::int, 2) end,
                                          'custo_instalada', case when (fa.funil ->> 'instaladas')::int > 0 then round(ma.gasto / (fa.funil ->> 'instaladas')::int, 2) end)
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
                                                              then round(mc.gasto / (fc.funil ->> 'biometria_aprovada')::int, 2) end,
                                          'custo_venda_os', case when (fc.funil ->> 'vendas_os')::int > 0 then round(mc.gasto / (fc.funil ->> 'vendas_os')::int, 2) end,
                                          'custo_instalada', case when (fc.funil ->> 'instaladas')::int > 0 then round(mc.gasto / (fc.funil ->> 'instaladas')::int, 2) end)
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
  || public._agente_trafego_cobertura(jan.de)   -- 0149
  || jsonb_build_object('escada', public._leads_resumo(jan.de)   -- 0157: a escada única (as chaves antigas seguem valendo)
                               || jsonb_build_object('abertos', public._agente_trafego_abertos(jan.de))   -- 0218
                               || jsonb_build_object('caixas', public._agente_trafego_caixas(jan.de)))   -- 0219
  || jsonb_build_object('capi', public._agente_trafego_capi(jan.de))   -- 0218: eventos à Meta pelo lado do NIOGEN
  from jan, mt, ft, fm
$function$;

commit;
