-- NIOGEN | supabase/migrations/0216_live_resolvida_so_sem_destino.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Correção da 0214: "Resolvida no Chatwoot e sem saída" pegava também conversa resolvida COM destino de saída legítimo
-- (sem cobertura, fora da área, já cliente Nio, recusou). Agora só sobe para Para fazer a resolvida com destino "em andamento"
-- (ou sem destino) — a que de fato parou sem saída. Resolvida com destino de saída não entra nem em Acompanhando.
-- (Número 0216: a 0215 fica para a migration do celular, hoje com o nome repetido 0214_celular_pwa_push.)
-- Regra 20: sem estado novo; só a leitura da Live. Desempenho: mesma consulta (+1 comparação).
begin;
create or replace view public.v_jornada as  SELECT j.tipo,
    j.chave,
    j.venda_id,
    j.conversa_id,
    j.chatwoot_conversation_id,
    j.nome,
    j.cidade,
    j.plano,
    j.origem,
    j.etapa,
    j.etapa_nome,
    j.precisa_acao OR a.usa OR COALESCE(p.sobe, false) AS precisa_acao,
        CASE
            WHEN a.usa THEN a.nivel
            WHEN p.k IS NOT NULL THEN p.nivel
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN a.usa THEN a.texto
            WHEN p.k IS NOT NULL THEN p.texto
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN a.usa THEN a.botao
            ELSE j.botao
        END AS botao,
        CASE
            WHEN a.usa THEN a.em
            WHEN p.k IS NOT NULL THEN p.desde
            ELSE j.desde
        END AS desde,
    j.dono_tipo,
    j.dono_nome,
    j.pendencia,
    j.acao_id,
    j.status_venda,
    j.parceiro_id,
    j.sem_dono_min,
    j.pedido_provisorio,
    j.cliente_confirmou,
    j.confirmou_em,
    an.portal_status,
    an.portal_desde AS portal_status_desde,
    an.bio_resultado AS biometria_ged,
    an.bio_desde AS biometria_ged_desde,
    COALESCE(p.k = 'parado'::text, false) AS cliente_parado
   FROM v_jornada_base j
     LEFT JOIN v_venda_andamento an ON an.venda_id = j.venda_id
     LEFT JOIN v_instalacao_confirmacao ic ON ic.venda_id = j.venda_id AND ic.resposta = 'remarcar'::text
     LEFT JOIN LATERAL ( SELECT x.texto,
            x.nivel,
            x.em,
            x.botao
           FROM ( VALUES (an.portal_alerta,an.portal_alerta_nivel,an.portal_desde,'abrir'::text), (an.bio_alerta,an.bio_alerta_nivel,an.bio_desde,'abrir'::text), (
                        CASE
                            WHEN ic.venda_id IS NOT NULL THEN 'Cliente pediu para remarcar a instalação · reagendar no portal e gravar'::text
                            ELSE NULL::text
                        END,'agora'::text,ic.resposta_em,'reagendar'::text)) x(texto, nivel, em, botao)
          WHERE x.texto IS NOT NULL
          ORDER BY (
                CASE x.nivel
                    WHEN 'agora'::text THEN 0
                    ELSE 1
                END), x.em
         LIMIT 1) al ON true
     CROSS JOIN LATERAL ( SELECT al.texto,
            al.nivel,
            al.em,
            al.botao,
            COALESCE(al.texto IS NOT NULL AND j.etapa > 0 AND (j.nivel <> 'agora'::text OR al.botao = 'reagendar'::text AND j.botao = 'responder'::text) AND
                CASE al.nivel
                    WHEN 'agora'::text THEN 0
                    ELSE 1
                END <=
                CASE j.nivel
                    WHEN 'hoje'::text THEN 1
                    ELSE 2
                END, false) AS usa) a
     CROSS JOIN ( SELECT COALESCE((r.valor ->> 'parado_min')::integer, 60) AS parado_min,
            COALESCE((r.valor ->> 'janela_fecha_h')::integer, 23) AS janela_fecha_h,
            COALESCE((r.valor ->> 'sobe_h')::integer, 3) AS sobe_h,
            COALESCE((r.valor ->> 'dias_max')::integer, 15) AS dias_max
           FROM ( SELECT ( SELECT config_regras.valor
                           FROM config_regras
                          WHERE config_regras.chave = 'live_cliente_parado'::text) AS valor) r) cp
     LEFT JOIN mari_conversas mc ON j.tipo = 'conversa'::text AND mc.id = j.conversa_id
     LEFT JOIN LATERAL ( SELECT q.k,
                CASE q.k
                    WHEN 'parado'::text THEN 'espera'::text
                    ELSE 'hoje'::text
                END AS nivel,
            q.k = ANY (ARRAY['resolvida'::text, 'janela'::text]) AS sobe,
                CASE q.k
                    WHEN 'resolvida'::text THEN 'Resolvida no Chatwoot e sem saída no NIOGEN · a Mari parou de cutucar · dar saída ou retomar'::text
                    WHEN 'janela'::text THEN (('Cliente parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) || ' · a janela de 24 h fecha às '::text)
                        || to_char((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text, 'HH24:MI'::text) || ' · cutucar agora (texto livre)'::text
                    ELSE ('Vez do cliente · parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) ||
                        CASE
                            WHEN (mc.ultima_msg_lead_at + '24:00:00'::interval) > now() THEN ' · janela de 24 h até '::text
                                || to_char((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text, 'DD/MM HH24:MI'::text)
                            ELSE ' · janela fechada (só template)'::text
                        END
                END AS texto,
            mc.ultima_msg_mari_at AS desde
           FROM ( SELECT
                        CASE
                            WHEN mc.id IS NULL OR j.precisa_acao OR a.usa OR j.pendencia OR COALESCE(j.dono_tipo, 'mari'::text) <> 'mari'::text
                              OR mc.status <> 'ativo'::text OR COALESCE(mc.nao_contatar, false) OR mc.ultima_msg_lead_at IS NULL
                              OR mc.ultima_msg_mari_at IS NULL OR mc.ultima_msg_mari_at < mc.ultima_msg_lead_at
                              OR mc.ultima_msg_lead_at < (now() - make_interval(days => cp.dias_max)) THEN NULL::text
                            WHEN COALESCE(mc.chatwoot_resolvida, false) AND COALESCE(mc.funil_destino, 'em_andamento'::text) <> 'em_andamento'::text THEN NULL::text
                            WHEN COALESCE(mc.chatwoot_resolvida, false) THEN 'resolvida'::text
                            WHEN mc.ultima_msg_mari_at > (now() - make_interval(mins => cp.parado_min)) THEN NULL::text
                            WHEN (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) > now()
                             AND (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) <= (now() + make_interval(hours => cp.sobe_h)) THEN 'janela'::text
                            ELSE 'parado'::text
                        END AS k) q
          WHERE q.k IS NOT NULL) p ON true;

commit;
