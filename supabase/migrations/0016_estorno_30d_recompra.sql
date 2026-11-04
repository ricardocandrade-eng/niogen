-- NIOGEN | supabase/migrations/0016_estorno_30d_recompra.sql | 04/11/2026
-- Correção do estorno (reunião Ricardo × Rogério, 04/11 — docs/CONTRATO_DHARMA_regras.md "Estorno de comissão"):
-- churn < 180 d e inadimplência NÃO estornam; estorno 100 % = cancelar e reativar em até 30 d, cliente/endereço já com Nio
-- ativo, não qualidade, fraude, fora da área; downgrade ≤ 180 d = só a diferença; recompra = multa de R$ 500 (não é estorno).
--  * v_funil.firme_em (nome mantido): ativação (ou instalação) + 30 d, antes instalado_em + 180 d.
--  * v_funil.downgrade_ate (nova, no fim): ativação + 180 d — só para o aviso de downgrade.
--  * checar_recompra(): o endereço (CEP + número + complemento normalizados) já teve venda no NIOGEN que saiu ou que a Nio cancelou.
-- CREATE OR REPLACE mantém as colunas e a ordem: as views que leem v_funil (v_instalacoes, v_alertas_contrato, v_painel_*) seguem iguais.
--
-- Passo 0 (banco real em 04/11): firme_em só em v_funil; nenhuma função grava estorno_previsto nem trata churn; não existe
-- passagem automática 4 → 5; 0 vendas; migrations 0001–0015.

create or replace view public.v_funil
with (security_invoker = true) as
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
            WHEN v.status = '1_vendido'::text AND v.agendamento_registrado_em IS NULL AND v.vendido_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.vendido_em) / 3600::numeric, 2)
            ELSE NULL::numeric
        END AS horas_sem_agendamento,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.biometria_status IS DISTINCT FROM 'aprovada'::text THEN round(EXTRACT(epoch FROM now() - v.criado_em) / 86400::numeric, 2)
            ELSE NULL::numeric
        END AS dias_esperando_biometria,
    v.instalado_em + '15 days'::interval AS docs_prazo_em,
    -- 04/11: vira 'ganha' 30 dias após a ativação (cancelar e reativar em até 30 d é o estorno de 100 %); churn não estorna.
    COALESCE(v.ativado_em, v.instalado_em) + '30 days'::interval AS firme_em,
    (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) AS dfv_ok,
        CASE
            WHEN v.dfv_consultado_em IS NOT NULL THEN floor(EXTRACT(epoch FROM now() - v.dfv_consultado_em) / 86400::numeric)::integer
            ELSE NULL::integer
        END AS dfv_dias,
    -- Downgrade em até 180 dias da ativação estorna só a diferença de comissão (aviso; não entra no valor em risco).
    COALESCE(v.ativado_em, v.instalado_em) + '180 days'::interval AS downgrade_ate
   FROM vendas v
     LEFT JOIN config_planos p ON p.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id;

comment on column public.v_funil.firme_em is
  'Data em que a comissão vira ''ganha'': ativação (ou instalação) + 30 d. O nome antigo ficou para não quebrar telas e views.';
comment on column public.v_funil.downgrade_ate is
  'Até esta data (ativação + 180 d) um downgrade desconta a diferença de comissão.';

create or replace function public.checar_recompra(p_cep text, p_numero text, p_complemento text default null, p_ignorar uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  -- Recompra: venda nova para endereço que já teve Nio com pedido cancelado → multa de R$ 500 por pedido (não bloqueia).
  with norm as (
    select regexp_replace(coalesce(p_cep, ''), '\D', '', 'g')                     as cep,
           lower(btrim(coalesce(p_numero, '')))                                  as numero,
           regexp_replace(lower(coalesce(p_complemento, '')), '[^a-z0-9]', '', 'g') as comp
  ),
  anteriores as (
    select v.id, v.status, v.nio_situacao, coalesce(v.nio_osab_em, v.criado_em) as quando
    from public.vendas v, norm n
    where n.cep <> '' and n.numero <> ''
      and v.id is distinct from p_ignorar
      and regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = n.cep
      and lower(btrim(coalesce(v.numero, ''))) = n.numero
      and regexp_replace(lower(coalesce(v.complemento, '')), '[^a-z0-9]', '', 'g') = n.comp
      and (v.status = 'saida' or public.osab_cancelada(v.nio_situacao))
  )
  select jsonb_build_object(
    'recompra', count(*) > 0,
    'anteriores', count(*),
    'ultima_em', max(quando))
  from anteriores
  where public.meu_perfil() is not null
$$;

revoke execute on function public.checar_recompra(text, text, text, uuid) from public, anon;
grant execute on function public.checar_recompra(text, text, text, uuid) to authenticated;
