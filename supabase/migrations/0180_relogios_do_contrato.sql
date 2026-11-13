-- NIOGEN | 0180_relogios_do_contrato.sql | 13/11/2026 — Claude Code (etapa 6, fatia 6b: relógios do contrato num lugar só)
-- Os três prazos do contrato passam a sair de UM lugar — config_regras — e chegam às telas já calculados pelas views:
--   • 4 h para agendar a instalação   → config_regras.prazo_agendar_horas   → v_vendas.agendar_ate (+ prazo_agendar_horas)
--   • 15 dias para os documentos      → config_regras.prazo_docs_dias       → v_vendas.docs_prazo_em (+ prazo_docs_dias)
--   • 120 dias para contestar         → config_regras.prazo_contestacao_dias (NOVA) → v_dinheiro.contestar_ate (+ prazo_contestacao_dias)
-- Antes: v_vendas tinha os 15 dias fixos, v_dinheiro os 120 fixos, e a ficha contava as 4 h a partir da venda (o certo, como
-- nas outras telas, é a partir da biometria validada). O relógio das 4 h começa em agendar_desde = biometria validada (ou a
-- venda, se não houver a data da biometria). As views foram recriadas a partir da produção (pg_get_viewdef em 13/11/2026):
-- só as expressões dos prazos mudam e as colunas novas entram no fim. Nenhuma regra de status muda aqui.

insert into public.config_regras (chave, valor, descricao) values
  ('prazo_contestacao_dias', '120'::jsonb,
   'Contrato: dias corridos, a partir da ativação, para contestar a comissão com a Nio. Lido pela trilha do dinheiro (v_dinheiro.contestar_ate). 0180.')
on conflict (chave) do nothing;

create or replace view public.v_vendas with (security_invoker = true) as
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
    p.nome AS plano_nome,
    p.familia AS plano_familia,
    p.velocidade AS plano_velocidade,
    p.preco AS plano_preco,
    p.codigo AS plano_codigo,
    p.portfolio AS plano_portfolio,
    p.variante AS plano_variante,
    p.cluster AS plano_cluster,
    p.preco_cartao AS plano_preco_cartao,
    p.taxa_a_vista AS plano_taxa_a_vista,
    p.isencao_meses AS plano_isencao_meses,
    u.nome AS vendedor_nome,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.biometria_status = 'validada'::text THEN round(EXTRACT(epoch FROM now() - v.biometria_validada_em) / 3600::numeric, 2)
            WHEN v.status = '1_vendido'::text AND v.agendamento_registrado_em IS NULL THEN round(EXTRACT(epoch FROM now() - GREATEST(v.biometria_validada_em, v.vendido_em)) / 3600::numeric, 2)
            ELSE NULL::numeric
        END AS horas_sem_agendamento,
        CASE
            WHEN v.status = '0_qualificado'::text AND COALESCE(btrim(v.nio_pedido), ''::text) <> ''::text AND v.biometria_status IS DISTINCT FROM 'validada'::text THEN round(EXTRACT(epoch FROM now() - COALESCE(v.biometria_link_enviado_em, v.nio_pedido_em, v.criado_em)) / 86400::numeric, 2)
            ELSE NULL::numeric
        END AS dias_esperando_biometria,
    v.instalado_em + make_interval(days => COALESCE(( SELECT (r.valor #>> '{}'::text[])::integer FROM config_regras r WHERE r.chave = 'prazo_docs_dias'::text), 15)) AS docs_prazo_em,
    COALESCE(v.ativado_em, v.instalado_em) + '30 days'::interval AS firme_em,
    (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) AS dfv_ok,
        CASE
            WHEN v.dfv_consultado_em IS NOT NULL THEN floor(EXTRACT(epoch FROM now() - v.dfv_consultado_em) / 86400::numeric)::integer
            ELSE NULL::integer
        END AS dfv_dias,
    COALESCE(v.ativado_em, v.instalado_em) + '180 days'::interval AS downgrade_ate,
    v.nio_viab_resultado,
    v.nio_viab_velocidade,
    v.nio_viab_interesse_id,
    v.nio_viab_endereco_id,
    v.nio_viab_em,
    v.nio_viab_origem,
    v.credito_resultado,
    v.credito_em,
    v.biometria_link,
    v.biometria_link_enviado_em,
    v.biometria_validada_em,
    v.instalacao_preferencia,
    v.instalacao_turno,
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) AS nio_viab_ok,
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) OR (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) OR COALESCE(v.dfv_dispensado, false) AS viab_ok,
        CASE
            WHEN (v.status = ANY (ARRAY['0_qualificado'::text, '1_vendido'::text])) AND (v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text])) AND v.biometria_link_enviado_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.biometria_link_enviado_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_biometria_pendente,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.credito_resultado = 'pendente'::text AND v.credito_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.credito_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_credito_pendente,
    COALESCE(v.biometria_validada_em, v.vendido_em) AS agendar_desde,
    v.nio_viab_endereco_portal,
    v.parceiro_id,
    pa.nome AS parceiro_nome,
    v.conferencia_status,
    v.conferencia_motivo,
    v.conferencia_prazo_ate,
    pe.id AS pend_id,
    pe.motivo AS pend_motivo,
    pm.nome AS pend_motivo_nome,
    pe.descricao AS pend_descricao,
    pe.quem_destrava AS pend_quem,
    pe.aberta_em AS pend_desde,
    pe.revisar_em AS pend_revisar_em,
    pe.revisoes AS pend_revisoes,
    pm.saida_sugerida AS pend_saida_sugerida,
    v.nio_os,
    v.nio_os_em,
    jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS jornada_etapa,
    v.saida_motivo,
    v.saida_sub,
    v.cancelada_apos_instalar_em,
    v.cancelada_apos_instalar_motivo,
    v.nio_pedido_em,
    v.ponto_referencia,
    v.nio_viab_por,
    COALESCE(v.biometria_validada_em, v.vendido_em) + make_interval(secs => (3600::numeric * COALESCE(( SELECT (r.valor #>> '{}'::text[])::numeric FROM config_regras r WHERE r.chave = 'prazo_agendar_horas'::text), 4::numeric))::double precision) AS agendar_ate,
    COALESCE(( SELECT (r.valor #>> '{}'::text[])::numeric FROM config_regras r WHERE r.chave = 'prazo_agendar_horas'::text), 4::numeric) AS prazo_agendar_horas,
    COALESCE(( SELECT (r.valor #>> '{}'::text[])::integer FROM config_regras r WHERE r.chave = 'prazo_docs_dias'::text), 15) AS prazo_docs_dias
   FROM vendas v
     LEFT JOIN config_planos p ON p.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     LEFT JOIN parceiros pa ON pa.id = v.parceiro_id
     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo;

create or replace view public.v_dinheiro with (security_invoker = true) as
 SELECT v.id AS venda_id,
    'dharma'::text AS parceiro_id,
    v.cliente_nome,
    v.cidade,
    v.nio_os,
    v.nio_pedido,
    v.nio_contrato,
    b.base_em AS ativada_em,
    COALESCE(l.prevista, 0::numeric) AS prevista,
    COALESCE(l.bonus_previsto, 0::numeric) AS bonus_previsto,
    COALESCE(l.prevista, 0::numeric) + COALESCE(l.bonus_previsto, 0::numeric) AS previsto_total,
    COALESCE(l.extrato, 0::numeric) AS no_extrato,
    COALESCE(l.estorno, 0::numeric) AS estornado,
    COALESCE(l.multa, 0::numeric) AS multas,
    COALESCE(l.pago, 0::numeric) AS pago,
    COALESCE(l.extrato, 0::numeric) + COALESCE(l.estorno, 0::numeric) + COALESCE(l.multa, 0::numeric) - (COALESCE(l.prevista, 0::numeric) + COALESCE(l.bonus_previsto, 0::numeric)) AS diferenca,
        CASE
            WHEN COALESCE(l.estorno, 0::numeric) < 0::numeric AND (COALESCE(l.extrato, 0::numeric) + COALESCE(l.estorno, 0::numeric)) <= 0::numeric THEN 'estornada'::text
            WHEN COALESCE(l.n_contestacao, 0::bigint) > 0 THEN 'contestada'::text
            WHEN COALESCE(l.pago, 0::numeric) > 0::numeric THEN 'paga'::text
            WHEN COALESCE(l.n_extrato, 0::bigint) > 0 THEN 'no_extrato'::text
            WHEN v.cancelada_apos_instalar_em IS NOT NULL OR (b.base_em + '30 days'::interval) > now() THEN 'em_risco'::text
            ELSE 'firme'::text
        END AS estado,
    v.cancelada_apos_instalar_em,
    v.cancelada_apos_instalar_motivo,
    b.base_em + '30 days'::interval AS risco_ate,
    b.base_em + '180 days'::interval AS downgrade_ate,
    b.base_em + make_interval(days => COALESCE(( SELECT (r.valor #>> '{}'::text[])::integer FROM config_regras r WHERE r.chave = 'prazo_contestacao_dias'::text), 120)) AS contestar_ate,
    b.base_em + '10 mons'::interval AS m10_em,
    v.bonus_m10_potencial,
    b.base_em + make_interval(days => COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::integer AS int4
           FROM config_regras
          WHERE config_regras.chave = 'prazo_docs_dias'::text), 15)) AS docs_ate,
    v.docs_entregues_em,
    l.ciclos,
    COALESCE(( SELECT (r.valor #>> '{}'::text[])::integer FROM config_regras r WHERE r.chave = 'prazo_contestacao_dias'::text), 120) AS prazo_contestacao_dias
   FROM vendas v
     CROSS JOIN LATERAL ( SELECT COALESCE(v.ativado_em, v.instalado_em) AS base_em) b
     LEFT JOIN LATERAL ( SELECT sum(x.valor) FILTER (WHERE x.tipo = 'prevista'::text) AS prevista,
            sum(x.valor) FILTER (WHERE x.tipo = 'bonus_previsto'::text) AS bonus_previsto,
            sum(x.valor) FILTER (WHERE x.tipo = ANY (ARRAY['extrato_comissao'::text, 'extrato_bonus'::text])) AS extrato,
            count(*) FILTER (WHERE x.tipo ~~ 'extrato_%'::text) AS n_extrato,
            sum(x.valor) FILTER (WHERE x.tipo = 'extrato_estorno'::text) AS estorno,
            sum(x.valor) FILTER (WHERE x.tipo = 'multa'::text) AS multa,
            sum(x.valor) FILTER (WHERE x.tipo = 'pagamento'::text) AS pago,
            count(*) FILTER (WHERE x.tipo = 'contestacao'::text) AS n_contestacao,
            array_agg(DISTINCT x.ciclo) FILTER (WHERE x.ciclo IS NOT NULL) AS ciclos
           FROM comissao_lancamentos x
          WHERE x.venda_id = v.id) l ON true
  WHERE v.instalado_em IS NOT NULL OR (v.status = ANY (ARRAY['3_instalado'::text, '4_ativo_provisorio'::text, '5_comissao_firme'::text]));
