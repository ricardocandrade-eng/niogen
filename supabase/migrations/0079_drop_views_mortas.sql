-- NIOGEN | supabase/migrations/0079_drop_views_mortas.sql | 09/11/2026 — Claude Code (pendência 39; rascunho da rodada noturna aprovado)
-- ✅ OK do Ricardo em 09/11 de manhã: "Pode apagar". Antes era o rascunho supabase/rascunhos/DROP_views_mortas_091126_RASCUNHO.sql.
--
-- Levantamento de quem lê cada view (09/11 ~01h25):
--   • front (niogen/docs/*.html, assets/*.js) ........ grep pelo nome
--   • n8n VIVO (39 workflows da instância, GET /workflows — corpo dos nós) e exports em niogen/n8n, mari, meta, portal, extensao, scripts, tests
--   • banco: pg_depend (views que dependem), pg_proc.prosrc (funções que citam) e pg_policies
--   • Drive (docs do projeto): só prompts antigos em docs/_arquivo/ e o PROMPT_CODE_16 (texto, não código)
--
--   view                  front  n8n vivo  views/funções/policies  veredito
--   v_painel_mes          0      0         0                       ✅ ninguém lê → DROP abaixo
--   v_painel_hoje         0      0         0                       ✅ ninguém lê → DROP abaixo
--   v_alertas_contrato    0      0         0                       ✅ ninguém lê → DROP abaixo
--   v_instalacoes         2      0         0                       ❌ FICA — o badge do menu (sidebar.js) e instalacoes.html ainda leem
--   v_mari_abertura       0      0         função mari_cadencia_registrar   ❌ FICA (e é a medição da abertura B2)
--   v_mari_conversas      0      0         0                       ⏸ sem leitor, mas fora da pendência 39 — Ricardo decide (prompt 12, tela Mari antiga)
--   v_mari_metricas       0      0         0                       ⏸ idem
--   v_pendencias_abertas  0      0         0                       ⏸ nasceu 08/11 (0064) e está nas notas técnicas do backoffice — manter
--   v_placar_dfv          0      0         0                       ⏸ base da tela Placar ("em breve") — manter
--

drop view if exists public.v_painel_mes;
drop view if exists public.v_painel_hoje;
drop view if exists public.v_alertas_contrato;

-- ============================================================================================================================
-- VOLTAR ATRÁS (se algo quebrar depois do DROP): as definições abaixo foram copiadas do banco em 09/11 01h25 (pg_get_viewdef).
-- Rodar o bloco e depois:  grant select on public.v_painel_mes, public.v_painel_hoje, public.v_alertas_contrato to authenticated;
-- ============================================================================================================================
/*
create or replace view public.v_painel_mes with (security_invoker = true) as
 WITH base AS (
         SELECT f.id,
            f.criado_em,
            f.criado_por,
            f.status,
            f.motivo_saida,
            f.interesse_futuro_em,
            f.origem,
            f.origem_ref,
            f.cliente_nome,
            f.cliente_cpf_cnpj,
            f.cliente_whatsapp,
            f.cliente_email,
            f.segmento,
            f.cep,
            f.logradouro,
            f.numero,
            f.complemento,
            f.bairro,
            f.cidade,
            f.uf,
            f.plano_id,
            f.forma_pagamento,
            f.vencimento_dia,
            f.comissao_prevista,
            f.comissao_paga,
            f.ciclo_pago,
            f.estorno_previsto,
            f.nio_pedido,
            f.nio_contrato,
            f.nio_situacao,
            f.nio_pendencia_cod,
            f.nio_pendencia_desc,
            f.biometria_status,
            f.biometria_em,
            f.vendido_em,
            f.agendamento_registrado_em,
            f.instalacao_agendada_para,
            f.instalado_em,
            f.ativado_em,
            f.docs_entregues_em,
            f.vendedor_id,
            f.trava_cobertura,
            f.trava_area,
            f.trava_sem_produto_ativo,
            f.trava_sem_cancelamento_30d,
            f.trava_cpf_valido,
            f.trava_contato_confirmado,
            f.nio_osab_em,
            f.nio_venda_valida,
            f.valor_mensal,
            f.comissao_nominal,
            f.comissao_adicionais,
            f.bonus_transicao_previsto,
            f.bonus_nmei_previsto,
            f.bonus_m10_potencial,
            f.primeiro_vencimento,
            f.dfv_viabilidade,
            f.dfv_consultado_em,
            f.dfv_consultado_por,
            f.dfv_faixa_credito,
            f.dfv_classificacao,
            f.dfv_hp_livre,
            f.dfv_hcs,
            f.dfv_dispensado,
            f.dfv_dispensa_motivo,
            f.dfv_origem,
            f.dfv_resultado,
            f.dfv_particao,
            f.plano_nome,
            f.plano_familia,
            f.plano_velocidade,
            f.plano_preco,
            f.plano_codigo,
            f.plano_portfolio,
            f.plano_variante,
            f.plano_cluster,
            f.plano_preco_cartao,
            f.plano_taxa_a_vista,
            f.plano_isencao_meses,
            f.vendedor_nome,
            f.horas_sem_agendamento,
            f.dias_esperando_biometria,
            f.docs_prazo_em,
            f.firme_em,
            f.dfv_ok,
            f.dfv_dias,
            date_trunc('month'::text, (f.vendido_em AT TIME ZONE 'America/Sao_Paulo'::text))::date AS mes_venda,
            (f.vendido_em AT TIME ZONE 'America/Sao_Paulo'::text)::date AS dia_venda,
            date_trunc('month'::text, (f.instalado_em AT TIME ZONE 'America/Sao_Paulo'::text))::date AS mes_inst,
            (f.instalado_em AT TIME ZONE 'America/Sao_Paulo'::text)::date AS dia_inst,
            f.status = ANY (ARRAY['3_instalado'::text, '4_ativo_provisorio'::text, '5_comissao_firme'::text]) AS instalada,
            osab_risco(f.nio_venda_valida, f.nio_pendencia_desc, f.motivo_saida) AS em_risco
           FROM v_funil f
        ), vend AS (
         SELECT base.id,
            base.criado_em,
            base.criado_por,
            base.status,
            base.motivo_saida,
            base.interesse_futuro_em,
            base.origem,
            base.origem_ref,
            base.cliente_nome,
            base.cliente_cpf_cnpj,
            base.cliente_whatsapp,
            base.cliente_email,
            base.segmento,
            base.cep,
            base.logradouro,
            base.numero,
            base.complemento,
            base.bairro,
            base.cidade,
            base.uf,
            base.plano_id,
            base.forma_pagamento,
            base.vencimento_dia,
            base.comissao_prevista,
            base.comissao_paga,
            base.ciclo_pago,
            base.estorno_previsto,
            base.nio_pedido,
            base.nio_contrato,
            base.nio_situacao,
            base.nio_pendencia_cod,
            base.nio_pendencia_desc,
            base.biometria_status,
            base.biometria_em,
            base.vendido_em,
            base.agendamento_registrado_em,
            base.instalacao_agendada_para,
            base.instalado_em,
            base.ativado_em,
            base.docs_entregues_em,
            base.vendedor_id,
            base.trava_cobertura,
            base.trava_area,
            base.trava_sem_produto_ativo,
            base.trava_sem_cancelamento_30d,
            base.trava_cpf_valido,
            base.trava_contato_confirmado,
            base.nio_osab_em,
            base.nio_venda_valida,
            base.valor_mensal,
            base.comissao_nominal,
            base.comissao_adicionais,
            base.bonus_transicao_previsto,
            base.bonus_nmei_previsto,
            base.bonus_m10_potencial,
            base.primeiro_vencimento,
            base.dfv_viabilidade,
            base.dfv_consultado_em,
            base.dfv_consultado_por,
            base.dfv_faixa_credito,
            base.dfv_classificacao,
            base.dfv_hp_livre,
            base.dfv_hcs,
            base.dfv_dispensado,
            base.dfv_dispensa_motivo,
            base.dfv_origem,
            base.dfv_resultado,
            base.dfv_particao,
            base.plano_nome,
            base.plano_familia,
            base.plano_velocidade,
            base.plano_preco,
            base.plano_codigo,
            base.plano_portfolio,
            base.plano_variante,
            base.plano_cluster,
            base.plano_preco_cartao,
            base.plano_taxa_a_vista,
            base.plano_isencao_meses,
            base.vendedor_nome,
            base.horas_sem_agendamento,
            base.dias_esperando_biometria,
            base.docs_prazo_em,
            base.firme_em,
            base.dfv_ok,
            base.dfv_dias,
            base.mes_venda,
            base.dia_venda,
            base.mes_inst,
            base.dia_inst,
            base.instalada,
            base.em_risco
           FROM base
          WHERE base.vendido_em IS NOT NULL AND (base.status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text, '3_instalado'::text, '4_ativo_provisorio'::text, '5_comissao_firme'::text])) AND base.nio_venda_valida IS NOT FALSE
        ), saidas AS (
         SELECT e.venda_id,
            date_trunc('month'::text, (e.criado_em AT TIME ZONE 'America/Sao_Paulo'::text))::date AS mes
           FROM eventos_venda e
          WHERE e.tipo = 'status'::text AND (e.detalhe ->> 'para'::text) = 'saida'::text OR e.tipo = 'criada'::text AND (e.detalhe ->> 'status'::text) = 'saida'::text
        ), meses AS (
         SELECT vend.mes_venda AS mes
           FROM vend
        UNION
         SELECT config_metas.mes
           FROM config_metas
        )
 SELECT m.mes,
    cm.meta_vendas,
    (( SELECT count(*) AS count
           FROM vend
          WHERE vend.mes_venda = m.mes))::integer AS vendidas,
    (( SELECT count(*) AS count
           FROM vend
          WHERE vend.mes_venda = m.mes AND vend.instalada))::integer AS instaladas,
    (( SELECT count(*) AS count
           FROM vend
          WHERE vend.mes_venda = m.mes AND NOT vend.instalada))::integer AS aguardando,
    (( SELECT count(*) AS count
           FROM base
          WHERE (base.status = ANY (ARRAY['4_ativo_provisorio'::text, '5_comissao_firme'::text])) AND COALESCE(base.ativado_em, base.instalado_em) < ((m.mes + '1 mon'::interval) AT TIME ZONE 'America/Sao_Paulo'::text)))::integer AS ativas_carteira,
    (( SELECT count(DISTINCT s.venda_id) AS count
           FROM saidas s
          WHERE s.mes = m.mes))::integer AS saidas,
    ( SELECT b.motivo_saida
           FROM saidas s
             JOIN base b ON b.id = s.venda_id
          WHERE s.mes = m.mes AND b.motivo_saida IS NOT NULL
          GROUP BY b.motivo_saida
          ORDER BY (count(*)) DESC, b.motivo_saida
         LIMIT 1) AS saidas_motivo_top,
    ( SELECT COALESCE(sum(vend.comissao_prevista), 0::numeric) AS "coalesce"
           FROM vend
          WHERE vend.mes_venda = m.mes) AS comissao_prevista,
    ( SELECT COALESCE(sum(vend.comissao_prevista), 0::numeric) AS "coalesce"
           FROM vend
          WHERE vend.mes_venda = m.mes AND vend.instalada) AS comissao_instalada,
    ( SELECT COALESCE(sum(base.comissao_prevista), 0::numeric) AS "coalesce"
           FROM base
          WHERE base.mes_venda = m.mes AND base.em_risco AND base.status <> 'saida'::text) AS comissao_em_risco,
    ( SELECT COALESCE(sum(vend.comissao_nominal), 0::numeric) AS "coalesce"
           FROM vend
          WHERE vend.mes_venda = m.mes) AS comissao_nominal,
    ( SELECT COALESCE(sum(vend.comissao_adicionais), 0::numeric) AS "coalesce"
           FROM vend
          WHERE vend.mes_venda = m.mes) AS comissao_adicionais,
    ( SELECT COALESCE(sum(vend.bonus_transicao_previsto), 0::numeric) AS "coalesce"
           FROM vend
          WHERE vend.mes_venda = m.mes) AS bonus_transicao,
    ( SELECT COALESCE(sum(vend.bonus_nmei_previsto), 0::numeric) AS "coalesce"
           FROM vend
          WHERE vend.mes_venda = m.mes) AS bonus_nmei,
    ( SELECT COALESCE(sum(vend.bonus_m10_potencial), 0::numeric) AS "coalesce"
           FROM vend
          WHERE vend.mes_venda = m.mes) AS bonus_m10_potencial,
    ( SELECT COALESCE(jsonb_object_agg(x.origem, x.n), '{}'::jsonb) AS "coalesce"
           FROM ( SELECT vend.origem,
                    count(*) AS n
                   FROM vend
                  WHERE vend.mes_venda = m.mes
                  GROUP BY vend.origem) x) AS por_origem,
    ( SELECT COALESCE(jsonb_object_agg(COALESCE(x.cidade, '—'::text), x.n), '{}'::jsonb) AS "coalesce"
           FROM ( SELECT vend.cidade,
                    count(*) AS n
                   FROM vend
                  WHERE vend.mes_venda = m.mes
                  GROUP BY vend.cidade) x) AS por_cidade,
    ( SELECT COALESCE(jsonb_agg(jsonb_build_object('nome', x.nome, 'vendidas', x.n, 'instaladas', x.i) ORDER BY x.n DESC, x.nome), '[]'::jsonb) AS "coalesce"
           FROM ( SELECT COALESCE(vend.vendedor_nome, '—'::text) AS nome,
                    count(*) AS n,
                    count(*) FILTER (WHERE vend.instalada) AS i
                   FROM vend
                  WHERE vend.mes_venda = m.mes
                  GROUP BY (COALESCE(vend.vendedor_nome, '—'::text))) x) AS por_vendedor,
    ( SELECT COALESCE(jsonb_object_agg(COALESCE(x.plano_nome, '—'::text), x.n), '{}'::jsonb) AS "coalesce"
           FROM ( SELECT vend.plano_nome,
                    count(*) AS n
                   FROM vend
                  WHERE vend.mes_venda = m.mes
                  GROUP BY vend.plano_nome) x) AS por_plano,
    ( SELECT COALESCE(jsonb_object_agg(COALESCE(x.forma_pagamento, '—'::text), x.n), '{}'::jsonb) AS "coalesce"
           FROM ( SELECT vend.forma_pagamento,
                    count(*) AS n
                   FROM vend
                  WHERE vend.mes_venda = m.mes
                  GROUP BY vend.forma_pagamento) x) AS por_forma,
    ( SELECT COALESCE(jsonb_object_agg(x.dia_venda::text, x.n), '{}'::jsonb) AS "coalesce"
           FROM ( SELECT vend.dia_venda,
                    count(*) AS n
                   FROM vend
                  WHERE vend.mes_venda = m.mes
                  GROUP BY vend.dia_venda) x) AS por_dia_vendas,
    ( SELECT COALESCE(jsonb_object_agg(x.dia_inst::text, x.n), '{}'::jsonb) AS "coalesce"
           FROM ( SELECT base.dia_inst,
                    count(*) AS n
                   FROM base
                  WHERE base.mes_inst = m.mes AND base.instalada
                  GROUP BY base.dia_inst) x) AS por_dia_instaladas
   FROM meses m
     LEFT JOIN config_metas cm ON cm.mes = m.mes;

create or replace view public.v_painel_hoje with (security_invoker = true) as
 WITH f AS (
         SELECT v.id,
            v.criado_em,
            v.criado_por,
            v.status,
            v.motivo_saida,
            v.interesse_futuro_em,
            v.origem,
            v.origem_ref,
            v.cliente_nome,
            v.cliente_cpf_cnpj,
            v.cliente_whatsapp,
            v.cliente_email,
            v.segmento,
            v.cep,
            v.logradouro,
            v.numero,
            v.complemento,
            v.bairro,
            v.cidade,
            v.uf,
            v.plano_id,
            v.forma_pagamento,
            v.vencimento_dia,
            v.comissao_prevista,
            v.comissao_paga,
            v.ciclo_pago,
            v.estorno_previsto,
            v.nio_pedido,
            v.nio_contrato,
            v.nio_situacao,
            v.nio_pendencia_cod,
            v.nio_pendencia_desc,
            v.biometria_status,
            v.biometria_em,
            v.vendido_em,
            v.agendamento_registrado_em,
            v.instalacao_agendada_para,
            v.instalado_em,
            v.ativado_em,
            v.docs_entregues_em,
            v.vendedor_id,
            v.trava_cobertura,
            v.trava_area,
            v.trava_sem_produto_ativo,
            v.trava_sem_cancelamento_30d,
            v.trava_cpf_valido,
            v.trava_contato_confirmado,
            v.nio_osab_em,
            v.nio_venda_valida,
            v.valor_mensal,
            v.comissao_nominal,
            v.comissao_adicionais,
            v.bonus_transicao_previsto,
            v.bonus_nmei_previsto,
            v.bonus_m10_potencial,
            v.primeiro_vencimento,
            v.dfv_viabilidade,
            v.dfv_consultado_em,
            v.dfv_consultado_por,
            v.dfv_faixa_credito,
            v.dfv_classificacao,
            v.dfv_hp_livre,
            v.dfv_hcs,
            v.dfv_dispensado,
            v.dfv_dispensa_motivo,
            v.dfv_origem,
            v.dfv_resultado,
            v.dfv_particao,
            v.plano_nome,
            v.plano_familia,
            v.plano_velocidade,
            v.plano_preco,
            v.plano_codigo,
            v.plano_portfolio,
            v.plano_variante,
            v.plano_cluster,
            v.plano_preco_cartao,
            v.plano_taxa_a_vista,
            v.plano_isencao_meses,
            v.vendedor_nome,
            v.horas_sem_agendamento,
            v.dias_esperando_biometria,
            v.docs_prazo_em,
            v.firme_em,
            v.dfv_ok,
            v.dfv_dias,
            (now() AT TIME ZONE 'America/Sao_Paulo'::text)::date AS hoje
           FROM v_funil v
        )
 SELECT max(hoje) AS hoje,
    count(*) FILTER (WHERE (vendido_em AT TIME ZONE 'America/Sao_Paulo'::text)::date = hoje AND (status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text, '3_instalado'::text, '4_ativo_provisorio'::text, '5_comissao_firme'::text])) AND nio_venda_valida IS NOT FALSE)::integer AS vendas_hoje,
    count(*) FILTER (WHERE (instalado_em AT TIME ZONE 'America/Sao_Paulo'::text)::date = hoje)::integer AS instaladas_hoje,
    count(*) FILTER (WHERE (biometria_em AT TIME ZONE 'America/Sao_Paulo'::text)::date = hoje AND (biometria_status = ANY (ARRAY['agendada'::text, 'aprovada'::text])))::integer AS biometrias_hoje,
    count(*) FILTER (WHERE status = '0_qualificado'::text)::integer AS qualificados,
    count(*) FILTER (WHERE status = '0_qualificado'::text AND biometria_status IS DISTINCT FROM 'aprovada'::text)::integer AS esperando_biometria,
    count(*) FILTER (WHERE horas_sem_agendamento > 4::numeric)::integer AS sem_agendamento_4h,
    count(*) FILTER (WHERE (instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date = hoje AND instalado_em IS NULL AND (status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text])))::integer AS instalacoes_agendadas_hoje,
    count(*) FILTER (WHERE (status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text])) AND (nio_pendencia_cod IS NOT NULL OR nio_pendencia_desc IS NOT NULL))::integer AS pendencias_osab,
    mode() WITHIN GROUP (ORDER BY nio_pendencia_desc) FILTER (WHERE (status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text])) AND nio_pendencia_desc IS NOT NULL) AS pendencia_top
   FROM f;

create or replace view public.v_alertas_contrato with (security_invoker = true) as
 SELECT f.id AS venda_id,
    f.cliente_nome,
    'venda_invalida'::text AS tipo,
    'bad'::text AS nivel,
    'Nio marcou venda inválida'::text || COALESCE(' · '::text || f.nio_pendencia_desc, ''::text) AS texto,
    'venda.html?id='::text || f.id AS link,
    f.nio_osab_em AS desde,
    NULL::numeric AS horas
   FROM v_funil f
  WHERE f.nio_venda_valida IS FALSE AND f.status <> '5_comissao_firme'::text
UNION ALL
 SELECT f.id AS venda_id,
    f.cliente_nome,
    'risco_contrato'::text AS tipo,
    'bad'::text AS nivel,
    'Risco de multa/estorno · '::text || COALESCE(f.nio_pendencia_desc, f.motivo_saida) AS texto,
    'venda.html?id='::text || f.id AS link,
    f.nio_osab_em AS desde,
    NULL::numeric AS horas
   FROM v_funil f
  WHERE f.nio_venda_valida IS NOT FALSE AND osab_risco(NULL::boolean, f.nio_pendencia_desc, f.motivo_saida)
UNION ALL
 SELECT f.id AS venda_id,
    f.cliente_nome,
    'sem_agendamento'::text AS tipo,
    'bad'::text AS nivel,
    ((('vendida há '::text || floor(f.horas_sem_agendamento)::integer) || 'h'::text) || lpad(round((f.horas_sem_agendamento - floor(f.horas_sem_agendamento)) * 60::numeric)::integer::text, 2, '0'::text)) || ' sem agendamento'::text AS texto,
    'instalacoes.html'::text AS link,
    f.vendido_em AS desde,
    f.horas_sem_agendamento AS horas
   FROM v_funil f
  WHERE f.horas_sem_agendamento > 4::numeric
UNION ALL
 SELECT f.id AS venda_id,
    f.cliente_nome,
    'docs'::text AS tipo,
        CASE
            WHEN f.docs_prazo_em < now() THEN 'bad'::text
            ELSE 'warn'::text
        END AS nivel,
        CASE
            WHEN f.docs_prazo_em < now() THEN 'documentos à Nio atrasados desde '::text
            ELSE 'documentos à Nio até '::text
        END || to_char((f.docs_prazo_em AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text) AS texto,
    'venda.html?id='::text || f.id AS link,
    f.instalado_em AS desde,
    NULL::numeric AS horas
   FROM v_funil f
  WHERE f.docs_entregues_em IS NULL AND f.docs_prazo_em IS NOT NULL AND f.docs_prazo_em <= (now() + '3 days'::interval) AND (f.status = ANY (ARRAY['3_instalado'::text, '4_ativo_provisorio'::text]))
UNION ALL
 SELECT f.id AS venda_id,
    f.cliente_nome,
    'dfv_nao_consultado'::text AS tipo,
    'warn'::text AS nivel,
    'DFV não consultado · '::text ||
        CASE
            WHEN f.biometria_status = 'agendada'::text THEN 'biometria marcada'::text
            ELSE 'visita marcada'::text
        END AS texto,
    'venda.html?id='::text || f.id AS link,
    COALESCE(f.biometria_em, f.instalacao_agendada_para, f.criado_em) AS desde,
    NULL::numeric AS horas
   FROM v_funil f
  WHERE f.status = '0_qualificado'::text AND f.dfv_viabilidade = 'nao_consultado'::text AND NOT f.dfv_dispensado AND (f.biometria_status = 'agendada'::text OR f.biometria_em IS NOT NULL OR f.instalacao_agendada_para IS NOT NULL)
UNION ALL
 SELECT f.id AS venda_id,
    f.cliente_nome,
    'dfv_sem_cobertura'::text AS tipo,
    'bad'::text AS nivel,
    ('DFV: '::text ||
        CASE
            WHEN f.dfv_viabilidade = 'sem_viabilidade'::text THEN 'endereço sem viabilidade'::text
            ELSE 'endereço não encontrado'::text
        END) || ' · não vender'::text AS texto,
    'venda.html?id='::text || f.id AS link,
    f.dfv_consultado_em AS desde,
    NULL::numeric AS horas
   FROM v_funil f
  WHERE (f.dfv_viabilidade = ANY (ARRAY['sem_viabilidade'::text, 'nao_encontrado'::text])) AND f.status <> 'saida'::text;
*/
