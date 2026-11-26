-- NIOGEN | supabase/migrations/0416_conversas_ultima_auto.sql | 26/11/2026 — Claude Code (Opus 5.5)
-- Resumo: a lista de Conversas passa a saber se a ÚLTIMA mensagem foi um disparo automático do sistema (Ricardo, 26/11/2026:
--   "preciso identificar melhor o que são mensagens vindas do cliente e o que são disparos do sistema (cadência)").
--   v_conversas ganha, no fim, a coluna ultima_auto: a marca do turno da Mari que fechou a conversa —
--     tags.cadencia (F1–F5 da janela de 24 h, D3, D7, D15, INSTALACAO, CARTAO, BIO1, BIOVOLTA…) ou
--     tags.backoffice (retomada, sopro, fila_vero_clique, indicacao_*, pos_instalacao, saida, credito…).
--   Nula quando a última fala é do cliente, do time ou uma resposta da Mari. Só leitura: nada muda estado, nada muda o que já existia
--   (mesmas colunas, na mesma ordem; a nova entra no fim, como o "create or replace view" exige). conversas_lista() devolve
--   setof v_conversas e passa a trazer a coluna sozinha.
-- Regra 20: (1–3) nenhum estado novo, nenhuma gravação; (4) a fonte é mari_turnos.tags, gravada por quem dispara; (5) sem número
--   novo para fechar — é rótulo de uma linha que já existe.
begin;

create or replace view public.v_conversas with (security_invoker = true) as
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
    'dharma'::text AS parceiro_id,
    c.funil_etapa,
    c.funil_destino,
    c.funil_detalhe,
    c.funil_destino_em,
    c.funil_alerta,
    c.funil_alerta_em,
        CASE
            WHEN l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone) THEN ( SELECT count(*)::integer AS count
               FROM mari_turnos t3
              WHERE t3.conversa_id = c.id AND t3.papel = 'lead'::text AND t3.created_at > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone))
            ELSE 0
        END AS nao_lidas,
    COALESCE(pv.nome_curto, pv.nome, pe.plano) AS plano,
    v.comissao_prevista AS comissao,
    COALESCE(v.valor_mensal, pe.valor) AS valor_mes,
        CASE
            WHEN u.papel = 'mari'::text THEN COALESCE(NULLIF(u.tags ->> 'cadencia'::text, ''::text), NULLIF(u.tags ->> 'backoffice'::text, ''::text))
            ELSE NULL::text
        END AS ultima_auto
   FROM mari_conversas c
     LEFT JOIN vendas v ON v.id = c.venda_id
     LEFT JOIN config_planos pv ON pv.id = v.plano_id
     LEFT JOIN LATERAL _oport_plano(c.plano_escolhido, c.forma_pagamento, c.cluster, c.segmento) pe(plano, valor) ON v.id IS NULL AND c.plano_escolhido IS NOT NULL
     CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE t.papel = 'lead'::text) AS ult_lead,
            GREATEST(max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])), c.dispensada_em) AS ult_resp
           FROM mari_turnos t
          WHERE t.conversa_id = c.id) l
     LEFT JOIN LATERAL ( SELECT t.papel,
            t.texto,
            t.created_at,
            t.tags
           FROM mari_turnos t
          WHERE t.conversa_id = c.id AND (t.papel = ANY (ARRAY['lead'::text, 'mari'::text, 'humano'::text]))
          ORDER BY t.created_at DESC
         LIMIT 1) u ON true
  WHERE c.canal = 'whatsapp'::text AND COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text;

commit;
