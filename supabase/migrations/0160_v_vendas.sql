-- NIOGEN | supabase/migrations/0160_v_vendas.sql | 13/11/2026 — Claude Code (Opus 5.5)
-- Plano do sistema fechado, etapa 4b (docs/PLANO_sistema_fechado_etapas_121126_2135.md, no Drive): "migrar as 5 telas que leem a
-- v_funil antiga". O nome "funil" agora é a escada (v_leads, 0156); a lista de VENDAS ganha nome próprio.
--
-- 1. v_vendas: a mesma linha por venda da v_funil (mesmas colunas, mesma ordem) + o que a v_funil não tem porque congelou o v.* antes
--    da 0157: saida_motivo · saida_sub (lista única de saída) · cancelada_apos_instalar_em/_motivo · nio_pedido_em · ponto_referencia ·
--    nio_viab_por. É a view que as telas leem (ficha, Vendas, Painel, Instalações, Configurações › OSAB). security_invoker: a RLS da
--    vendas vale para quem consulta (o vendedor vê só as dele).
-- 2. v_funil volta a ser security_invoker. Ela nasceu assim (0023/0024), mas o "create or replace view" sem WITH das 0089, 0111 e
--    0153 apagou a opção: desde 09/11 ela roda com o dono e ignora a RLS da vendas — qualquer usuário logado leria todas as vendas
--    por ela. Hoje só há admin e backoffice, então nada vazou; com o 1º vendedor, vazaria. A v_funil fica só para quem ainda a lê no
--    banco: v_instalacoes e as funções da Mari (mari_entrada pelo n8n com a service role; mari_ao_vivo é security definer) —
--    nenhuma das duas muda de comportamento. Sai na etapa 6, quando a Mari passar a ler a v_vendas.
-- Nada mais muda: nenhuma coluna, função ou dado.

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
    v.instalado_em + '15 days'::interval AS docs_prazo_em,
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
    public.jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS jornada_etapa,
    v.saida_motivo,
    v.saida_sub,
    v.cancelada_apos_instalar_em,
    v.cancelada_apos_instalar_motivo,
    v.nio_pedido_em,
    v.ponto_referencia,
    v.nio_viab_por
   FROM public.vendas v
     LEFT JOIN public.config_planos p ON p.id = v.plano_id
     LEFT JOIN public.usuarios u ON u.id = v.vendedor_id
     LEFT JOIN public.parceiros pa ON pa.id = v.parceiro_id
     LEFT JOIN public.venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
     LEFT JOIN public.config_motivos_pendencia pm ON pm.codigo = pe.motivo;

comment on view public.v_vendas is
  'Uma linha por venda (0160): a v_funil + saida_motivo/saida_sub (lista única), cancelada_apos_instalar_*, nio_pedido_em, ponto_referencia, nio_viab_por. É a que as telas leem; etapa/status/destino do lead ficam na v_leads.';
revoke all on public.v_vendas from anon;
grant select on public.v_vendas to authenticated;
grant select on public.v_vendas to service_role;

alter view public.v_funil set (security_invoker = true);
