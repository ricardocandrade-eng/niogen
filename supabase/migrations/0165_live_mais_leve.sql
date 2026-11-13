-- NIOGEN | supabase/migrations/0165_live_mais_leve.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 13/11: "Sim, alivia" — aliviar o Live no que está FORA da régua da Mari (mari_cadencia_avaliar não é tocada).
-- 1. v_mari_quadro: a contagem dos itens coletados ("Mari atendendo · N/9 dados") remontava o JSON da conversa inteira
--    (to_jsonb(c.*)) a cada item e a cada uso — 9 itens × 2 usos por conversa. Agora o JSON é montado UMA vez por conversa
--    ("SELECT ch.j OFFSET 0") e os itens leem dele. Mesmas colunas, mesma ordem, mesmo resultado; filtro por conversa segue
--    descendo até a tabela (não é CTE materializada).
-- 2. chatwoot_acoes: índice por conversa nas ações de mensagem (a v_jornada procurava a última resposta do time lendo a
--    tabela inteira, duas vezes por conversa).
-- Nenhuma regra muda. Ensaio em transação desfeita: v_mari_quadro, v_jornada e v_oportunidades idênticas antes e depois
-- (linha a linha, nos dois sentidos) e o tempo antes e depois, na mesma sessão.

create index if not exists chatwoot_acoes_conversa_msg_idx on public.chatwoot_acoes (conversa_id) where tipo = 'mensagem';

create or replace view public.v_mari_quadro with (security_invoker = true) as
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
                            WHEN _mari_item_validado(i.regra_validado, v.valor, jj.j) THEN 'validado'::text
                            ELSE 'coletado'::text
                        END AS estado
                   FROM ( SELECT ch.j OFFSET 0) jj
                     CROSS JOIN config_mari_itens i
                     CROSS JOIN LATERAL ( SELECT _mari_item_valor(jj.j, i.fonte) AS valor) v
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
