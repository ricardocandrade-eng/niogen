-- NIOGEN | supabase/migrations/0218_retrato_abertos_e_capi.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11 ~14h45, "Sim, implementar"): os dois campos novos do retrato do Agente de Tráfego propostos em
-- docs/CONFERENCIA_skill_agente_trafego_x_dados_151126_1440.md (item D), a partir de docs/ERROS_leitura_agente_trafego_151126_1425.md §9.
--
-- 1. escada.abertos — os leads em andamento por IDADE (desde que nasceram) e por TEMPO PARADO (desde a última mensagem do
--    cliente), em faixas fixas ate_24h · 1_3d · 3_7d · mais_7d, cruzados
--    com status e com a vez. "Parado" conta só a fala do CLIENTE: toque da Mari sem resposta não é movimento. Toda faixa vem SEMPRE, com 0 quando vazia: ausente nunca quer dizer zero aqui.
--    em_silencio = vez da Mari, conversa ativa, sem próximo toque da cadência e sem prazo: ninguém vai falar com o lead.
--    A regra mora em _lead_em_silencio(), a mesma que a conferência diária usa (item 16 novo).
-- 2. capi — os eventos à Meta pelo lado do NIOGEN (meta_eventos), por evento: gerados · enviados · sem_clique · erros ·
--    pendentes, desde max(janela, config_regras.meta_capi.desde); e a fila (v_meta_capi_painel). Os 4 eventos vêm sempre.
--    É o único lugar onde o QualifiedLead aparece: a Meta Ads API desta conta não tem campo para ele.
-- 3. Legenda nova: abertos, capi, meta_coletado_em e atribuicao_desde (pontos cegos achados na conferência).
-- 4. conferencia_itens(): item 16 "lead_em_silencio" (atenção quando > 0).
--
-- Regra 20: (1) sem estado novo — os números leem etapa/status/destino/vez/prazo que já existem; (2) em_silencio é o detector do
-- "ninguém parado em silêncio" e vira item da conferência; (3) nada grava estado; (4) fonte única: v_leads + mari_conversas +
-- mari_turnos (conversa) e meta_eventos (envio à Meta); (5) item 16 em conferencia_itens(). O n8n (agente_trafego_snapshot) grava
-- a saída inteira da RPC: sem mudança lá. Privacidade: só contagens.
-- Desempenho: agente_trafego_retrato(14) medido antes e depois (EXPLAIN ANALYZE) — números no Diário.
begin;

-- regra única do "lead em silêncio" (retrato e conferência)
create or replace function public._lead_em_silencio(p_de date default null)
returns table (conversa_id uuid)
language sql stable security definer set search_path = public as $$
  select l.conversa_id
    from public.v_leads l
    join public.mari_conversas c on c.id = l.conversa_id
   where l.destino = 'em_andamento'
     and l.vez = 'mari'                       -- humano/time atribuído já vira vez 'time' na v_leads
     and l.prazo_em is null
     and c.canal = 'whatsapp'
     and c.status = 'ativo'
     and c.cadencia_proximo_em is null
     and (p_de is null or (l.criado_em at time zone 'America/Sao_Paulo')::date >= p_de)
$$;

create or replace function public._faixa_horas(p_h numeric)
returns text language sql immutable as $$
  select case when p_h is null then null when p_h < 24 then 'ate_24h' when p_h < 72 then '1_3d'
              when p_h < 168 then '3_7d' else 'mais_7d' end
$$;

create or replace function public._agente_trafego_abertos(p_de date)
returns jsonb language sql stable security definer set search_path = public as $$
  with a as (
    select l.status, coalesce(l.vez, 'sem_vez') as vez,
           public._faixa_horas(extract(epoch from now() - l.criado_em) / 3600) as idade,
           public._faixa_horas(extract(epoch from now() - coalesce(t.ultima, l.criado_em)) / 3600) as parado
      from public.v_leads l
      left join lateral (select max(x.created_at) as ultima from public.mari_turnos x
                          where x.conversa_id = l.conversa_id and x.papel = 'lead') t on true
     where l.destino = 'em_andamento' and (l.criado_em at time zone 'America/Sao_Paulo')::date >= p_de
  ),
  fx(f) as (values ('ate_24h'), ('1_3d'), ('3_7d'), ('mais_7d')),
  -- faixas sempre presentes, com 0
  por_chave as (
    select 'idade' as eixo, k.chave, fx.f, count(a.*) filter (where a.idade = fx.f) as n
      from (select status as chave from a group by 1) k cross join fx left join a on a.status = k.chave group by 1, 2, 3
    union all
    select 'parado', k.chave, fx.f, count(a.*) filter (where a.parado = fx.f)
      from (select status as chave from a group by 1) k cross join fx left join a on a.status = k.chave group by 1, 2, 3
    union all
    select 'vez_parado', k.chave, fx.f, count(a.*) filter (where a.parado = fx.f)
      from (select vez as chave from a group by 1) k cross join fx left join a on a.vez = k.chave group by 1, 2, 3
  ),
  obj as (
    select eixo, chave, jsonb_object_agg(f, n) as faixas from por_chave group by 1, 2
  )
  select jsonb_build_object(
    'total', (select count(*) from a),
    'por_idade',  (select jsonb_object_agg(fx.f, (select count(*) from a where a.idade = fx.f)) from fx),
    'por_parado', (select jsonb_object_agg(fx.f, (select count(*) from a where a.parado = fx.f)) from fx),
    'por_status_idade',  coalesce((select jsonb_object_agg(chave, faixas) from obj where eixo = 'idade'), '{}'::jsonb),
    'por_status_parado', coalesce((select jsonb_object_agg(chave, faixas) from obj where eixo = 'parado'), '{}'::jsonb),
    'por_vez_parado',    coalesce((select jsonb_object_agg(chave, faixas) from obj where eixo = 'vez_parado'), '{}'::jsonb),
    'em_silencio', (select count(*) from public._lead_em_silencio(p_de)))
$$;

create or replace function public._agente_trafego_capi(p_de date)
returns jsonb language sql stable security definer set search_path = public as $$
  with cfg as (
    select (valor ->> 'desde')::timestamptz as desde, valor ->> 'dataset_id' as dataset_id,
           coalesce((valor ->> 'ligado')::boolean, false) as ligado
      from public.config_regras where chave = 'meta_capi'
  ),
  ini as (select greatest(coalesce(cfg.desde, '-infinity'::timestamptz),
                          (p_de::timestamp at time zone 'America/Sao_Paulo')) as ini from cfg),
  ev(evento) as (values ('ViewContent'), ('QualifiedLead'), ('LeadSubmitted'), ('Purchase')),
  e as (select m.* from public.meta_eventos m, ini where m.parceiro_id = 'dharma' and m.fato_em >= ini.ini)
  select jsonb_build_object(
    'ligado', cfg.ligado, 'dataset_id', cfg.dataset_id,
    'desde', to_char(cfg.desde at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"'),
    'contado_desde', to_char(ini.ini at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"'),
    'por_evento', (select jsonb_object_agg(ev.evento, jsonb_build_object(
                       'gerados',    (select count(*) from e where e.evento = ev.evento),
                       'enviados',   (select count(*) from e where e.evento = ev.evento and e.status = 'enviado'),
                       'sem_clique', (select count(*) from e where e.evento = ev.evento and e.status = 'sem_clique'),
                       'erros',      (select count(*) from e where e.evento = ev.evento and e.status = 'erro'),
                       'pendentes',  (select count(*) from e where e.evento = ev.evento and e.status = 'pendente')))
                     from ev),
    'enviados_7d', p.enviados_7d, 'erros_7d', p.erros_7d, 'sem_clique_7d', p.sem_clique_7d,
    'na_fila', p.na_fila, 'atrasados', p.atrasados,
    'ultimo_envio', to_char(p.ultimo_envio at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"'))
  from cfg, ini, public.v_meta_capi_painel p
$$;


-- a RPC do retrato (definição viva de 15/11 + abertos, capi e legenda)
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
      'abertos', 'escada.abertos (0218): os leads em andamento da janela. por_idade = desde que a conversa nasceu; por_parado = desde a última mensagem do CLIENTE (ou desde que nasceu, se ele nunca escreveu): toque da Mari sem resposta não conta como movimento. Faixas sempre presentes, 0 quando vazias: ate_24h · 1_3d · 3_7d · mais_7d. por_status_idade, por_status_parado e por_vez_parado cruzam as faixas com status e vez. em_silencio = vez da Mari, conversa ativa, sem próximo toque da cadência e sem prazo: ninguém vai falar com o lead (mesma regra do item lead_em_silencio da conferência). Ponto cego: conta conversa, não pessoa; e parado não diz de quem é a vez — cruze com por_vez_parado',
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
                               || jsonb_build_object('abertos', public._agente_trafego_abertos(jan.de)))   -- 0218
  || jsonb_build_object('capi', public._agente_trafego_capi(jan.de))   -- 0218: eventos à Meta pelo lado do NIOGEN
  from jan, mt, ft, fm
$function$;

-- a conferência diária (definição viva de 15/11 + item 16)
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

  return it;
end;
$function$;

revoke execute on function public._lead_em_silencio(date) from public, anon, authenticated;
grant execute on function public._lead_em_silencio(date) to service_role;
revoke execute on function public._faixa_horas(numeric) from public, anon, authenticated;
grant execute on function public._faixa_horas(numeric) to service_role;
revoke execute on function public._agente_trafego_abertos(date) from public, anon, authenticated;
grant execute on function public._agente_trafego_abertos(date) to service_role;
revoke execute on function public._agente_trafego_capi(date) from public, anon, authenticated;
grant execute on function public._agente_trafego_capi(date) to service_role;

commit;
