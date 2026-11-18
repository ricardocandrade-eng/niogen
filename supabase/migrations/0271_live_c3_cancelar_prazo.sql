-- NIOGEN | supabase/migrations/0271_live_c3_cancelar_prazo.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 6 do caminho (porta única), a Live — Ricardo, 17/11: "Pode começar" (protótipo claude.ai/artifact/Jm85a2vNmDdugxkinkBYKt) e
-- "Sim, comece a Live". Duas decisões abertas desde a 0266/0265, como foram propostas no debate da Live:
--   (1) C3: handoff "interesse caindo" / "múltiplos decisores" fica com a Mari (0266) E vira oportunidade 🔥 na Live — regra O10 em
--       config_oportunidades (3 dias depois do handoff, fora do teto diário, como O7–O9), motivo e texto sugerido (op_O10).
--       Só o miolo de v_oportunidades muda (mesmas colunas: oportunidades_abertas devolve setof v_oportunidades).
--   (2) "Cancelar na Nio" (live_conferir, 0157/0233): prazo de 24 h úteis a contar da Saída (config_regras.time_horario) e o dono
--       (quem deu a Saída) no texto; vencido começa com "VENCIDO" e a Live acende a linha.
-- Regra 20: (1) e (2) não criam estado; (2) é o prazo que vira alerta (regra 2/7); conferência: cenário X11 no portão.
begin;

insert into public.config_oportunidades (codigo, nome, ativo, pontos, ordem, parametros, descricao) values
  ('O10', 'Interesse caindo (fica com a Mari)', true, 60, 100, '{"dias": 3}'::jsonb,
   'C3 (17/11): a Mari passou por interesse caindo ou múltiplos decisores — o lead fica com ela e o time pode esquentar')
on conflict (codigo) do update set nome = excluded.nome, ativo = excluded.ativo, pontos = excluded.pontos, parametros = excluded.parametros, descricao = excluded.descricao;

update public.config_oportunidades
   set parametros = jsonb_set(parametros, '{fora_do_teto}',
         (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(coalesce(parametros -> 'fora_do_teto', '[]'::jsonb) || '["O10"]'::jsonb) x))
 where codigo = 'geral';

insert into public.config_mari_textos (chave, texto)
select 'op_O10', 'Oi[, {nome}]! Aqui é {agente}, que está cuidando do seu pedido de internet fibra 😊 Ficou alguma dúvida sobre os planos ou a instalação? Se quiser, te ajudo a comparar com calma.'
 where not exists (select 1 from public.config_mari_textos where chave = 'op_O10');

create or replace view public.v_oportunidades with (security_invoker = true) as
 WITH cfg AS (
         SELECT COALESCE((g.p ->> 'ligado'::text)::boolean, true) AS ligado,
            COALESCE((g.p ->> 'max_dia'::text)::integer, 5) AS max_dia,
            COALESCE((g.p ->> 'max_por_conversa_dia'::text)::integer, 1) AS max_conv,
            COALESCE((g.p ->> 'max_parado_dias'::text)::numeric, 7::numeric) AS max_dias,
            COALESCE((g.p ->> 'janela_horas'::text)::numeric, 23::numeric) AS janela_h,
            g.p ->> 'template'::text AS tpl,
            COALESCE(g.p -> 'fora_do_teto'::text, '["O7", "O8", "O9"]'::jsonb) AS fora,
            (now() AT TIME ZONE 'America/Sao_Paulo'::text)::date AS hoje
           FROM ( SELECT COALESCE(( SELECT config_oportunidades.parametros
                           FROM config_oportunidades
                          WHERE config_oportunidades.codigo = 'geral'::text), '{}'::jsonb) AS p) g
        ), regra AS (
         SELECT config_oportunidades.codigo,
            config_oportunidades.nome,
            config_oportunidades.pontos,
            config_oportunidades.ordem,
            config_oportunidades.parametros AS p
           FROM config_oportunidades
          WHERE config_oportunidades.ativo AND config_oportunidades.codigo <> 'geral'::text
        ), tpl AS (
         SELECT t.nome
           FROM config_templates_waba t,
            cfg cfg_1
          WHERE t.uso = 'oportunidade'::text AND t.status = 'APPROVED'::text AND (cfg_1.tpl IS NULL OR t.nome = cfg_1.tpl)
          ORDER BY t.nome
         LIMIT 1
        ), feitas_hoje AS (
         SELECT l.conversa_id,
            count(*) AS n
           FROM oportunidades_log l,
            cfg cfg_1
          WHERE (l.tipo = ANY (ARRAY['enviada'::text, 'dispensada'::text])) AND (l.criado_em AT TIME ZONE 'America/Sao_Paulo'::text)::date = cfg_1.hoje
          GROUP BY l.conversa_id
        ), eu AS (
         SELECT NULLIF(split_part(btrim(u.nome), ' '::text, 1), ''::text) AS nome
           FROM usuarios u
          WHERE u.id = auth.uid()
        ), base AS (
         SELECT q.id AS conversa_id,
            q.nome,
            q.cidade,
            q.cluster,
            q.segmento,
            q.coluna,
            q.plano_escolhido,
            q.plano_nome,
            q.itens_validados,
            q.itens_total,
            q.alertas,
            q.trava_viabilidade,
            q.trava_endereco_nio,
            q.ultima_em AS parado_desde,
            c.ultima_msg_lead_at,
            c.forma_pagamento,
            c.dados,
            c.chatwoot_conversation_id,
            c.telefone,
            ( SELECT s.evento FROM porta_sombra s WHERE s.conversa_id = c.id AND (s.evento = ANY (ARRAY['mari_passou:interesse_caindo'::text, 'mari_passou:multiplos_decisores'::text])) ORDER BY s.em DESC LIMIT 1) AS c3_evento,
            ( SELECT max(s.em) FROM porta_sombra s WHERE s.conversa_id = c.id AND (s.evento = ANY (ARRAY['mari_passou:interesse_caindo'::text, 'mari_passou:multiplos_decisores'::text]))) AS c3_em,
            COALESCE(NULLIF(split_part(btrim(c.dados ->> 'nome'::text), ' '::text, 1), ''::text),
                CASE
                    WHEN c.nome_confiavel THEN NULLIF(split_part(btrim(c.nome_contato), ' '::text, 1), ''::text)
                    ELSE NULL::text
                END) AS primeiro_nome,
            mari_cadencia_nome(c.*) AS nome_template,
            c.ultima_msg_lead_at + cfg_1.janela_h::double precision * '01:00:00'::interval AS janela_fecha_em,
            minutos_uteis(q.ultima_em, now(), q.cidade) AS min_uteis,
            (EXISTS ( SELECT 1
                   FROM mari_turnos t
                  WHERE t.conversa_id = q.id AND t.papel = 'mari'::text AND t.tags ? 'carrossel'::text)) AS viu_planos
           FROM v_mari_quadro q
             JOIN mari_conversas c ON c.id = q.id
             CROSS JOIN cfg cfg_1
          WHERE cfg_1.ligado AND NOT q.teste AND (q.coluna = ANY (ARRAY['novo'::text, 'qualificando'::text, 'planos'::text, 'dados'::text, 'retomada'::text])) AND q.vez = 'cliente'::text AND COALESCE(q.ultima_quem, ''::text) <> 'humano'::text AND q.venda_id IS NULL AND c.canal = 'whatsapp'::text AND COALESCE(c.chatwoot_conversation_id, ''::text) <> ''::text AND NOT COALESCE(c.nao_contatar, false) AND NOT COALESCE(c.humano_atribuido, false) AND c.chatwoot_agente IS NULL AND (c.espera_ate IS NULL OR c.espera_ate <= now()) AND q.trava_cliente_nio <> 'bloqueia'::text AND q.trava_viabilidade <> 'bloqueia'::text AND q.trava_endereco_nio <> 'bloqueia'::text AND q.ultima_em > (now() - cfg_1.max_dias::double precision * '1 day'::interval) AND COALESCE(( SELECT f.n
                   FROM feitas_hoje f
                  WHERE f.conversa_id = q.id), 0::bigint) < cfg_1.max_conv AND NOT (EXISTS ( SELECT 1
                   FROM oportunidades_log l
                  WHERE l.conversa_id = q.id AND l.tipo = 'enviada'::text AND l.criado_em > COALESCE(c.ultima_msg_lead_at, '-infinity'::timestamp with time zone)))
        ), bate AS (
         SELECT b.conversa_id,
            b.nome,
            b.cidade,
            b.cluster,
            b.segmento,
            b.coluna,
            b.plano_escolhido,
            b.plano_nome,
            b.itens_validados,
            b.itens_total,
            b.alertas,
            b.trava_viabilidade,
            b.trava_endereco_nio,
            b.parado_desde,
            b.ultima_msg_lead_at,
            b.forma_pagamento,
            b.dados,
            b.chatwoot_conversation_id,
            b.telefone,
            b.primeiro_nome,
            b.nome_template,
            b.janela_fecha_em,
            b.min_uteis,
            b.viu_planos,
            r.codigo,
            r.pontos,
            r.ordem
           FROM base b
             JOIN regra r ON
                CASE r.codigo
                    WHEN 'O1'::text THEN b.janela_fecha_em > now() AND b.janela_fecha_em <= (now() + COALESCE((r.p ->> 'fecha_em_horas'::text)::numeric, 4::numeric)::double precision * '01:00:00'::interval) AND (b.itens_validados >= COALESCE((r.p ->> 'termometro_min'::text)::integer, 2) OR b.viu_planos OR b.coluna = 'planos'::text)
                    WHEN 'O2'::text THEN b.coluna = 'planos'::text AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 2::numeric) * 60::numeric) AND b.parado_desde >= (now() - COALESCE((r.p ->> 'max_horas'::text)::numeric, 48::numeric)::double precision * '01:00:00'::interval)
                    WHEN 'O3'::text THEN ((b.dados ->> 'objecao'::text IN ( SELECT jsonb_array_elements_text(COALESCE(r.p -> 'objecoes'::text, '[]'::jsonb)) AS jsonb_array_elements_text)) OR b.alertas && (ARRAY( SELECT jsonb_array_elements_text(COALESCE(r.p -> 'alertas'::text, '[]'::jsonb)) AS jsonb_array_elements_text))) AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 1::numeric) * 60::numeric)
                    WHEN 'O4'::text THEN b.itens_validados >= COALESCE((r.p ->> 'termometro_min'::text)::integer, 6) AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 1::numeric) * 60::numeric)
                    WHEN 'O5'::text THEN b.trava_viabilidade = 'ok'::text AND b.trava_endereco_nio = 'ok'::text AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 1::numeric) * 60::numeric)
                    WHEN 'O10'::text THEN b.c3_em IS NOT NULL AND b.c3_em > (now() - COALESCE((r.p ->> 'dias'::text)::numeric, 3::numeric)::double precision * '1 day'::interval)
                    ELSE false
                END
        ), agg AS (
         SELECT bate.conversa_id,
            (array_agg(bate.codigo ORDER BY bate.pontos DESC, bate.ordem))[1] AS codigo,
            array_agg(bate.codigo ORDER BY bate.pontos DESC, bate.ordem) AS regras,
            sum(bate.pontos)::integer AS pontos
           FROM bate
          GROUP BY bate.conversa_id
        ), linha AS (
         SELECT a.conversa_id,
            a.codigo,
            a.regras,
            a.pontos,
            b.nome,
            b.primeiro_nome,
            b.nome_template,
            b.cidade,
            b.coluna,
            b.parado_desde,
            b.janela_fecha_em,
            b.chatwoot_conversation_id,
            b.itens_validados,
            b.itens_total,
            b.telefone,
            COALESCE(b.plano_nome, pv.plano) AS plano,
            pv.valor AS valor_mes,
                CASE
                    WHEN b.janela_fecha_em > now() THEN 'livre'::text
                    WHEN (EXISTS ( SELECT 1
                       FROM tpl)) THEN 'template'::text
                    ELSE 'ligar'::text
                END AS canal,
            ( SELECT t.nome
                   FROM tpl t) AS template,
                CASE a.codigo
                    WHEN 'O1'::text THEN ('Janela de 24 h fecha em '::text || _oport_dur(b.janela_fecha_em - now())) ||
                    CASE
                        WHEN b.coluna = 'planos'::text OR b.viu_planos THEN ' · já viu os planos'::text
                        ELSE ''::text
                    END
                    WHEN 'O2'::text THEN ('Viu os planos há '::text || _oport_dur(now() - b.parado_desde)) || ' e não escolheu'::text
                    WHEN 'O3'::text THEN (
                    CASE
                        WHEN 'desconto'::text = ANY (b.alertas) THEN 'Pediu desconto'::text
                        ELSE 'Objeção: '::text || COALESCE(
                        CASE b.dados ->> 'objecao'::text
                            WHEN 'preco'::text THEN 'achou caro'::text
                            WHEN 'pensar'::text THEN 'vai pensar'::text
                            WHEN 'consultar_alguem'::text THEN 'vai ver com alguém'::text
                            WHEN 'ja_tem'::text THEN 'já tem internet'::text
                            WHEN 'marca'::text THEN 'não conhece a Nio'::text
                            WHEN 'sem_5g'::text THEN 'não precisa do 5G'::text
                            ELSE NULL::text
                        END, b.dados ->> 'objecao'::text)
                    END || ' · sem resposta há '::text) || _oport_dur(now() - b.parado_desde)
                    WHEN 'O4'::text THEN (((('Quase pronto: '::text || b.itens_validados) || '/'::text) || b.itens_total) || ' dados · parou há '::text) || _oport_dur(now() - b.parado_desde)
                    WHEN 'O5'::text THEN 'Viabilidade ok e endereço livre · parou há '::text || _oport_dur(now() - b.parado_desde)
                    WHEN 'O10'::text THEN (CASE b.c3_evento WHEN 'mari_passou:multiplos_decisores'::text THEN 'Vai decidir com outra pessoa'::text ELSE 'Interesse caindo'::text END || ' · a Mari segue · sem resposta há '::text) || _oport_dur(now() - b.parado_desde)
                    ELSE NULL::text
                END ||
                CASE
                    WHEN a.codigo <> 'O1'::text AND ('O1'::text = ANY (a.regras)) THEN ' · janela fecha em '::text || _oport_dur(b.janela_fecha_em - now())
                    ELSE ''::text
                END AS motivo
           FROM agg a
             JOIN base b ON b.conversa_id = a.conversa_id
             LEFT JOIN LATERAL _oport_plano(b.plano_escolhido, b.forma_pagamento, b.cluster, b.segmento) pv(plano, valor) ON true
        ), regra_v AS (
         SELECT config_oportunidades.codigo,
            config_oportunidades.pontos,
            config_oportunidades.ordem,
            config_oportunidades.parametros AS p
           FROM config_oportunidades
          WHERE config_oportunidades.ativo AND (config_oportunidades.codigo = ANY (ARRAY['O6'::text, 'O7'::text, 'O8'::text, 'O9'::text]))
        ), vbase AS (
         SELECT v.id AS venda_id,
            v.status,
            v.cliente_nome,
            v.cidade,
            v.motivo_saida,
            v.interesse_futuro_em,
            v.comissao_prevista,
            v.valor_mensal,
            v.instalacao_agendada_para,
            v.instalacao_turno,
            v.agendamento_registrado_em,
            v.dfv_hp_livre,
            v.conferencia_motivo,
            COALESCE(pl.nome_curto, pl.nome) AS plano_nome,
            c.id AS conversa_id,
            c.chatwoot_conversation_id,
            c.telefone,
            COALESCE(NULLIF(split_part(btrim(v.cliente_nome), ' '::text, 1), ''::text), 'tudo bem'::text) AS primeiro_nome,
            mari_cadencia_nome(ROW(c.id, c.telefone, c.nome_contato, c.nome_confiavel, c.canal, c.chatwoot_conversation_id, c.status, c.etapa, c.cep, c.numero, c.complemento, c.endereco_cep, c.cidade, c.uf, c.cluster, c.dentro_area, c.segmento, c.mei, c.elegibilidade, c.dfv_resultado, c.dfv_detalhe, c.plano_escolhido, c.forma_pagamento, c.visita_preferencia, c.dados, c.lgpd_enviada, c.upsell_oferecido, c.nao_contatar, c.ultima_msg_lead_at, c.followup_next_at, c.followup_count, c.agendamento_retorno, c.origem, c.handoff_motivo, c.handoff_em, c.venda_id, c.ultima_entrada_ts, c.processando_ate, c.created_at, c.updated_at, c.ultima_msg_mari_at, c.cadencia_passo, c.cadencia_passo_em, c.cadencia_proximo_em, c.cadencia_retorno_em, c.visita_confirmada_para, c.humano_atribuido, c.time_atribuido, c.chatwoot_resolvida, c.handoff_briefing, c.nio_viab_resultado, c.nio_viab_velocidade, c.nio_viab_interesse_id, c.nio_viab_em, c.instalacao_preferencia, c.nio_viab_endereco_portal, c.bio_lembrete_em, c.instalacao_avisada_para, c.instalacao_avisada_em, c.instalacao_lembrada_para, c.ciclos_encerrados, c.ciclo_anterior, c.chatwoot_status, c.chatwoot_agente, c.chatwoot_time, c.chatwoot_etiquetas, c.chatwoot_sync_em, c.etiqueta_futuro_em, c.etiqueta_futuro_para, c.quadro_encerrada_motivo, c.quadro_encerrada_em, c.quadro_encerrada_por, c.espera_ate, c.espera_motivo, c.espera_em, c.espera_por, NULL::text, NULL::jsonb, NULL::timestamp with time zone, NULL::integer, NULL::text, NULL::timestamp with time zone, NULL::integer, NULL::timestamp with time zone, NULL::text, NULL::timestamp with time zone, NULL::text, NULL::jsonb, NULL::timestamp with time zone, NULL::integer, NULL::timestamp with time zone, NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::timestamp with time zone, NULL::text, NULL::text, NULL::timestamp with time zone, NULL::text, NULL::text, NULL::date, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::jsonb, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::uuid, NULL::text, NULL::uuid, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::text, NULL::timestamp with time zone, NULL::jsonb, NULL::jsonb, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::uuid)) AS nome_template,
            c.ultima_msg_lead_at + cfg_1.janela_h::double precision * '01:00:00'::interval AS janela_fecha_em,
            _oport_chave_motivo(v.motivo_saida, v.saida_motivo, v.saida_sub, v.interesse_futuro_em) AS chave_motivo,
            COALESCE(( SELECT max(e.criado_em) AS max
                   FROM eventos_venda e
                  WHERE e.venda_id = v.id AND e.tipo = 'status'::text AND (e.detalhe ->> 'para'::text) = 'saida'::text), v.criado_em) AS saida_em,
            ic.resposta AS confirmacao
           FROM vendas v
             JOIN LATERAL ( SELECT c2.id,
                    c2.telefone,
                    c2.nome_contato,
                    c2.nome_confiavel,
                    c2.canal,
                    c2.chatwoot_conversation_id,
                    c2.status,
                    c2.etapa,
                    c2.cep,
                    c2.numero,
                    c2.complemento,
                    c2.endereco_cep,
                    c2.cidade,
                    c2.uf,
                    c2.cluster,
                    c2.dentro_area,
                    c2.segmento,
                    c2.mei,
                    c2.elegibilidade,
                    c2.dfv_resultado,
                    c2.dfv_detalhe,
                    c2.plano_escolhido,
                    c2.forma_pagamento,
                    c2.visita_preferencia,
                    c2.dados,
                    c2.lgpd_enviada,
                    c2.upsell_oferecido,
                    c2.nao_contatar,
                    c2.ultima_msg_lead_at,
                    c2.followup_next_at,
                    c2.followup_count,
                    c2.agendamento_retorno,
                    c2.origem,
                    c2.handoff_motivo,
                    c2.handoff_em,
                    c2.venda_id,
                    c2.ultima_entrada_ts,
                    c2.processando_ate,
                    c2.created_at,
                    c2.updated_at,
                    c2.ultima_msg_mari_at,
                    c2.cadencia_passo,
                    c2.cadencia_passo_em,
                    c2.cadencia_proximo_em,
                    c2.cadencia_retorno_em,
                    c2.visita_confirmada_para,
                    c2.humano_atribuido,
                    c2.time_atribuido,
                    c2.chatwoot_resolvida,
                    c2.handoff_briefing,
                    c2.nio_viab_resultado,
                    c2.nio_viab_velocidade,
                    c2.nio_viab_interesse_id,
                    c2.nio_viab_em,
                    c2.instalacao_preferencia,
                    c2.nio_viab_endereco_portal,
                    c2.bio_lembrete_em,
                    c2.instalacao_avisada_para,
                    c2.instalacao_avisada_em,
                    c2.instalacao_lembrada_para,
                    c2.ciclos_encerrados,
                    c2.ciclo_anterior,
                    c2.chatwoot_status,
                    c2.chatwoot_agente,
                    c2.chatwoot_time,
                    c2.chatwoot_etiquetas,
                    c2.chatwoot_sync_em,
                    c2.etiqueta_futuro_em,
                    c2.etiqueta_futuro_para,
                    c2.quadro_encerrada_motivo,
                    c2.quadro_encerrada_em,
                    c2.quadro_encerrada_por,
                    c2.espera_ate,
                    c2.espera_motivo,
                    c2.espera_em,
                    c2.espera_por
                   FROM mari_conversas c2
                  WHERE c2.venda_id = v.id AND c2.canal = 'whatsapp'::text AND COALESCE(c2.chatwoot_conversation_id, ''::text) <> ''::text
                  ORDER BY c2.updated_at DESC NULLS LAST
                 LIMIT 1) c ON true
             LEFT JOIN config_planos pl ON pl.id = v.plano_id
             LEFT JOIN v_instalacao_confirmacao ic ON ic.venda_id = v.id
             CROSS JOIN cfg cfg_1
          WHERE cfg_1.ligado AND (v.status = ANY (ARRAY['saida'::text, '2_aguardando_instalacao'::text])) AND NOT COALESCE(c.nao_contatar, false) AND COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text AND COALESCE(( SELECT f.n
                   FROM feitas_hoje f
                  WHERE f.conversa_id = c.id), 0::bigint) < cfg_1.max_conv
        ), vbate AS (
         SELECT b.venda_id,
            b.status,
            b.cliente_nome,
            b.cidade,
            b.motivo_saida,
            b.interesse_futuro_em,
            b.comissao_prevista,
            b.valor_mensal,
            b.instalacao_agendada_para,
            b.instalacao_turno,
            b.agendamento_registrado_em,
            b.dfv_hp_livre,
            b.conferencia_motivo,
            b.plano_nome,
            b.conversa_id,
            b.chatwoot_conversation_id,
            b.telefone,
            b.primeiro_nome,
            b.nome_template,
            b.janela_fecha_em,
            b.chave_motivo,
            b.saida_em,
            b.confirmacao,
            r.codigo,
            r.pontos,
            r.ordem,
            x.volta_em
           FROM vbase b
             CROSS JOIN regra_v r
             CROSS JOIN LATERAL ( SELECT
                        CASE
                            WHEN r.codigo = 'O6'::text THEN
                            CASE
                                WHEN b.interesse_futuro_em IS NOT NULL THEN ((b.interesse_futuro_em::timestamp without time zone + '09:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text)
                                ELSE b.saida_em + (((r.p -> 'dias'::text) ->> b.chave_motivo)::numeric)::double precision * '1 day'::interval
                            END
                            ELSE NULL::timestamp with time zone
                        END AS volta_em) x
             CROSS JOIN cfg cfg_1
          WHERE
                CASE r.codigo
                    WHEN 'O6'::text THEN b.status = 'saida'::text AND (r.p -> 'dias'::text) ? b.chave_motivo AND NOT (COALESCE(b.motivo_saida, ''::text) IN ( SELECT jsonb_array_elements_text(COALESCE(r.p -> 'nunca'::text, '[]'::jsonb)) AS jsonb_array_elements_text)) AND (COALESCE(b.conferencia_motivo, ''::text) <> ALL (ARRAY['ja_cliente_nio'::text, 'suspeita_fraude'::text, 'ja_tem_pedido_nio'::text])) AND (b.dfv_hp_livre IS NULL OR b.dfv_hp_livre > 0) AND x.volta_em IS NOT NULL AND now() >= x.volta_em AND now() < (x.volta_em + COALESCE((r.p ->> 'max_dias_depois'::text)::numeric, 30::numeric)::double precision * '1 day'::interval) AND NOT (EXISTS ( SELECT 1
                       FROM oportunidades_log l
                      WHERE l.conversa_id = b.conversa_id AND l.codigo = 'O6'::text AND l.tipo = 'enviada'::text))
                    WHEN 'O7'::text THEN b.status = '2_aguardando_instalacao'::text AND (b.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date = (cfg_1.hoje + 1) AND (now() AT TIME ZONE 'America/Sao_Paulo'::text)::time without time zone >= COALESCE((r.p ->> 'hora'::text)::time without time zone, '20:00:00'::time without time zone) AND b.confirmacao IS NULL
                    ELSE false
                END
        ), vagg AS (
         SELECT vbate.conversa_id,
            (array_agg(vbate.codigo ORDER BY vbate.pontos DESC, vbate.ordem))[1] AS codigo,
            array_agg(vbate.codigo ORDER BY vbate.pontos DESC, vbate.ordem) AS regras,
            sum(vbate.pontos)::integer AS pontos
           FROM vbate
          GROUP BY vbate.conversa_id
        ), vlinha AS (
         SELECT a.conversa_id,
            a.codigo,
            a.regras,
            a.pontos,
            b.cliente_nome AS nome,
            b.primeiro_nome,
            b.nome_template,
            b.cidade,
                CASE
                    WHEN b.status = 'saida'::text THEN 'saida'::text
                    ELSE 'instalacao'::text
                END AS coluna,
                CASE
                    WHEN a.codigo = 'O6'::text THEN b.saida_em
                    ELSE COALESCE(b.agendamento_registrado_em, b.instalacao_agendada_para)
                END AS parado_desde,
            b.janela_fecha_em,
            b.chatwoot_conversation_id,
            NULL::bigint AS itens_validados,
            NULL::bigint AS itens_total,
            b.telefone,
            b.plano_nome AS plano,
            b.valor_mensal AS valor_mes,
                CASE
                    WHEN a.codigo <> 'O6'::text THEN 'ligar'::text
                    WHEN b.janela_fecha_em > now() THEN 'livre'::text
                    WHEN (EXISTS ( SELECT 1
                       FROM tpl)) THEN 'template'::text
                    ELSE 'ligar'::text
                END AS canal,
            ( SELECT t.nome
                   FROM tpl t) AS template,
                CASE a.codigo
                    WHEN 'O6'::text THEN ((('Saída há '::text || _oport_dur(now() - b.saida_em)) || ' · '::text) || lower(COALESCE(b.chave_motivo, 'sem motivo'::text))) || COALESCE((' · R$ '::text || _oport_reais(b.comissao_prevista)) || ' de comissão se voltar'::text, ''::text)
                    WHEN 'O7'::text THEN (('Instala amanhã ('::text ||
                    CASE
                        WHEN COALESCE(b.instalacao_turno,
                        CASE
                            WHEN EXTRACT(hour FROM (b.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)) >= 12::numeric THEN 'tarde'::text
                            ELSE 'manha'::text
                        END) = 'tarde'::text THEN '13–17h'::text
                        ELSE '8–12h'::text
                    END) || ') e não confirmou a visita · ligar hoje'::text) || COALESCE((' · R$ '::text || _oport_reais(b.comissao_prevista)) || ' de comissão em jogo'::text, ''::text)
                    ELSE NULL::text
                END AS motivo
           FROM vagg a
             JOIN LATERAL ( SELECT vb.venda_id,
                    vb.status,
                    vb.cliente_nome,
                    vb.cidade,
                    vb.motivo_saida,
                    vb.interesse_futuro_em,
                    vb.comissao_prevista,
                    vb.valor_mensal,
                    vb.instalacao_agendada_para,
                    vb.instalacao_turno,
                    vb.agendamento_registrado_em,
                    vb.dfv_hp_livre,
                    vb.conferencia_motivo,
                    vb.plano_nome,
                    vb.conversa_id,
                    vb.chatwoot_conversation_id,
                    vb.telefone,
                    vb.primeiro_nome,
                    vb.nome_template,
                    vb.janela_fecha_em,
                    vb.chave_motivo,
                    vb.saida_em,
                    vb.confirmacao,
                    vb.codigo,
                    vb.pontos,
                    vb.ordem,
                    vb.volta_em
                   FROM vbate vb
                  WHERE vb.conversa_id = a.conversa_id AND vb.codigo = a.codigo
                 LIMIT 1) b ON true
        ), todas AS (
         SELECT linha.conversa_id,
            linha.codigo,
            linha.regras,
            linha.pontos,
            linha.nome,
            linha.primeiro_nome,
            linha.nome_template,
            linha.cidade,
            linha.coluna,
            linha.parado_desde,
            linha.janela_fecha_em,
            linha.chatwoot_conversation_id,
            linha.itens_validados,
            linha.itens_total,
            linha.telefone,
            linha.plano,
            linha.valor_mes,
            linha.canal,
            linha.template,
            linha.motivo
           FROM linha
        UNION ALL
         SELECT vlinha.conversa_id,
            vlinha.codigo,
            vlinha.regras,
            vlinha.pontos,
            vlinha.nome,
            vlinha.primeiro_nome,
            vlinha.nome_template,
            vlinha.cidade,
            vlinha.coluna,
            vlinha.parado_desde,
            vlinha.janela_fecha_em,
            vlinha.chatwoot_conversation_id,
            vlinha.itens_validados,
            vlinha.itens_total,
            vlinha.telefone,
            vlinha.plano,
            vlinha.valor_mes,
            vlinha.canal,
            vlinha.template,
            vlinha.motivo
           FROM vlinha
        ), numerada AS (
         SELECT l.conversa_id,
            l.codigo,
            l.regras,
            l.pontos,
            l.nome,
            l.primeiro_nome,
            l.nome_template,
            l.cidade,
            l.coluna,
            l.parado_desde,
            l.janela_fecha_em,
            l.chatwoot_conversation_id,
            l.itens_validados,
            l.itens_total,
            l.telefone,
            l.plano,
            l.valor_mes,
            l.canal,
            l.template,
            l.motivo,
            row_number() OVER (ORDER BY l.pontos DESC, l.janela_fecha_em, l.parado_desde) AS n,
            row_number() OVER (PARTITION BY ((l.codigo IN ( SELECT jsonb_array_elements_text(cfg_n.fora) AS x))) ORDER BY l.pontos DESC, l.janela_fecha_em, l.parado_desde) AS nc
           FROM todas l
             CROSS JOIN cfg cfg_n
        )
 SELECT 'dharma'::text AS parceiro_id,
    n.conversa_id,
    n.codigo,
    n.regras,
    n.pontos,
    n.nome,
    n.cidade,
    n.coluna,
    n.motivo,
    n.plano,
    n.valor_mes,
    n.janela_fecha_em,
    n.canal,
    n.template,
    n.parado_desde,
    n.chatwoot_conversation_id,
        CASE n.canal
            WHEN 'livre'::text THEN _oport_texto(( SELECT x.texto
               FROM config_mari_textos x
              WHERE x.chave = ('op_'::text || n.codigo)), jsonb_build_object('nome', n.primeiro_nome, 'cidade', n.cidade, 'plano', n.plano, 'valor', _oport_reais(n.valor_mes), 'agente', COALESCE(( SELECT eu.nome
               FROM eu), 'o time'::text)))
            WHEN 'template'::text THEN mari_render_template(n.template, jsonb_build_array(n.nome_template, COALESCE(( SELECT eu.nome
               FROM eu), 'o time'::text)))
            ELSE NULL::text
        END AS texto_sugerido,
    n.n AS ordem,
    n.telefone
   FROM numerada n,
    cfg
  WHERE (n.codigo IN ( SELECT jsonb_array_elements_text(cfg.fora) AS x)) OR n.nc::numeric <= GREATEST(cfg.max_dia::numeric - COALESCE(( SELECT count(*)::numeric AS count
           FROM oportunidades_log lq
          WHERE (lq.tipo = ANY (ARRAY['enviada'::text, 'dispensada'::text])) AND (lq.criado_em AT TIME ZONE 'America/Sao_Paulo'::text)::date = cfg.hoje AND NOT (COALESCE(lq.codigo, ''::text) IN ( SELECT jsonb_array_elements_text(cfg.fora) AS x))), 0::numeric), 0::numeric);

CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           -- 0271 (passo 6, Live): prazo de 24 h úteis a contar da Saída e dono = quem deu a Saída. Vencido = "VENCIDO" no texto (a Live acende).
           case when public._horas_uteis(ev.em, now()) >= 24 then 'VENCIDO · ' else 'prazo: faltam ' || greatest(1, ceil(24 - public._horas_uteis(ev.em, now())))::int || ' h úteis · ' end
             || 'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || coalesce(' · Saída dada por ' || ev.quem, '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select e.criado_em as em, (select split_part(btrim(u.nome), ' ', 1) from public.usuarios u where u.id = e.criado_por) as quem
                            from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status' order by e.criado_em desc limit 1) ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
    union all
    -- (i2) 0196: biometria da Nio fora do ar (suspeita automática pelo GED360 ou marcada pelo time)
    select 'biometria_fora', q.id::text, null::uuid, null::uuid, 'Biometria da Nio', q.inicio, 1,
           format('%s desde %s%s · %s venda(s) esperando a biometria — peça à Nio a dispensa e marque "Nio dispensou" em cada ficha; quando voltar, marque "Voltou" (Operações › Biometria)',
                  case when q.confirmada_em is null then 'Biometria da Nio parece fora do ar (GED360 sem biometria nova há ' || q.horas_sem_envio || ' h no horário comercial · confirme no grupo)'
                       else 'Biometria da Nio FORA DO AR' end,
                  to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                  case when q.origem = 'manual' then ' (marcada por ' || coalesce((select u.nome from public.usuarios u where u.id = q.aberta_por), 'time') || ')' else '' end,
                  (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')))
      from public.biometria_quedas q
     where q.fim is null
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
    union all
    -- (l) 0202: o portal consultou outra rua (ou disse "sem viabilidade" com a fachada viável no DFV) — o time confere a rua
    select 'conferir_rua', c.id::text, c.id, c.venda_id, n.nome, c.rua_conferir_em,
           case when c.rua_conferir_em < now() - interval '4 hours' then 1 else 2 end,
           format('%s — cliente: %s, nº %s · portal: %s%s. Refaça na Cobertura escolhendo a rua do cliente e marque "Conferi"%s',
                  case c.rua_conferir ->> 'motivo' when 'rua_divergente' then 'O portal consultou OUTRA RUA'
                       else 'O portal disse sem viabilidade, mas a fachada está viável no DFV' end,
                  coalesce(nullif(c.rua_conferir ->> 'esperada', ''), c.endereco_cep ->> 'logradouro', '?'), coalesce(c.numero, '?'),
                  coalesce(nullif(split_part(c.rua_conferir ->> 'portal', ',', 1), ''), '?'),
                  coalesce(' · DFV: ' || nullif(c.rua_conferir ->> 'dfv', ''), ''),
                  case when c.rua_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.rua_conferir_em is not null
    union all
    -- (n) 0233: unidade a confirmar — o portal tem lista fechada de unidades e a do cliente não bate (ou ele disse "nenhuma
    -- dessas", ou o endereço não tem nenhuma cadastrada). Dono: backoffice. Prazo: 4 h.
    select 'conferir_unidade', c.id::text, c.id, c.venda_id, n.nome, c.unidade_conferir_em,
           case when c.unidade_conferir_em < now() - interval '4 hours' or c.unidade_conferir ->> 'motivo' <> 'escolher' then 1 else 2 end,
           format('%s · %s, nº %s%s',
                  case c.unidade_conferir ->> 'motivo'
                       when 'escolher' then format('Unidade a confirmar — viável no endereço; o cliente disse "%s" e o portal tem: %s. A Mari está perguntando qual é; se ele não escolher, confirme com ele. No pedido, escolha a unidade DELE (nunca outra)',
                                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), 'nada'), coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       when 'nenhuma' then format('Unidade fora do cadastro da Nio — o cliente disse que a unidade dele não é nenhuma de: %s. Peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                                  coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       else format('Endereço sem unidade cadastrada na Nio (complemento "%s") — peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), c.complemento, '?')) end,
                  coalesce(c.endereco_cep ->> 'logradouro', 'CEP ' || c.cep, '?'), coalesce(c.numero, '?'),
                  case when c.unidade_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.unidade_conferir_em is not null
    union all
    -- (m) 0210: o robô do GED360 está barrado (2+ leituras seguidas com erro) — sem ele ninguém fica sabendo da biometria
    select 'ged360_barrado', 'ged360', null::uuid, null::uuid, 'Robô do GED360', g.desde, 1,
           case when g.erro ilike '%simult%'
                then format('O robô do GED360 não lê desde %s: alguém entrou no GED360 com o login do robô ("logins simultâneos"). Saia do GED360 e use "⟳ Consultar no GED360" na ficha — sem o robô, biometria aprovada não avisa ninguém',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'HH24:MI'))
                else format('O robô do GED360 não lê desde %s (%s leituras com erro: %s) — biometria aprovada não avisa ninguém até voltar',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), g.n, left(g.erro, 120)) end
      from (select (select min(l.lida_em) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as desde,
                   (select count(*) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as n,
                   (select l.erro from public.ged360_leituras l order by l.lida_em desc limit 1) as erro,
                   (select l.ok from public.ged360_leituras l order by l.lida_em desc limit 1) as ultima_ok) g
     where g.ultima_ok = false and g.n >= 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;

commit;
