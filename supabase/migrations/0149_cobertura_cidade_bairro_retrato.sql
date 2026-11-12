-- NIOGEN | 0149_cobertura_cidade_bairro_retrato.sql | 12/11/2026 — Claude Code (prompt "Cobertura por cidade e bairro no retrato
-- do Agente de Tráfego")
-- Resultado: parar de pagar conversa que nasce sem cobertura (21 % das conversas novas desde 05/11; meta < 10 % até 19/11).
--   1. dfv_cobertura_cidade / dfv_cobertura_bairro (parceiro_id — regra 15): fachadas viáveis do DFV por cidade da C2 e por bairro,
--      com lat/long média do bairro (para anunciar por raio). Carga: niogen/dfv/cobertura_cidades.py cidades (só leitura no painel).
--   2. conversa_cobertura_distancia: para cada conversa sem cobertura, a faixa de distância até a fachada viável mais próxima
--      (medida do ponto do CEP). Carga: cobertura_cidades.py distancias. Sem CEP, rua ou nome aqui.
--   3. agente_trafego_retrato ganha cobertura_resumo, cobertura_por_cidade[] e sem_cobertura_por_bairro[] (só contagens) + legenda.

create or replace function public._norm_geo(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(regexp_replace(
           upper(translate(coalesce(t, ''), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
                                             'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc')),
           '\(.*?\)', ' ', 'g'), '^\s*BAIRRO\s+', '', 'g'), '\s+', ' ', 'g')), '')
$$;
comment on function public._norm_geo(text) is
  'Nome de cidade/bairro comparável: maiúsculas, sem acento, sem o trecho entre parênteses (ViaCEP: "Serra Verde (Venda Nova)") e sem o prefixo BAIRRO do DFV. 0149.';

create table if not exists public.dfv_cobertura_cidade (
  parceiro_id   text not null default 'dharma',
  uf            text not null default 'MG',
  municipio     text not null,                    -- como o DFV escreve (JUIZ DE FORA)
  cidade        text not null,                    -- como a campanha escreve (Juiz de Fora)
  cidade_norm   text generated always as (public._norm_geo(cidade)) stored,
  conjunto      text,                             -- CJ_JF | CJ_REGULAR | CJ_BTU
  fachadas      int not null default 0,           -- fachadas viáveis (distintas por logradouro + número)
  hps           int not null default 0,           -- domicílios (HPs) viáveis
  bairros       int not null default 0,           -- bairros com pelo menos 1 fachada viável
  particao      date,                             -- data da base do DFV
  atualizado_em timestamptz not null default now(),
  primary key (parceiro_id, uf, municipio)
);
create table if not exists public.dfv_cobertura_bairro (
  parceiro_id   text not null default 'dharma',
  uf            text not null default 'MG',
  municipio     text not null,
  bairro        text not null,
  bairro_norm   text generated always as (public._norm_geo(bairro)) stored,
  fachadas      int not null default 0,
  hps           int not null default 0,
  lat           numeric(9, 6),                    -- média das fachadas viáveis do bairro
  lon           numeric(9, 6),
  atualizado_em timestamptz not null default now(),
  primary key (parceiro_id, uf, municipio, bairro)
);
create index if not exists dfv_cobertura_bairro_norm on public.dfv_cobertura_bairro (parceiro_id, municipio, bairro_norm);

create table if not exists public.conversa_cobertura_distancia (
  conversa_id   uuid primary key references public.mari_conversas (id) on delete cascade,
  parceiro_id   text not null default 'dharma',
  distancia_m   int,                              -- até a fachada viável mais próxima; null = não deu para medir
  faixa         text not null check (faixa in ('ate_200m', '200m_1km', 'mais_1km', 'sem_medida')),
  geo_fonte     text,                             -- de onde veio o ponto do CEP (awesomeapi | brasilapi)
  calculado_em  timestamptz not null default now()
);

alter table public.dfv_cobertura_cidade enable row level security;
alter table public.dfv_cobertura_bairro enable row level security;
alter table public.conversa_cobertura_distancia enable row level security;
drop policy if exists dfv_cobertura_cidade_ler on public.dfv_cobertura_cidade;
create policy dfv_cobertura_cidade_ler on public.dfv_cobertura_cidade for select to authenticated
  using ((select public.meu_perfil()) = any (array['admin', 'backoffice']));
drop policy if exists dfv_cobertura_bairro_ler on public.dfv_cobertura_bairro;
create policy dfv_cobertura_bairro_ler on public.dfv_cobertura_bairro for select to authenticated
  using ((select public.meu_perfil()) = any (array['admin', 'backoffice']));
drop policy if exists conversa_cobertura_distancia_ler on public.conversa_cobertura_distancia;
create policy conversa_cobertura_distancia_ler on public.conversa_cobertura_distancia for select to authenticated
  using ((select public.meu_perfil()) = any (array['admin', 'backoffice']));
grant select on public.dfv_cobertura_cidade, public.dfv_cobertura_bairro, public.conversa_cobertura_distancia to authenticated;
revoke all on public.dfv_cobertura_cidade, public.dfv_cobertura_bairro, public.conversa_cobertura_distancia from anon;

-- Os 3 blocos novos do retrato (separados para o retrato principal continuar igual ao da 0147).
create or replace function public._agente_trafego_cobertura(p_de date)
returns jsonb language sql stable security definer set search_path = public as $$
  with
  conv as (  -- conversas novas desde max(janela, 05/11), mesma regra do retrato: WhatsApp, testes fora
    select c.id, c.funil_destino, public._norm_geo(c.cidade) as cidade_norm, c.cidade,
           coalesce(nullif(btrim(c.endereco_cep ->> 'bairro'), ''), '(sem bairro)') as bairro
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.funil_destino, '') <> 'teste_duplicada'
       and (c.created_at at time zone 'America/Sao_Paulo')::date >= greatest(p_de, date '2026-11-05')
  ),
  sc as (select * from conv where funil_destino = 'sem_cobertura'),
  cid as (
    select k.*,
           (select count(*) from conv v where v.cidade_norm = k.cidade_norm) as conversas,
           (select count(*) from sc v where v.cidade_norm = k.cidade_norm) as sem_cobertura,
           coalesce((select jsonb_agg(jsonb_build_object('bairro', b.bairro, 'fachadas', b.fachadas, 'lat', b.lat, 'lon', b.lon)
                                      order by b.fachadas desc, b.bairro)
                       from (select * from public.dfv_cobertura_bairro b
                              where b.parceiro_id = k.parceiro_id and b.uf = k.uf and b.municipio = k.municipio
                              order by b.fachadas desc, b.bairro limit 10) b), '[]'::jsonb) as top_bairros
      from public.dfv_cobertura_cidade k
     where k.parceiro_id = 'dharma'
  ),
  bai as (
    select v.cidade, v.bairro, count(*) as conversas,
           (select b.fachadas from public.dfv_cobertura_bairro b
             join public.dfv_cobertura_cidade k on k.parceiro_id = b.parceiro_id and k.uf = b.uf and k.municipio = b.municipio
            where b.parceiro_id = 'dharma' and k.cidade_norm = v.cidade_norm and b.bairro_norm = public._norm_geo(v.bairro)
            order by b.fachadas desc limit 1) as fachadas_bairro,
           exists (select 1 from public.dfv_cobertura_cidade k where k.parceiro_id = 'dharma' and k.cidade_norm = v.cidade_norm)
             as cidade_medida,
           count(*) filter (where d.faixa = 'ate_200m') as ate_200m,
           count(*) filter (where d.faixa = '200m_1km') as de_200m_a_1km,
           count(*) filter (where d.faixa = 'mais_1km') as mais_1km,
           count(*) filter (where d.faixa is null or d.faixa = 'sem_medida') as sem_medida
      from sc v
      left join public.conversa_cobertura_distancia d on d.conversa_id = v.id
     group by v.cidade, v.cidade_norm, v.bairro
  )
  select jsonb_build_object(
    'cobertura_resumo', jsonb_build_object(
      'desde', greatest(p_de, date '2026-11-05'),
      'conversas', (select count(*) from conv),
      'sem_cobertura', (select count(*) from sc),
      'pct_sem_cobertura', case when (select count(*) from conv) > 0
                                then round(100.0 * (select count(*) from sc) / (select count(*) from conv), 1) end,
      'meta_pct', 10, 'meta_ate', '2026-11-19',
      'dfv_atualizado_em', (select to_char(max(atualizado_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI')
                              from public.dfv_cobertura_cidade where parceiro_id = 'dharma'),
      'dfv_base', (select max(particao) from public.dfv_cobertura_cidade where parceiro_id = 'dharma')),
    'cobertura_por_cidade', coalesce((
      select jsonb_agg(jsonb_build_object('cidade', c.cidade, 'conjunto', c.conjunto, 'fachadas_viaveis', c.fachadas,
                                          'domicilios_viaveis', c.hps, 'bairros_com_fachada', c.bairros,
                                          'conversas', c.conversas, 'sem_cobertura', c.sem_cobertura,
                                          'top_bairros', c.top_bairros)
                       order by c.conjunto, c.fachadas desc, c.cidade) from cid c), '[]'::jsonb),
    'sem_cobertura_por_bairro', coalesce((
      select jsonb_agg(jsonb_build_object('cidade', b.cidade, 'bairro', b.bairro, 'conversas', b.conversas,
                                          'dfv_tem_fachada_no_bairro', case when b.fachadas_bairro is not null then true
                                                                            when b.cidade_medida then false end,
                                          'dfv_fachadas_no_bairro', coalesce(b.fachadas_bairro, 0),
                                          'distancia_fachada_viavel', jsonb_build_object(
                                            'ate_200m', b.ate_200m, '200m_a_1km', b.de_200m_a_1km,
                                            'mais_1km', b.mais_1km, 'sem_medida', b.sem_medida))
                       order by b.conversas desc, b.cidade, b.bairro) from bai b), '[]'::jsonb)
  )
$$;
revoke execute on function public._agente_trafego_cobertura(date) from public, anon, authenticated;
grant execute on function public._agente_trafego_cobertura(date) to service_role;

-- Retrato = o da 0147 + os blocos de cobertura (0149).
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
             'qualificadas_reais', count(*) filter (where b.qualificada_real),
             'por_destino', public._agente_trafego_contar(array_agg(b.destino)),
             'por_etapa', public._agente_trafego_contar(array_agg(b.etapa)),
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
                              'ja_cliente_nio', 0, 'sem_cobertura', 0, 'qualificadas', 0, 'qualificadas_reais', 0,
                              'por_destino', '{}'::jsonb, 'por_etapa', '{}'::jsonb, 'pedidos_abertos', 0,
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
      'biometria_aprovada', 'venda com biometria validada = a venda que decide (custo_por.venda); até 12/11 procurava aprovada e dava sempre 0',
      'saidas', 'destino de saída → contagem, uma por conversa (pedido_humano e multiplos_decisores não são saída)',
      'por_anuncio', 'funil só das conversas com referral do anúncio (ad_id); antes de atribuicao_desde nenhuma conversa tinha anúncio, então anúncio com gasto e 0 conversas aqui pode ser só falta de atribuição',
      'custo_por', 'gasto da Meta na janela ÷ conversas_meta; os demais ÷ marcos das conversas com origem meta_ads (atribuídas ou não)',
      'cobertura_resumo', 'conversas novas desde max(janela, 05/11) e quantas tiveram destino sem_cobertura; meta: pct_sem_cobertura < 10 até 19/11 (era 21 % em 12/11). dfv_base = data da base do DFV usada (0149)',
      'cobertura_por_cidade', 'as 35 cidades da C2 no DFV da Nio: fachadas_viaveis (logradouro + número distintos), domicilios_viaveis (HPs), bairros_com_fachada e os 10 bairros com mais fachadas com lat/lon média (centro para anunciar por raio); conversas e sem_cobertura = conversas novas da cidade no mesmo período do cobertura_resumo. Atualiza quando roda dfv/cobertura_cidades.py cidades',
      'sem_cobertura_por_bairro', 'conversas com destino sem_cobertura por cidade + bairro (bairro do ViaCEP; sem CEP, rua ou nome). dfv_tem_fachada_no_bairro: o DFV tem fachada viável com o mesmo nome de bairro (null = cidade fora das 35 medidas). distancia_fachada_viavel: do ponto do CEP (não do número) até a fachada viável mais próxima do DFV — ate_200m (perto: conferir a regra dos 200 m e o portal), 200m_a_1km, mais_1km (raio do anúncio está pegando gente longe da rede); sem_medida = ainda não calculado (roda dfv/cobertura_cidades.py distancias)',
      'privacidade', 'só contagens; sem nome, CPF, telefone, endereço, CEP ou rua (bairro só em sem_cobertura_por_bairro e top_bairros, que é dado do DFV)'),
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
  || public._agente_trafego_cobertura(jan.de)   -- 0149
  from jan, mt, ft, fm
$$;
revoke execute on function public.agente_trafego_retrato(int) from public, anon, authenticated;
grant execute on function public.agente_trafego_retrato(int) to service_role;
