-- NIOGEN | supabase/migrations/0164_o6_lista_unica.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- Parte C do prompt docs/Prompt_fechar_4a_operacoes_131126_0145.md (Drive): a oportunidade O6 (venda em Saída que volta ao Live
-- depois de N dias — config_oportunidades.O6) passa a entender a lista única de saída.
-- O defeito: a lead_sair (0157) grava motivo_saida = "Recusou · preço" e guarda saida_motivo/saida_sub; a O6 casava a chave pelo
-- texto antigo ("Preço", "Desistiu", "Sem contato (cadência esgotada)"…). Saída feita pela ficha nova não voltava como 🔥.
-- O que muda: só a "chave do motivo" da venda na v_oportunidades, que agora sai de _oport_chave_motivo():
--   recusou·preço → Preço · recusou·concorrente → Concorrente · recusou·momento → Interesse futuro (com data) ·
--   recusou·desistiu → Desistiu · sem_resposta → Sem contato (cadência esgotada) · fachada_nao_atendida → Sem cobertura ·
--   cidade_nao_atendida → Fora da área · ja_cliente_nio, credito_negado, reprovado_biometria, fraude → nomes que não estão em
--   parametros.dias (nunca voltam). Saída antiga (saida_motivo nulo): o texto de sempre, como reserva.
-- A regra não muda: dias, nunca, fora_area e max_dias_depois seguem em config_oportunidades.O6; a data de volta, quando houver,
-- continua mandando (interesse_futuro_em às 9h). A view é a de produção (pg_get_viewdef em 13/11), mesmas colunas e ordem.
-- Ensaio em transação desfeita: oportunidades de hoje idênticas antes e depois; uma saída "Recusou · preço" sem data, há 16 dias,
-- não voltava e passa a voltar como O6; com data vencida, volta como O6.

create or replace function public._oport_chave_motivo(p_motivo_saida text, p_saida_motivo text, p_saida_sub text, p_volta date)
returns text language sql immutable set search_path = public as $f$
  select case
    -- lista única de saída (lead_sair, 0157): casa pelo código e pelo sub-motivo
    when p_saida_motivo = 'recusou' then case lower(coalesce(p_saida_sub, ''))
        when 'preço' then 'Preço' when 'concorrente' then 'Concorrente' when 'momento' then 'Interesse futuro (com data)'
        when 'desistiu' then 'Desistiu' else 'Recusou' end
    when p_saida_motivo = 'sem_resposta'          then 'Sem contato (cadência esgotada)'
    when p_saida_motivo = 'fachada_nao_atendida'  then 'Sem cobertura'
    when p_saida_motivo = 'cidade_nao_atendida'   then 'Fora da área'
    when p_saida_motivo = 'ja_cliente_nio'        then 'Já é cliente Nio'
    when p_saida_motivo = 'credito_negado'        then 'Crédito negado'
    when p_saida_motivo = 'reprovado_biometria'   then 'Reprovado na biometria'
    when p_saida_motivo = 'venda_indevida_fraude' then 'Fraude'
    when p_saida_motivo is not null               then p_saida_motivo
    -- saídas antigas (antes da lista única): o texto de sempre
    when p_volta is not null then 'Interesse futuro (com data)'
    else p_motivo_saida end;
$f$;

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
            mari_cadencia_nome(ROW(c.id, c.telefone, c.nome_contato, c.nome_confiavel, c.canal, c.chatwoot_conversation_id, c.status, c.etapa, c.cep, c.numero, c.complemento, c.endereco_cep, c.cidade, c.uf, c.cluster, c.dentro_area, c.segmento, c.mei, c.elegibilidade, c.dfv_resultado, c.dfv_detalhe, c.plano_escolhido, c.forma_pagamento, c.visita_preferencia, c.dados, c.lgpd_enviada, c.upsell_oferecido, c.nao_contatar, c.ultima_msg_lead_at, c.followup_next_at, c.followup_count, c.agendamento_retorno, c.origem, c.handoff_motivo, c.handoff_em, c.venda_id, c.ultima_entrada_ts, c.processando_ate, c.created_at, c.updated_at, c.ultima_msg_mari_at, c.cadencia_passo, c.cadencia_passo_em, c.cadencia_proximo_em, c.cadencia_retorno_em, c.visita_confirmada_para, c.humano_atribuido, c.time_atribuido, c.chatwoot_resolvida, c.handoff_briefing, c.nio_viab_resultado, c.nio_viab_velocidade, c.nio_viab_interesse_id, c.nio_viab_em, c.instalacao_preferencia, c.nio_viab_endereco_portal, c.bio_lembrete_em, c.instalacao_avisada_para, c.instalacao_avisada_em, c.instalacao_lembrada_para, c.ciclos_encerrados, c.ciclo_anterior, c.chatwoot_status, c.chatwoot_agente, c.chatwoot_time, c.chatwoot_etiquetas, c.chatwoot_sync_em, c.etiqueta_futuro_em, c.etiqueta_futuro_para, c.quadro_encerrada_motivo, c.quadro_encerrada_em, c.quadro_encerrada_por, c.espera_ate, c.espera_motivo, c.espera_em, c.espera_por, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)) AS nome_template,
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
