-- NIOGEN | supabase/migrations/0126_silenciada_definitiva_de_novo.sql | 12/11/2026 — Claude Code
-- Desfaz a 0124 e a 0125 (Ricardo, 12/11 ~01h: "pode desfazer"). O 📵 silenciar existe para IGNORAR DE VEZ quem só quer reclamar
-- da Nio (caso Marli): mensagem nova não traz a conversa de volta para Esperando resposta, Live ou o alarme. Views voltam à
-- definição da 0100/0111. O que o Ricardo pediu no lugar — "toda conversa precisa aparecer no sistema" — fica no front:
-- Conversas › Todas passa a listar também encerradas e silenciadas (selo 📵), e a busca acha qualquer uma.
-- Nota da RPC: diz onde achar a conversa silenciada.

create or replace view public.v_conversas with (security_invoker=true) as
 SELECT c.id,
    c.venda_id,
    COALESCE(NULLIF(btrim(c.dados ->> 'nome'::text), ''::text), NULLIF(btrim(c.nome_contato), ''::text), 'Contato'::text) AS nome,
    c.telefone,
    c.cidade,
    c.origem,
    c.chatwoot_conversation_id,
    c.chatwoot_status,
    COALESCE(c.chatwoot_etiquetas, '{}'::text[]) AS etiquetas,
        CASE
            WHEN COALESCE(c.nao_contatar, false) THEN NULL::text
            WHEN c.chatwoot_agente IS NOT NULL THEN 'pessoa'::text
            WHEN COALESCE(c.humano_atribuido, false) THEN 'pessoa'::text
            WHEN c.chatwoot_status = 'resolved'::text THEN NULL::text
            WHEN c.chatwoot_time IS NOT NULL THEN 'time'::text
            ELSE 'mari'::text
        END AS dono_tipo,
        CASE
            WHEN COALESCE(c.nao_contatar, false) THEN NULL::text
            WHEN c.chatwoot_agente IS NOT NULL THEN c.chatwoot_agente
            WHEN COALESCE(c.humano_atribuido, false) THEN 'time (assumida)'::text
            WHEN c.chatwoot_status = 'resolved'::text THEN NULL::text
            WHEN c.chatwoot_time IS NOT NULL THEN 'time '::text || c.chatwoot_time
            ELSE 'Mari'::text
        END AS dono_nome,
    COALESCE(u.created_at, c.created_at) AS ultima_em,
    u.papel AS ultima_quem,
    "left"(regexp_replace(COALESCE(u.texto, ''::text), '\s+'::text, ' '::text, 'g'::text), 160) AS ultima_txt,
    l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone) AND l.ult_lead > (now() - '7 days'::interval) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) AND NOT (c.espera_ate IS NOT NULL AND l.ult_lead <= c.espera_em) AND cliente_confirmou_desde(c.id, l.ult_resp) IS NULL AS cliente_esperando,
        CASE
            WHEN l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) AND cliente_confirmou_desde(c.id, l.ult_resp) IS NULL THEN floor(EXTRACT(epoch FROM now() - l.ult_lead) / 60::numeric)::integer
            ELSE NULL::integer
        END AS esperando_min,
    l.ult_lead,
    l.ult_lead IS NOT NULL AND l.ult_lead > (now() - '23:00:00'::interval) AS janela_aberta,
        CASE
            WHEN v.id IS NOT NULL THEN jornada_etapa(v.status, v.nio_pedido, v.credito_resultado)
            ELSE 1
        END AS etapa,
    COALESCE(c.nao_contatar, false) OR (c.status = ANY (ARRAY['encerrado_humano'::text, 'encerrado_ia'::text])) OR COALESCE(v.status, ''::text) = 'saida'::text OR COALESCE(c.quadro_encerrada_motivo, ''::text) = 'suporte_nio'::text AS encerrada,
    c.created_at,
    'dharma'::text AS parceiro_id
   FROM mari_conversas c
     LEFT JOIN vendas v ON v.id = c.venda_id
     CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE t.papel = 'lead'::text) AS ult_lead,
            max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])) AS ult_resp
           FROM mari_turnos t
          WHERE t.conversa_id = c.id) l
     LEFT JOIN LATERAL ( SELECT t.papel,
            t.texto,
            t.created_at
           FROM mari_turnos t
          WHERE t.conversa_id = c.id AND (t.papel = ANY (ARRAY['lead'::text, 'mari'::text, 'humano'::text]))
          ORDER BY t.created_at DESC
         LIMIT 1) u ON true
  WHERE c.canal = 'whatsapp'::text AND COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text;

create or replace view public.v_mari_quadro with (security_invoker=true) as
 WITH base AS (
         SELECT c.id,
            c.telefone,
            c.nome_contato,
            c.nome_confiavel,
            c.canal,
            c.chatwoot_conversation_id,
            c.status,
            c.etapa,
            c.cep,
            c.numero,
            c.complemento,
            c.endereco_cep,
            c.cidade,
            c.uf,
            c.cluster,
            c.dentro_area,
            c.segmento,
            c.mei,
            c.elegibilidade,
            c.dfv_resultado,
            c.dfv_detalhe,
            c.plano_escolhido,
            c.forma_pagamento,
            c.visita_preferencia,
            c.dados,
            c.lgpd_enviada,
            c.upsell_oferecido,
            c.nao_contatar,
            c.ultima_msg_lead_at,
            c.followup_next_at,
            c.followup_count,
            c.agendamento_retorno,
            c.origem,
            c.handoff_motivo,
            c.handoff_em,
            c.venda_id,
            c.ultima_entrada_ts,
            c.processando_ate,
            c.created_at,
            c.updated_at,
            c.ultima_msg_mari_at,
            c.cadencia_passo,
            c.cadencia_passo_em,
            c.cadencia_proximo_em,
            c.cadencia_retorno_em,
            c.visita_confirmada_para,
            c.humano_atribuido,
            c.time_atribuido,
            c.chatwoot_resolvida,
            c.handoff_briefing,
            c.nio_viab_resultado,
            c.nio_viab_velocidade,
            c.nio_viab_interesse_id,
            c.nio_viab_em,
            c.instalacao_preferencia,
            c.nio_viab_endereco_portal,
            c.bio_lembrete_em,
            c.instalacao_avisada_para,
            c.instalacao_avisada_em,
            c.instalacao_lembrada_para,
            c.ciclos_encerrados,
            c.ciclo_anterior,
            c.chatwoot_status,
            c.chatwoot_agente,
            c.chatwoot_time,
            c.chatwoot_etiquetas,
            c.chatwoot_sync_em,
            c.etiqueta_futuro_em,
            c.etiqueta_futuro_para,
            c.quadro_encerrada_motivo,
            c.quadro_encerrada_em,
            c.quadro_encerrada_por,
            to_jsonb(c.*) AS j,
            v.status AS venda_status,
            v.motivo_saida AS venda_motivo_saida,
            ( SELECT max(t.created_at) AS max
                   FROM mari_turnos t
                  WHERE t.conversa_id = c.id AND t.papel = 'humano'::text) AS ult_humano
           FROM mari_conversas c
             LEFT JOIN vendas v ON v.id = c.venda_id
        ), ch AS (
         SELECT b.id,
            b.telefone,
            b.nome_contato,
            b.nome_confiavel,
            b.canal,
            b.chatwoot_conversation_id,
            b.status,
            b.etapa,
            b.cep,
            b.numero,
            b.complemento,
            b.endereco_cep,
            b.cidade,
            b.uf,
            b.cluster,
            b.dentro_area,
            b.segmento,
            b.mei,
            b.elegibilidade,
            b.dfv_resultado,
            b.dfv_detalhe,
            b.plano_escolhido,
            b.forma_pagamento,
            b.visita_preferencia,
            b.dados,
            b.lgpd_enviada,
            b.upsell_oferecido,
            b.nao_contatar,
            b.ultima_msg_lead_at,
            b.followup_next_at,
            b.followup_count,
            b.agendamento_retorno,
            b.origem,
            b.handoff_motivo,
            b.handoff_em,
            b.venda_id,
            b.ultima_entrada_ts,
            b.processando_ate,
            b.created_at,
            b.updated_at,
            b.ultima_msg_mari_at,
            b.cadencia_passo,
            b.cadencia_passo_em,
            b.cadencia_proximo_em,
            b.cadencia_retorno_em,
            b.visita_confirmada_para,
            b.humano_atribuido,
            b.time_atribuido,
            b.chatwoot_resolvida,
            b.handoff_briefing,
            b.nio_viab_resultado,
            b.nio_viab_velocidade,
            b.nio_viab_interesse_id,
            b.nio_viab_em,
            b.instalacao_preferencia,
            b.nio_viab_endereco_portal,
            b.bio_lembrete_em,
            b.instalacao_avisada_para,
            b.instalacao_avisada_em,
            b.instalacao_lembrada_para,
            b.ciclos_encerrados,
            b.ciclo_anterior,
            b.chatwoot_status,
            b.chatwoot_agente,
            b.chatwoot_time,
            b.chatwoot_etiquetas,
            b.chatwoot_sync_em,
            b.etiqueta_futuro_em,
            b.etiqueta_futuro_para,
            b.quadro_encerrada_motivo,
            b.quadro_encerrada_em,
            b.quadro_encerrada_por,
            b.j,
            b.venda_status,
            b.venda_motivo_saida,
            b.ult_humano,
                CASE
                    WHEN b.quadro_encerrada_em IS NOT NULL AND (b.ultima_msg_lead_at IS NULL OR b.ultima_msg_lead_at <= b.quadro_encerrada_em OR b.quadro_encerrada_motivo = 'suporte_nio'::text) THEN 'encerrada'::text
                    WHEN b.status = ANY (ARRAY['encerrado_humano'::text, 'encerrado_ia'::text]) THEN 'encerrada'::text
                    WHEN b.nao_contatar THEN 'encerrada'::text
                    WHEN b.venda_status = 'saida'::text THEN 'encerrada'::text
                    WHEN b.status = 'handoff_realizado'::text AND (b.handoff_motivo = ANY (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'ja_cliente_nio'::text, 'sem_contato'::text])) THEN 'encerrada'::text
                    WHEN b.status = 'handoff_realizado'::text AND b.handoff_motivo = 'dados_completos'::text THEN 'handoff:dados_completos'::text
                    WHEN b.status = 'handoff_realizado'::text OR b.humano_atribuido THEN 'humano'::text
                    ELSE COALESCE(b.etapa, 'abertura'::text)
                END AS etapa_chave
           FROM base b
        )
 SELECT ch.id,
    ch.created_at,
    ch.canal,
    ch.canal = 'teste'::text OR COALESCE(ch.telefone, ''::text) ~~ '5500000000%'::text AS teste,
    COALESCE(NULLIF(btrim(ch.dados ->> 'nome'::text), ''::text), ch.nome_contato) AS nome,
    ch.cidade,
    ch.cluster,
    COALESCE(ch.segmento, 'varejo'::text) AS segmento,
    ch.origem,
    an.ad_nome,
    an.adset_nome,
    an.campanha_nome,
    ch.plano_escolhido,
    p.nome_curto AS plano_nome,
    ch.status,
    ch.etapa,
    ch.etapa_chave,
    ( SELECT k_1.codigo
           FROM config_mari_colunas k_1
          WHERE k_1.ativo AND (ch.etapa_chave = ANY (k_1.etapas))
          ORDER BY k_1.ordem
         LIMIT 1) AS coluna,
        CASE
            WHEN ch.etapa_chave <> 'encerrada'::text THEN NULL::text
            WHEN ch.quadro_encerrada_motivo IS NOT NULL THEN ch.quadro_encerrada_motivo
            WHEN ch.nao_contatar THEN 'nao_contatar'::text
            WHEN ch.handoff_motivo = 'ja_cliente_nio'::text OR (ch.elegibilidade = ANY (ARRAY['ja_cliente'::text, 'cancelou_30d'::text])) THEN 'ja_cliente'::text
            WHEN (ch.handoff_motivo = ANY (ARRAY['fora_de_area'::text, 'sem_cobertura'::text])) OR ch.dentro_area IS FALSE THEN 'fora_area'::text
            WHEN ch.venda_id IS NOT NULL AND COALESCE(ch.venda_status, ''::text) <> 'saida'::text THEN 'venda'::text
            WHEN ch.status = 'encerrado_humano'::text THEN 'zerada'::text
            ELSE 'perdida'::text
        END AS encerrada_motivo,
    ch.venda_motivo_saida,
        CASE
            WHEN ch.etapa_chave <> 'encerrada'::text THEN NULL::text
            WHEN ch.quadro_encerrada_motivo IS NOT NULL THEN COALESCE(( SELECT m.value ->> 'nome'::text
               FROM config_mari_colunas k_1,
                LATERAL jsonb_array_elements(COALESCE(k_1.motivos, '[]'::jsonb)) m(value)
              WHERE k_1.codigo = 'encerrada'::text AND (m.value ->> 'codigo'::text) = ch.quadro_encerrada_motivo
             LIMIT 1), ch.quadro_encerrada_motivo)
            WHEN ch.venda_status = 'saida'::text THEN 'Venda em Saída'::text || COALESCE(' · '::text || ch.venda_motivo_saida, ''::text)
            WHEN ch.nao_contatar THEN 'Não contatar'::text
            WHEN ch.handoff_motivo = 'ja_cliente_nio'::text OR (ch.elegibilidade = ANY (ARRAY['ja_cliente'::text, 'cancelou_30d'::text])) THEN 'Já é cliente Nio'::text
            WHEN (ch.handoff_motivo = ANY (ARRAY['fora_de_area'::text, 'sem_cobertura'::text])) OR ch.dentro_area IS FALSE THEN 'Fora de área'::text
            WHEN ch.venda_id IS NOT NULL THEN 'Venda criada'::text
            WHEN ch.status = 'encerrado_humano'::text THEN 'Memória zerada (#zerar)'::text
            WHEN ch.handoff_motivo = 'recusa_compra'::text THEN 'Perdida · recusou'::text
            WHEN ch.handoff_motivo = 'sem_contato'::text THEN 'Perdida · sem contato'::text
            ELSE 'Perdida'::text
        END AS encerrada_txt,
        CASE
            WHEN ch.etapa_chave = 'encerrada'::text THEN NULL::text
            WHEN ch.status = 'handoff_realizado'::text OR ch.humano_atribuido THEN
            CASE
                WHEN ch.ult_humano IS NOT NULL AND ch.ult_humano >= COALESCE(ch.ultima_msg_lead_at, '-infinity'::timestamp with time zone) THEN 'cliente'::text
                ELSE 'humano'::text
            END
            WHEN ch.ultima_msg_lead_at IS NOT NULL AND ch.ultima_msg_lead_at > COALESCE(ch.ultima_msg_mari_at, '-infinity'::timestamp with time zone) AND ch.ultima_msg_lead_at > COALESCE(ch.ult_humano, '-infinity'::timestamp with time zone) THEN 'mari'::text
            ELSE 'cliente'::text
        END AS vez,
        CASE
            WHEN ch.status = 'handoff_realizado'::text OR ch.humano_atribuido THEN GREATEST(ch.ultima_msg_lead_at, ch.handoff_em)
            ELSE ch.ultima_msg_lead_at
        END AS vez_desde,
    GREATEST(ch.ultima_msg_lead_at, ch.ultima_msg_mari_at, ch.ult_humano, ch.created_at) AS ultima_em,
        CASE GREATEST(ch.ultima_msg_lead_at, ch.ultima_msg_mari_at, ch.ult_humano)
            WHEN ch.ultima_msg_lead_at THEN 'cliente'::text
            WHEN ch.ult_humano THEN 'humano'::text
            WHEN ch.ultima_msg_mari_at THEN 'mari'::text
            ELSE NULL::text
        END AS ultima_quem,
    ch.ultima_msg_lead_at + '24:00:00'::interval AS janela_24h_fecha_em,
    k.proximo_passo,
    k.proximo_em,
    k.pode_enviar,
    k.bloqueio,
    COALESCE(k.toques_hoje, tq.hoje, 0) AS contatos_hoje,
    COALESCE(k.toques_mes, tq.mes, 0) AS contatos_mes,
    array_remove(ARRAY[
        CASE
            WHEN ch.nao_contatar THEN 'nao_contatar'::text
            ELSE NULL::text
        END,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM mari_turnos t
              WHERE t.conversa_id = ch.id AND t.papel = 'lead'::text AND t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)'::text)) THEN 'desconto'::text
            ELSE NULL::text
        END,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM mari_turnos t
              WHERE t.conversa_id = ch.id AND t.papel = 'lead'::text AND t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)'::text)) THEN 'reclamacao_nio'::text
            ELSE NULL::text
        END,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM mari_turnos t
              WHERE t.conversa_id = ch.id AND t.papel = 'lead'::text AND t.texto ~* '(n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))'::text)) THEN 'nao_pedi_contato'::text
            ELSE NULL::text
        END,
        CASE
            WHEN ch.handoff_motivo = 'urgencia_alta'::text OR (EXISTS ( SELECT 1
               FROM mari_turnos t
              WHERE t.conversa_id = ch.id AND t.tags ? 'sinal_urgencia'::text)) THEN 'urgencia'::text
            ELSE NULL::text
        END], NULL::text) AS alertas,
    ch.venda_id,
    ch.venda_status,
    COALESCE(tm.itens_total, 0::bigint) AS itens_total,
    COALESCE(tm.itens_coletados, 0::bigint) AS itens_coletados,
    COALESCE(tm.itens_validados, 0::bigint) AS itens_validados,
    COALESCE(tm.faltam, '{}'::text[]) AS faltam,
    COALESCE(tm.itens, '[]'::jsonb) AS itens,
    tr.trava_cliente_nio,
    tr.trava_endereco_nio,
    tr.trava_viabilidade,
    COALESCE(tm.itens_total, 0::bigint) > 0 AND tm.itens_validados = tm.itens_total AND tr.trava_cliente_nio = 'ok'::text AND tr.trava_endereco_nio <> 'bloqueia'::text AND tr.trava_viabilidade <> 'bloqueia'::text AND (ch.etapa_chave <> ALL (ARRAY['handoff:dados_completos'::text, 'humano'::text, 'encerrada'::text])) AS pronto_handoff,
    ch.chatwoot_conversation_id,
    'dharma'::text AS parceiro_id,
        CASE
            WHEN k.proximo_em IS NOT NULL THEN mari_proximo_horario(k.proximo_em, ch.cidade)
            ELSE NULL::timestamp with time zone
        END AS proximo_toque_em
   FROM ch
     LEFT JOIN config_planos p ON p.codigo = ch.plano_escolhido
     LEFT JOIN LATERAL ( SELECT a.ad_nome,
            a.adset_nome,
            a.campanha_nome
           FROM v_mari_conversa_anuncio a
          WHERE a.conversa_id = ch.id
          ORDER BY a.referral_em DESC NULLS LAST
         LIMIT 1) an ON true
     LEFT JOIN v_mari_cadencia k ON k.conversa_id = ch.id
     LEFT JOIN LATERAL mari_toques(ch.telefone, now()) tq(hoje, mes) ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE x.obrigatorio) AS itens_total,
            count(*) FILTER (WHERE x.obrigatorio AND x.estado <> 'vazio'::text) AS itens_coletados,
            count(*) FILTER (WHERE x.obrigatorio AND x.estado = 'validado'::text) AS itens_validados,
            array_agg(x.nome ORDER BY x.ordem) FILTER (WHERE x.obrigatorio AND x.estado <> 'validado'::text) AS faltam,
            jsonb_agg(jsonb_build_object('codigo', x.codigo, 'nome', x.nome, 'estado', x.estado, 'obrigatorio', x.obrigatorio) ORDER BY x.ordem) AS itens
           FROM ( SELECT i.codigo,
                    i.nome,
                    i.ordem,
                    i.obrigatorio,
                        CASE
                            WHEN v.valor IS NULL THEN 'vazio'::text
                            WHEN _mari_item_validado(i.regra_validado, v.valor, ch.j) THEN 'validado'::text
                            ELSE 'coletado'::text
                        END AS estado
                   FROM config_mari_itens i
                     CROSS JOIN LATERAL ( SELECT _mari_item_valor(ch.j, i.fonte) AS valor) v
                  WHERE i.ativo AND (i.segmento = ANY (ARRAY['ambos'::text,
                        CASE
                            WHEN ch.segmento = 'empresas'::text THEN 'empresas'::text
                            ELSE 'varejo'::text
                        END]))) x) tm ON true
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN (ch.elegibilidade = ANY (ARRAY['ja_cliente'::text, 'cancelou_30d'::text])) OR ch.handoff_motivo = 'ja_cliente_nio'::text THEN 'bloqueia'::text
                    WHEN ch.elegibilidade = 'ok'::text THEN 'ok'::text
                    ELSE 'pendente'::text
                END AS trava_cliente_nio,
                CASE
                    WHEN ch.nio_viab_resultado = 'posse'::text OR ch.dfv_resultado = 'endereco_ocupado'::text THEN 'bloqueia'::text
                    WHEN ch.nio_viab_resultado = 'viavel'::text OR (ch.dfv_resultado = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) THEN 'ok'::text
                    ELSE 'pendente'::text
                END AS trava_endereco_nio,
                CASE
                    WHEN ch.dentro_area IS FALSE OR (ch.handoff_motivo = ANY (ARRAY['fora_de_area'::text, 'sem_cobertura'::text])) THEN 'bloqueia'::text
                    WHEN ch.nio_viab_resultado = 'viavel'::text OR ch.dentro_area AND (ch.dfv_resultado = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) THEN 'ok'::text
                    ELSE 'pendente'::text
                END AS trava_viabilidade) tr;

create or replace view public.v_mari_sem_resposta with (security_invoker=true) as
 WITH cfg AS (
         SELECT COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::boolean AS bool
                   FROM config_regras
                  WHERE config_regras.chave = 'alarme_silencio_ligado'::text), true) AS ligado,
            COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::numeric AS "numeric"
                   FROM config_regras
                  WHERE config_regras.chave = 'alarme_silencio_limite_min'::text), 3::numeric) AS limite_min,
            ( SELECT array_remove(regexp_split_to_array(regexp_replace(COALESCE(config_mari_textos.texto, ''::text), '[^0-9,]'::text, ''::text, 'g'::text), ','::text), ''::text) AS array_remove
                   FROM config_mari_textos
                  WHERE config_mari_textos.chave = 'telefones_teste'::text) AS tels_teste
        ), base AS (
         SELECT c.id,
            c.telefone,
            c.nome_contato,
            c.nome_confiavel,
            c.canal,
            c.chatwoot_conversation_id,
            c.status,
            c.etapa,
            c.cep,
            c.numero,
            c.complemento,
            c.endereco_cep,
            c.cidade,
            c.uf,
            c.cluster,
            c.dentro_area,
            c.segmento,
            c.mei,
            c.elegibilidade,
            c.dfv_resultado,
            c.dfv_detalhe,
            c.plano_escolhido,
            c.forma_pagamento,
            c.visita_preferencia,
            c.dados,
            c.lgpd_enviada,
            c.upsell_oferecido,
            c.nao_contatar,
            c.ultima_msg_lead_at,
            c.followup_next_at,
            c.followup_count,
            c.agendamento_retorno,
            c.origem,
            c.handoff_motivo,
            c.handoff_em,
            c.venda_id,
            c.ultima_entrada_ts,
            c.processando_ate,
            c.created_at,
            c.updated_at,
            c.ultima_msg_mari_at,
            c.cadencia_passo,
            c.cadencia_passo_em,
            c.cadencia_proximo_em,
            c.cadencia_retorno_em,
            c.visita_confirmada_para,
            c.humano_atribuido,
            c.time_atribuido,
            c.chatwoot_resolvida,
            c.handoff_briefing,
            c.nio_viab_resultado,
            c.nio_viab_velocidade,
            c.nio_viab_interesse_id,
            c.nio_viab_em,
            c.instalacao_preferencia,
            c.nio_viab_endereco_portal,
            c.bio_lembrete_em,
            c.instalacao_avisada_para,
            c.instalacao_avisada_em,
            c.instalacao_lembrada_para,
            c.ciclos_encerrados,
            c.ciclo_anterior,
            c.chatwoot_status,
            c.chatwoot_agente,
            c.chatwoot_time,
            c.chatwoot_etiquetas,
            c.chatwoot_sync_em,
            c.etiqueta_futuro_em,
            c.etiqueta_futuro_para,
            c.quadro_encerrada_motivo,
            c.quadro_encerrada_em,
            c.quadro_encerrada_por,
            GREATEST(( SELECT max(t.created_at) AS max
                   FROM mari_turnos t
                  WHERE t.conversa_id = c.id AND t.papel = 'humano'::text), ( SELECT max(a.criada_em) AS max
                   FROM chatwoot_acoes a
                  WHERE a.conversa_id = c.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text])))) AS ult_humano,
            ( SELECT t.texto
                   FROM mari_turnos t
                  WHERE t.conversa_id = c.id AND t.papel = 'lead'::text
                  ORDER BY t.created_at DESC
                 LIMIT 1) AS ult_fala,
            _mari_pos_handoff(c.*) AS pos_handoff
           FROM mari_conversas c
          WHERE COALESCE(c.quadro_encerrada_motivo, ''::text) <> 'suporte_nio'::text AND c.ultima_msg_lead_at IS NOT NULL AND c.ultima_msg_lead_at > (now() - '24:00:00'::interval) AND COALESCE(c.canal, ''::text) <> 'teste'::text AND c.telefone !~~ '5500000000%'::text
        )
 SELECT b.id,
    b.chatwoot_conversation_id,
    split_part(btrim(COALESCE(NULLIF(b.nome_contato, ''::text), 'Contato'::text)), ' '::text, 1) AS nome,
    mari_mascarar_fala(b.ult_fala) AS ultima_fala,
    b.ultima_msg_lead_at AS desde,
    floor(EXTRACT(epoch FROM now() - b.ultima_msg_lead_at) / 60::numeric)::integer AS minutos,
    b.pos_handoff,
    'dharma'::text AS parceiro_id
   FROM base b,
    cfg
  WHERE cfg.ligado AND b.ultima_msg_lead_at > COALESCE(b.ultima_msg_mari_at, '-infinity'::timestamp with time zone) AND b.ultima_msg_lead_at > COALESCE(b.ult_humano, '-infinity'::timestamp with time zone) AND b.ultima_msg_lead_at <= (now() - make_interval(secs => (cfg.limite_min * 60::numeric)::double precision)) AND (b.status = 'ativo'::text AND NOT COALESCE(b.humano_atribuido, false) AND b.chatwoot_agente IS NULL AND NOT COALESCE(b.nao_contatar, false) AND COALESCE(b.chatwoot_status, 'open'::text) <> 'resolved'::text OR b.pos_handoff) AND NOT ((b.telefone = ANY (COALESCE(cfg.tels_teste, '{}'::text[]))) AND (EXISTS ( SELECT 1
           FROM mari_turnos t
             JOIN mari_conversas c2 ON c2.id = t.conversa_id
          WHERE c2.telefone = b.telefone AND t.papel = 'sistema'::text AND t.texto ~~ '[memória da Mari zerada pelo comando #zerar%'::text AND t.created_at > (now() - '00:02:00'::interval))));

CREATE OR REPLACE FUNCTION public.backoffice_conversa_saida(p_conversa uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  g       uuid := gen_random_uuid();
  v_time  int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  quem    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  nomes   jsonb := '{"perdida": "Perdida (sem interesse)", "fora_area": "Fora de área", "ja_cliente": "Já é cliente Nio"}'::jsonb;
  tem_cw  boolean;
  feito   text[] := '{}';
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null and p_motivo <> 'reativar' then
    raise exception 'Esta conversa já tem venda: use a Saída da venda.';
  end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');
  tem_cw := coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%';

  if p_motivo = 'suporte_nio' then
    perform public.mari_cadencia_parar(c.id, p_time => true);
    update public.mari_conversas
       set quadro_encerrada_motivo = 'suporte_nio', quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null
     where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[silenciada no NIOGEN por ' || quem || ' — cliente Nio, suporte/reclamação: não é venda]', false);
    feito := feito || 'fora do Live (mesmo se ele escrever)'::text || 'cadência parada'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'silenciar', null, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('suporte-nio'), 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'silenciar', null, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'silenciar', null, c, 'atribuir', jsonb_build_object('team_id', v_time));
      perform public._bo_enfileirar(g, 4, 'silenciar', null, c, 'nota', jsonb_build_object('content',
        '📵 Silenciada por ' || quem || ' em ' || agora_t || ': cliente Nio com suporte/reclamação — não é venda (somos revenda, '
        || 'não o suporte da Nio). Canal da Nio: App Nio ou 0800. A Mari não responde e a conversa não volta para o Live (fica em Conversas › Todas, com o selo 📵). '
        || 'Para desfazer: ficha da conversa no NIOGEN → Reativar.'));
      perform public._bo_enfileirar(g, 5, 'silenciar', null, c, 'resolver', jsonb_build_object('status', 'snoozed'));
      feito := feito || 'etiqueta suporte-nio'::text || 'time backoffice (a Mari cala)'::text || 'nota'::text || 'adiada no Chatwoot'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito),
      'resumo', '✓ silenciada: a Mari não responde e ela não volta para o Live');

  elsif p_motivo = 'reativar' then
    if coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio' then
      return jsonb_build_object('ok', true, 'feito', '[]'::jsonb, 'resumo', 'A conversa não estava silenciada.');
    end if;
    update public.mari_conversas set quadro_encerrada_motivo = null, quadro_encerrada_em = null, quadro_encerrada_por = null where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[reativada no NIOGEN por ' || quem || ']', false);
    feito := feito || 'de volta no Live'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'reativar', null, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('suporte-nio')));
      perform public._bo_enfileirar(g, 2, 'reativar', null, c, 'nota',
        jsonb_build_object('content', '🔔 Reativada por ' || quem || ' em ' || agora_t || ' — segue com o time; para a Mari voltar, "Devolver para a Mari".'));
      feito := feito || 'etiqueta tirada'::text || 'nota'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ reativada: segue com o time backoffice');

  elsif nomes ? p_motivo then
    perform public.mari_cadencia_parar(c.id, p_resolvida => true);
    update public.mari_conversas
       set quadro_encerrada_motivo = p_motivo, quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null
     where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[encerrada no NIOGEN por ' || quem || ' — ' || (nomes ->> p_motivo) || ']', false);
    feito := feito || 'Saída'::text || 'cadência parada'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'saida', null, c, 'nota', jsonb_build_object('content',
        '⛔ Saída · ' || (nomes ->> p_motivo) || ' — ' || quem || ', ' || agora_t || '. Se o cliente escrever de novo, volta para o Live.'));
      perform public._bo_enfileirar(g, 2, 'saida', null, c, 'resolver', jsonb_build_object('status', 'resolved'));
      feito := feito || 'nota'::text || 'conversa resolvida'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ Saída · ' || (nomes ->> p_motivo));
  end if;
  raise exception 'Motivo desconhecido: %', p_motivo;
end;
$function$;
