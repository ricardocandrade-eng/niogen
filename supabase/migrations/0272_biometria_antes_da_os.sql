-- NIOGEN | supabase/migrations/0272_biometria_antes_da_os.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 6 — achados do caso Geraldo (Ricardo, 17/11: "Mas não vamos voltar aquelas correções de conserta uma coisa e estraga outra?",
-- "se o GED diz LINK ENVIADO, porque a ficha me dá opção de marcar Biometria validada…?", "Pode ser 2h", "O que achar melhor").
--   (1) v_jornada_base (o próximo passo da Live): crédito aprovado com a biometria ainda não aprovada mandava "gravar a OS e a data"
--       (botão OS e agenda) — e a porta recusa a OS sem biometria (D11, 0256). Agora: sem link → "no portal, Continuar manda a biometria";
--       link enviado → esperando a biometria do cliente (vez do cliente; 24 h hoje, 72 h agora); com risco → conferir no portal.
--       Só o texto/botão/nível do passo mudam; colunas iguais. Regra geral nova R13 no portão: o botão que a Live sugere vale na porta.
--   (2) config_transicao: o robô do GED360 que vê a biometria pendente leva o lead de "rodar crédito" para "aguarda biometria"
--       (era anotado como divergência: a tabela previa "fica onde está"). Robôs da Nio continuam nunca recusados.
--   (3) Biometria marcada à mão (Validada / Com risco) só quando o GED360 não leu esta venda há 2 h (config_regras.biometria_manual_horas)
--       ou pelo admin — a biometria é fato da Nio (regra 20, item 4). "Nio dispensou" continua livre (é o sistema da Nio fora do ar).
--       Novo "exige" = ged_sem_leitura, conferido pela porta (_porta_conferir) e mostrado na tela (porta_botoes), com o status do GED360.
-- Regra 20: nenhum estado novo; (3) fortalece a fonte única; conferência: R13 + cenário X12.
begin;

-- ── (1) o próximo passo da Live ──
create or replace view public.v_jornada_base with (security_invoker = true) as
 SELECT j.tipo,
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
    j.precisa_acao OR x.furo OR x.prov_vencido OR x.conf_vencida AS precisa_acao,
        CASE
            WHEN x.furo THEN 'agora'::text
            WHEN (x.prov_vencido OR x.conf_vencida) AND j.nivel <> 'agora'::text THEN 'hoje'::text
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN ('Passado pela Mari sem dono há '::text ||
            CASE
                WHEN y.min < 60 THEN y.min || ' min'::text
                ELSE (y.min / 60) || ' h'::text
            END) || ' (horário de atendimento) · assumir'::text
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN ('Cliente confirmou há '::text || (z.conf_min / 60)) || ' h · dar o retorno prometido'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN ('Trocar nº provisório do pedido ('::text || y.pedido) || ') pelo nº real do portal'::text
            WHEN x.confirmou AND j.tipo = 'conversa'::text AND NOT j.precisa_acao THEN 'Cliente confirmou · aguardando você'::text
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN 'assumir'::text
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN 'responder'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN 'abrir'::text
            ELSE j.botao
        END AS botao,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN y.handoff_em
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN z.conf_desde
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN y.pedido_em
            WHEN x.confirmou AND j.tipo = 'conversa'::text AND NOT j.precisa_acao THEN z.conf_desde
            ELSE j.desde
        END AS desde,
    j.dono_tipo,
    j.dono_nome,
    j.pendencia,
    j.acao_id,
    j.status_venda,
    j.parceiro_id,
    y.min AS sem_dono_min,
    y.prov AS pedido_provisorio,
    x.confirmou AND NOT x.conf_vencida AS cliente_confirmou,
    z.conf_desde AS confirmou_em
   FROM ( WITH cfg AS (
                 SELECT COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::integer AS int4
                           FROM config_regras
                          WHERE config_regras.chave = 'prazo_docs_dias'::text), 15) AS d_docs,
                    (now() AT TIME ZONE 'America/Sao_Paulo'::text)::date AS hoje
                ), conv AS (
                 SELECT q.id,
                    q.venda_id,
                    q.nome,
                    q.cidade,
                    q.origem,
                    q.plano_nome,
                    q.coluna,
                    q.itens_total,
                    q.itens_validados,
                    q.chatwoot_conversation_id,
                    q.ultima_em,
                    q.janela_24h_fecha_em,
                    q.contatos_hoje,
                    q.contatos_mes,
                    c_1.chatwoot_agente,
                    c_1.chatwoot_time,
                    c_1.chatwoot_status,
                    COALESCE(c_1.humano_atribuido, false) AS humano_atribuido,
                    COALESCE(c_1.nao_contatar, false) AS nao_contatar,
                    c_1.status AS conv_status,
                    c_1.handoff_motivo,
                    c_1.handoff_em,
                    l.ult_lead,
                    l.ult_resp,
                    l.ult_humano,
                    s.minutos AS sem_resp_min,
                    s.desde AS sem_resp_desde,
                    al.tipo AS alerta,
                    al.em AS alerta_em,
                    bl.id AS bloq_id,
                    bl.motivo AS bloq_motivo,
                    bl.criada_em AS bloq_em
                   FROM v_mari_quadro q
                     JOIN mari_conversas c_1 ON c_1.id = q.id
                     CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE t.papel = 'lead'::text) AS ult_lead,
                            GREATEST(max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])), ( SELECT max(a.criada_em) AS max
                                   FROM chatwoot_acoes a
                                  WHERE a.conversa_id = q.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text]))), c_1.dispensada_em) AS ult_resp,
                            GREATEST(max(t.created_at) FILTER (WHERE t.papel = 'humano'::text), ( SELECT max(a.criada_em) AS max
                                   FROM chatwoot_acoes a
                                  WHERE a.conversa_id = q.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text])))) AS ult_humano
                           FROM mari_turnos t
                          WHERE t.conversa_id = q.id) l
                     LEFT JOIN v_mari_sem_resposta s ON s.id = q.id
                     LEFT JOIN LATERAL ( SELECT
                                CASE
                                    WHEN t.texto ~* '(migra[çc][ãa]o|migrar|operadora parceira|outra operadora|desligamento|(pedido|contrato|instala[çc][ãa]o) (foi )?cancelad|\m(tim|claro|vivo)\M ?(ou|,|/) ?\m(tim|claro|vivo)\M)'::text THEN 'golpe'::text
                                    WHEN t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)'::text THEN 'reclamacao'::text
                                    WHEN t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)'::text THEN 'desconto'::text
                                    ELSE 'nao_pedi'::text
                                END AS tipo,
                            t.created_at AS em
                           FROM mari_turnos t
                          WHERE t.conversa_id = q.id AND t.papel = 'lead'::text AND t.created_at > (now() - '7 days'::interval) AND t.created_at > COALESCE(l.ult_humano, '-infinity'::timestamp with time zone) AND (t.texto ~* '(migra[çc][ãa]o|migrar|operadora parceira|outra operadora|desligamento|(pedido|contrato|instala[çc][ãa]o) (foi )?cancelad|\m(tim|claro|vivo)\M ?(ou|,|/) ?\m(tim|claro|vivo)\M)'::text OR t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente|descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos|n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))'::text)
                          ORDER BY t.created_at DESC
                         LIMIT 1) al ON true
                     LEFT JOIN LATERAL ( SELECT a.id,
                            COALESCE(a.payload ->> 'rotulo'::text, a.momento) || COALESCE(' — '::text || a.erro, ''::text) AS motivo,
                            a.criada_em
                           FROM chatwoot_acoes a
                          WHERE a.conversa_id = q.id AND a.status = 'bloqueada'::text AND a.criada_em > (now() - '7 days'::interval)
                          ORDER BY a.criada_em
                         LIMIT 1) bl ON true
                  WHERE c_1.canal = 'whatsapp'::text AND COALESCE(c_1.telefone, ''::text) !~~ '5500000000%'::text
                ), sinal AS (
                 SELECT cv.id,
                    cv.venda_id,
                    cv.nome,
                    cv.cidade,
                    cv.origem,
                    cv.plano_nome,
                    cv.coluna,
                    cv.itens_total,
                    cv.itens_validados,
                    cv.chatwoot_conversation_id,
                    cv.ultima_em,
                    cv.janela_24h_fecha_em,
                    cv.contatos_hoje,
                    cv.contatos_mes,
                    cv.chatwoot_agente,
                    cv.chatwoot_time,
                    cv.chatwoot_status,
                    cv.humano_atribuido,
                    cv.nao_contatar,
                    cv.conv_status,
                    cv.handoff_motivo,
                    cv.handoff_em,
                    cv.ult_lead,
                    cv.ult_resp,
                    cv.ult_humano,
                    cv.sem_resp_min,
                    cv.sem_resp_desde,
                    cv.alerta,
                    cv.alerta_em,
                    cv.bloq_id,
                    cv.bloq_motivo,
                    cv.bloq_em,
                        CASE
                            WHEN cv.nao_contatar OR cv.coluna = 'encerrada'::text THEN NULL::text
                            WHEN cv.bloq_id IS NOT NULL THEN ('Mensagem não saiu ('::text || cv.bloq_motivo) || ') · mandar à mão'::text
                            WHEN cv.sem_resp_min IS NOT NULL THEN ('Cliente sem resposta há '::text || cv.sem_resp_min) || ' min (a Mari não respondeu)'::text
                            WHEN cv.alerta = 'golpe'::text THEN 'Cliente citou migração, cancelamento ou outra operadora · possível golpe · humano agora'::text
                            WHEN cv.alerta = 'reclamacao'::text THEN 'Reclamação ou já cliente Nio · humano agora'::text
                            WHEN cv.alerta = 'desconto'::text THEN 'Pediu desconto · humano responde (só a tabela da Nio)'::text
                            WHEN cv.alerta = 'nao_pedi'::text THEN '"Não pedi contato" · humano responde e encerra'::text
                            WHEN cv.conv_status = 'handoff_realizado'::text AND (COALESCE(cv.handoff_motivo, ''::text) <> ALL (ARRAY['dados_completos'::text, 'recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'sem_contato'::text])) AND COALESCE(cv.ult_humano, '-infinity'::timestamp with time zone) < COALESCE(cv.handoff_em, '-infinity'::timestamp with time zone) THEN 'Pediu um consultor · ninguém do time falou ainda'::text
                            WHEN (cv.conv_status = 'handoff_realizado'::text OR cv.humano_atribuido OR cv.chatwoot_agente IS NOT NULL) AND cv.ult_lead > COALESCE(cv.ult_resp, '-infinity'::timestamp with time zone) AND cv.ult_lead > (now() - '7 days'::interval) AND cliente_confirmou_desde(cv.id, cv.ult_resp) IS NULL THEN
                            CASE
                                WHEN cv.coluna = 'retomada'::text THEN 'Voltou a falar depois do time · responder'::text
                                WHEN cv.conv_status = 'handoff_realizado'::text AND (cv.handoff_motivo = ANY (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'ja_cliente_nio'::text, 'sem_contato'::text])) THEN ('Voltou a escrever depois de sair ('::text ||
                                CASE cv.handoff_motivo
                                    WHEN 'sem_cobertura'::text THEN 'sem cobertura'::text
                                    WHEN 'fora_de_area'::text THEN 'fora da área'::text
                                    WHEN 'recusa_compra'::text THEN 'recusou'::text
                                    WHEN 'ja_cliente_nio'::text THEN 'já é cliente Nio'::text
                                    ELSE 'sem contato'::text
                                END) || ') · responder'::text
                                ELSE 'Cliente escreveu · responder'::text
                            END
                            ELSE NULL::text
                        END AS alerta_txt,
                        CASE
                            WHEN cv.bloq_id IS NOT NULL THEN cv.bloq_em
                            WHEN cv.sem_resp_min IS NOT NULL THEN cv.sem_resp_desde
                            WHEN cv.alerta IS NOT NULL THEN cv.alerta_em
                            WHEN cv.conv_status = 'handoff_realizado'::text AND (cv.handoff_motivo = ANY (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'ja_cliente_nio'::text, 'sem_contato'::text])) THEN cv.ult_lead
                            WHEN cv.conv_status = 'handoff_realizado'::text AND COALESCE(cv.ult_humano, '-infinity'::timestamp with time zone) < COALESCE(cv.handoff_em, '-infinity'::timestamp with time zone) THEN cv.handoff_em
                            ELSE cv.ult_lead
                        END AS alerta_desde,
                        CASE
                            WHEN cv.nao_contatar THEN NULL::text
                            WHEN cv.chatwoot_agente IS NOT NULL THEN 'pessoa'::text
                            WHEN cv.humano_atribuido THEN 'pessoa'::text
                            WHEN cv.chatwoot_status = 'resolved'::text THEN NULL::text
                            WHEN cv.chatwoot_time IS NOT NULL THEN 'time'::text
                            ELSE 'mari'::text
                        END AS dono_tipo,
                        CASE
                            WHEN cv.nao_contatar THEN NULL::text
                            WHEN cv.chatwoot_agente IS NOT NULL THEN cv.chatwoot_agente
                            WHEN cv.humano_atribuido THEN 'time (assumida)'::text
                            WHEN cv.chatwoot_status = 'resolved'::text THEN NULL::text
                            WHEN cv.chatwoot_time IS NOT NULL THEN 'time '::text || cv.chatwoot_time
                            ELSE 'Mari'::text
                        END AS dono_nome
                   FROM conv cv
                ), vend AS (
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
                    v.observacoes,
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
                    v.nio_viab_endereco_portal,
                    v.nio_pedido_em,
                    v.parceiro_id,
                    v.conferencia_status,
                    v.conferencia_motivo,
                    v.conferencia_obs,
                    v.conferencia_em,
                    v.conferencia_por,
                    v.conferencia_prazo_ate,
                    v.nio_viab_por,
                    v.ponto_referencia,
                    v.nio_os,
                    v.nio_os_em,
                    jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS etapa,
                    p.nome_curto AS plano_curto,
                    u.nome AS vendedor_nome,
                    pe.id AS pend_id,
                    pe.revisar_em AS pend_revisar,
                    pe.aberta_em AS pend_desde,
                    pm.nome AS pend_nome,
                        CASE pe.quem_destrava
                            WHEN 'nio'::text THEN 'Nio'::text
                            WHEN 'rogerio'::text THEN 'Rogério'::text
                            WHEN 'cliente'::text THEN 'cliente'::text
                            ELSE 'nosso time'::text
                        END AS pend_quem,
                    s.id AS conv_id,
                    s.chatwoot_conversation_id AS cw_id,
                    s.alerta_txt,
                    s.alerta_desde,
                    s.bloq_id,
                    s.dono_tipo AS conv_dono_tipo,
                    s.dono_nome AS conv_dono_nome,
                    s.id IS NOT NULL AND COALESCE(s.chatwoot_conversation_id, ''::text) <> ''::text AND COALESCE(s.dono_tipo, 'mari'::text) = 'mari'::text AND NOT s.nao_contatar AS sem_dono,
                    COALESCE(v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval), false) AS viab_ok
                   FROM vendas v
                     LEFT JOIN config_planos p ON p.id = v.plano_id
                     LEFT JOIN usuarios u ON u.id = v.vendedor_id
                     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
                     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo
                     LEFT JOIN LATERAL ( SELECT x_1.id,
                            x_1.venda_id,
                            x_1.nome,
                            x_1.cidade,
                            x_1.origem,
                            x_1.plano_nome,
                            x_1.coluna,
                            x_1.itens_total,
                            x_1.itens_validados,
                            x_1.chatwoot_conversation_id,
                            x_1.ultima_em,
                            x_1.janela_24h_fecha_em,
                            x_1.contatos_hoje,
                            x_1.contatos_mes,
                            x_1.chatwoot_agente,
                            x_1.chatwoot_time,
                            x_1.chatwoot_status,
                            x_1.humano_atribuido,
                            x_1.nao_contatar,
                            x_1.conv_status,
                            x_1.handoff_motivo,
                            x_1.handoff_em,
                            x_1.ult_lead,
                            x_1.ult_resp,
                            x_1.ult_humano,
                            x_1.sem_resp_min,
                            x_1.sem_resp_desde,
                            x_1.alerta,
                            x_1.alerta_em,
                            x_1.bloq_id,
                            x_1.bloq_motivo,
                            x_1.bloq_em,
                            x_1.alerta_txt,
                            x_1.alerta_desde,
                            x_1.dono_tipo,
                            x_1.dono_nome
                           FROM sinal x_1
                          WHERE x_1.venda_id = v.id
                          ORDER BY x_1.ultima_em DESC NULLS LAST
                         LIMIT 1) s ON true
                ), vr AS (
                 SELECT vd.id,
                    vd.criado_em,
                    vd.criado_por,
                    vd.status,
                    vd.motivo_saida,
                    vd.interesse_futuro_em,
                    vd.origem,
                    vd.origem_ref,
                    vd.cliente_nome,
                    vd.cliente_cpf_cnpj,
                    vd.cliente_whatsapp,
                    vd.cliente_email,
                    vd.segmento,
                    vd.cep,
                    vd.logradouro,
                    vd.numero,
                    vd.complemento,
                    vd.bairro,
                    vd.cidade,
                    vd.uf,
                    vd.plano_id,
                    vd.forma_pagamento,
                    vd.vencimento_dia,
                    vd.comissao_prevista,
                    vd.comissao_paga,
                    vd.ciclo_pago,
                    vd.estorno_previsto,
                    vd.nio_pedido,
                    vd.nio_contrato,
                    vd.nio_situacao,
                    vd.nio_pendencia_cod,
                    vd.nio_pendencia_desc,
                    vd.biometria_status,
                    vd.biometria_em,
                    vd.vendido_em,
                    vd.agendamento_registrado_em,
                    vd.instalacao_agendada_para,
                    vd.instalado_em,
                    vd.ativado_em,
                    vd.docs_entregues_em,
                    vd.vendedor_id,
                    vd.trava_cobertura,
                    vd.trava_area,
                    vd.trava_sem_produto_ativo,
                    vd.trava_sem_cancelamento_30d,
                    vd.trava_cpf_valido,
                    vd.trava_contato_confirmado,
                    vd.nio_osab_em,
                    vd.nio_venda_valida,
                    vd.valor_mensal,
                    vd.comissao_nominal,
                    vd.comissao_adicionais,
                    vd.bonus_transicao_previsto,
                    vd.bonus_nmei_previsto,
                    vd.bonus_m10_potencial,
                    vd.primeiro_vencimento,
                    vd.dfv_viabilidade,
                    vd.dfv_consultado_em,
                    vd.dfv_consultado_por,
                    vd.dfv_faixa_credito,
                    vd.dfv_classificacao,
                    vd.dfv_hp_livre,
                    vd.dfv_hcs,
                    vd.dfv_dispensado,
                    vd.dfv_dispensa_motivo,
                    vd.dfv_origem,
                    vd.dfv_resultado,
                    vd.dfv_particao,
                    vd.observacoes,
                    vd.nio_viab_resultado,
                    vd.nio_viab_velocidade,
                    vd.nio_viab_interesse_id,
                    vd.nio_viab_endereco_id,
                    vd.nio_viab_em,
                    vd.nio_viab_origem,
                    vd.credito_resultado,
                    vd.credito_em,
                    vd.biometria_link,
                    vd.biometria_link_enviado_em,
                    vd.biometria_validada_em,
                    vd.instalacao_preferencia,
                    vd.instalacao_turno,
                    vd.nio_viab_endereco_portal,
                    vd.nio_pedido_em,
                    vd.parceiro_id,
                    vd.conferencia_status,
                    vd.conferencia_motivo,
                    vd.conferencia_obs,
                    vd.conferencia_em,
                    vd.conferencia_por,
                    vd.conferencia_prazo_ate,
                    vd.nio_viab_por,
                    vd.ponto_referencia,
                    vd.nio_os,
                    vd.nio_os_em,
                    vd.etapa,
                    vd.plano_curto,
                    vd.vendedor_nome,
                    vd.pend_id,
                    vd.pend_revisar,
                    vd.pend_desde,
                    vd.pend_nome,
                    vd.pend_quem,
                    vd.conv_id,
                    vd.cw_id,
                    vd.alerta_txt,
                    vd.alerta_desde,
                    vd.bloq_id,
                    vd.conv_dono_tipo,
                    vd.conv_dono_nome,
                    vd.sem_dono,
                    vd.viab_ok,
                    cfg.d_docs,
                        CASE
                            WHEN vd.status = 'saida'::text THEN jsonb_build_array('fora', COALESCE(vd.motivo_saida, 'Saída'::text) || COALESCE(' · volta '::text || to_char(vd.interesse_futuro_em::timestamp with time zone, 'DD/MM'::text), ''::text), NULL::unknown, NULL::unknown)
                            WHEN vd.alerta_txt IS NOT NULL THEN jsonb_build_array('agora', vd.alerta_txt,
                            CASE
                                WHEN vd.bloq_id IS NOT NULL THEN 'manual'::text
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'responder'::text
                            END, vd.alerta_desde)
                            WHEN vd.pend_id IS NOT NULL AND vd.pend_revisar <= cfg.hoje THEN jsonb_build_array('agora', (('⏰ Revisar hoje: '::text || COALESCE(vd.pend_nome, 'pendência'::text)) || ' · '::text) || vd.pend_quem, 'pendencia', vd.pend_desde)
                            WHEN vd.pend_id IS NOT NULL THEN jsonb_build_array('espera', (((('⏸ Aguardando '::text || vd.pend_quem) || ' · '::text) || COALESCE(vd.pend_nome, 'pendência'::text)) || ' · revisar '::text) || to_char(vd.pend_revisar::timestamp with time zone, 'DD/MM'::text), 'pendencia', vd.pend_desde)
                            WHEN vd.nio_venda_valida = false THEN jsonb_build_array('agora', 'A Nio marcou a venda como inválida · avisar o Ricardo', 'abrir', vd.nio_osab_em)
                            WHEN vd.etapa = 2 AND vd.origem = 'parceiro_pap'::text AND vd.conferencia_status = 'pendente'::text THEN jsonb_build_array(
                            CASE
                                WHEN vd.conferencia_prazo_ate < now() THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Conferir a venda do parceiro', 'conferencia', vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.origem = 'parceiro_pap'::text AND (vd.conferencia_status = ANY (ARRAY['devolvida'::text, 'reprovada'::text])) THEN jsonb_build_array('espera',
                            CASE vd.conferencia_status
                                WHEN 'devolvida'::text THEN 'Devolvida ao parceiro · esperando correção'::text
                                ELSE 'Reprovada na conferência'::text
                            END, 'abrir', vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.credito_resultado = 'negado'::text THEN jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'abrir', vd.credito_em)
                            WHEN vd.etapa = 2 AND NOT vd.viab_ok THEN jsonb_build_array('hoje',
                            CASE
                                WHEN vd.nio_viab_resultado = ANY (ARRAY['sem_viabilidade'::text, 'nao_encontrado'::text, 'posse'::text]) THEN ('Portal: '::text ||
                                CASE vd.nio_viab_resultado
                                    WHEN 'sem_viabilidade'::text THEN 'sem viabilidade'::text
                                    WHEN 'nao_encontrado'::text THEN 'endereço não encontrado'::text
                                    ELSE 'endereço já tem Nio'::text
                                END) || ' · conferir no DFV: endereço viável a até 200 m → formulário da Nio + pendência'::text
                                WHEN vd.nio_viab_resultado = 'viavel'::text THEN 'Viabilidade vencida (> 7 dias) · consultar de novo no portal'::text
                                ELSE 'Consultar a viabilidade no portal'::text
                            END,
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'viabilidade'::text
                            END, vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.credito_resultado = 'pendente'::text THEN jsonb_build_array('hoje', 'Crédito pendente na Nio · conferir no portal e gravar o resultado',
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'credito'::text
                            END, COALESCE(vd.credito_em, vd.nio_viab_em, vd.criado_em))
                            WHEN vd.etapa = 2 THEN jsonb_build_array('hoje', 'Viável · rodar o crédito no portal e gravar o resultado',
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'credito'::text
                            END, COALESCE(vd.nio_viab_em, vd.criado_em))
                            WHEN vd.etapa = 3 AND vd.credito_resultado = 'negado'::text THEN jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'biometria', vd.credito_em)
                            WHEN vd.etapa = 3 AND vd.biometria_status = 'com_risco'::text THEN jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', COALESCE(vd.biometria_em, vd.credito_em, vd.criado_em))
                            WHEN vd.etapa = 3 AND vd.biometria_status = 'pendente'::text THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em) < (now() - '72:00:00'::interval) THEN 'agora'::text
                                WHEN COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em) < (now() - '24:00:00'::interval) THEN 'hoje'::text
                                ELSE 'espera'::text
                            END, ('Crédito aprovado · esperando a biometria do cliente · link da Nio há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em))) || ' · a OS vem depois da biometria aprovada'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em))
                            WHEN vd.etapa = 3 AND COALESCE(vd.biometria_status, ''::text) <> ALL (ARRAY['validada'::text, 'dispensada'::text]) THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em) < (now() - '02:00:00'::interval) THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Crédito aprovado · no portal, Continuar manda a biometria ao cliente · a OS vem depois da biometria aprovada'::text, 'abrir', COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em))
                            WHEN vd.etapa = 3 THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em) < (now() - '02:00:00'::interval) THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Biometria aprovada · no portal: forma de pagamento, agenda e OS · gravar a OS e a data'::text, 'os', COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em))
                            WHEN vd.etapa = 4 AND vd.instalacao_agendada_para IS NULL THEN jsonb_build_array('agora', 'OS aberta sem data · gravar a agenda do portal · há '::text || _h_txt(COALESCE(vd.biometria_validada_em, vd.vendido_em)), 'agendar', COALESCE(vd.biometria_validada_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND (vd.nio_pendencia_cod IS NOT NULL OR vd.nio_pendencia_desc IS NOT NULL) THEN jsonb_build_array('hoje', "left"('Pendência Nio · '::text || concat_ws(' · '::text, vd.nio_pendencia_cod, vd.nio_pendencia_desc), 90) || ' · reagendar'::text, 'agendar', COALESCE(vd.nio_osab_em, vd.agendamento_registrado_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'com_risco'::text THEN jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', vd.biometria_em)
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND (EXISTS ( SELECT 1
                               FROM biometria_quedas q
                              WHERE q.fim IS NULL)) THEN jsonb_build_array('hoje', 'Biometria da Nio fora do ar · pedir à Nio a dispensa e marcar "Nio dispensou" na ficha'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND (EXISTS ( SELECT 1
                               FROM biometria_quedas q
                              WHERE q.fim IS NOT NULL AND q.fim > (now() - '48:00:00'::interval) AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < q.fim)) THEN jsonb_build_array('agora', ('A biometria da Nio voltou · cliente esperando há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · conferir o link (pedir novo se expirou) e falar com ele'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < (now() - '72:00:00'::interval) THEN jsonb_build_array('agora', ('Biometria pendente há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · ligar para o cliente'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < (now() - '24:00:00'::interval) THEN jsonb_build_array('hoje', ('Biometria pendente há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · a Mari lembrou; consultar e falar com o cliente'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text THEN jsonb_build_array('espera', 'Esperando a biometria do cliente · link da Nio há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em)), 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date < cfg.hoje THEN jsonb_build_array('agora', ('Visita de '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' não aconteceu: cartão não cadastrado · falar com o cliente e reagendar no portal'::text, 'cartao', vd.instalacao_agendada_para)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date = cfg.hoje THEN jsonb_build_array('agora', 'Visita HOJE e o cartão não foi cadastrado · ligar agora: sem o cadastro no link da Nio não há instalação'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND vd.biometria_validada_em < (now() - '48:00:00'::interval) THEN jsonb_build_array('agora', ('Cartão sem cadastro há '::text || _h_txt(vd.biometria_validada_em)) || ' · ligar: sem o cadastro no link da Nio não há instalação'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date <= (cfg.hoje + 1) THEN jsonb_build_array('hoje', ('Visita amanhã ('::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ') e o cartão não foi cadastrado · falar com o cliente: sem o cadastro a Nio não instala'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) THEN jsonb_build_array('espera', ('Biometria aprovada · esperando o cliente cadastrar o cartão no link da Nio (visita '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' depende disso; a Mari avisou)'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date < cfg.hoje THEN jsonb_build_array('hoje', ('Instalação era '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' e a Nio não deu baixa · conferir no portal'::text, 'agendar', vd.instalacao_agendada_para)
                            WHEN vd.etapa = 4 THEN jsonb_build_array('espera', (('Instalação '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) ||
                            CASE
                                WHEN COALESCE(vd.instalacao_turno, ''::text) = 'tarde'::text OR EXTRACT(hour FROM (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)) >= 12::numeric THEN ' à tarde'::text
                                ELSE ' de manhã'::text
                            END) || ' · com a Nio'::text, 'agendar', vd.agendamento_registrado_em)
                            WHEN vd.etapa = 5 AND vd.status = '3_instalado'::text AND vd.docs_entregues_em IS NULL AND vd.instalado_em IS NOT NULL THEN jsonb_build_array(
                            CASE
                                WHEN (vd.instalado_em + make_interval(days => cfg.d_docs)) < now() THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, ((('Documentos à Nio · prazo '::text || to_char(((vd.instalado_em + make_interval(days => cfg.d_docs)) AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' ('::text) || cfg.d_docs) || ' dias)'::text, 'docs', vd.instalado_em)
                            ELSE jsonb_build_array('ok', 'Instalada · conta na meta', 'abrir', COALESCE(vd.ativado_em, vd.instalado_em))
                        END AS r
                   FROM vend vd
                     CROSS JOIN cfg
                )
         SELECT 'venda'::text AS tipo,
            vr.id::text AS chave,
            vr.id AS venda_id,
            vr.conv_id AS conversa_id,
            vr.cw_id AS chatwoot_conversation_id,
            vr.cliente_nome AS nome,
            vr.cidade,
            COALESCE(vr.plano_curto, ''::text) AS plano,
            vr.origem,
            vr.etapa,
            jornada_nome(vr.etapa) AS etapa_nome,
            (vr.r ->> 0) = ANY (ARRAY['agora'::text, 'hoje'::text]) AS precisa_acao,
            vr.r ->> 0 AS nivel,
            vr.r ->> 1 AS o_que_fazer,
            vr.r ->> 2 AS botao,
            NULLIF(vr.r ->> 3, ''::text)::timestamp with time zone AS desde,
            COALESCE(vr.conv_dono_tipo,
                CASE
                    WHEN vr.vendedor_id IS NOT NULL THEN 'pessoa'::text
                    ELSE NULL::text
                END) AS dono_tipo,
            COALESCE(vr.conv_dono_nome, vr.vendedor_nome) AS dono_nome,
            vr.pend_id IS NOT NULL AS pendencia,
            vr.bloq_id AS acao_id,
            vr.status AS status_venda,
            'dharma'::text AS parceiro_id
           FROM vr
        UNION ALL
         SELECT 'conversa'::text AS tipo,
            'c:'::text || s.id::text AS chave,
            NULL::uuid AS venda_id,
            s.id AS conversa_id,
            s.chatwoot_conversation_id,
            COALESCE(NULLIF(initcap(split_part(btrim(COALESCE(s.nome, ''::text)), ' '::text, 1)), ''::text), 'Contato'::text) AS nome,
            s.cidade,
            COALESCE(s.plano_nome, ''::text) AS plano,
            s.origem,
            1 AS etapa,
            jornada_nome(1) AS etapa_nome,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN false
                    WHEN e.ativa AND e.espera_ate <= now() THEN true
                    ELSE s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text
                END AS precisa_acao,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN 'espera'::text
                    WHEN e.ativa AND e.espera_ate <= now() THEN 'hoje'::text
                    WHEN s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text THEN 'agora'::text
                    ELSE 'espera'::text
                END AS nivel,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN (('⏸ Aguardando · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' · até '::text) || to_char((e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)
                    WHEN e.ativa AND e.espera_ate <= now() THEN ((('Retomar · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' (combinado para '::text) || to_char((e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ')'::text
                    WHEN s.alerta_txt IS NOT NULL THEN s.alerta_txt
                    WHEN s.coluna = 'completo'::text THEN 'Dados completos e a venda não nasceu · ver o erro na tela Mari'::text
                    WHEN s.dono_tipo = ANY (ARRAY['pessoa'::text, 'time'::text]) THEN ('Com '::text || s.dono_nome) || ' · esperando o cliente'::text
                    ELSE ((('Mari atendendo · '::text || COALESCE(s.itens_validados, 0::bigint)) || '/'::text) || COALESCE(s.itens_total, 0::bigint)) || ' dados'::text
                END AS o_que_fazer,
                CASE
                    WHEN s.bloq_id IS NOT NULL THEN 'manual'::text
                    WHEN s.dono_tipo = 'mari'::text OR s.dono_tipo IS NULL THEN 'assumir'::text
                    ELSE 'responder'::text
                END AS botao,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL OR e.ativa AND e.espera_ate <= now() THEN e.espera_ate
                    WHEN s.alerta_txt IS NOT NULL THEN s.alerta_desde
                    WHEN s.coluna = 'completo'::text THEN s.handoff_em
                    ELSE s.ultima_em
                END AS desde,
            s.dono_tipo,
            s.dono_nome,
            COALESCE(e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL, false) AS pendencia,
            s.bloq_id AS acao_id,
            NULL::text AS status_venda,
            'dharma'::text AS parceiro_id
           FROM sinal s
             LEFT JOIN LATERAL ( SELECT me.espera_ate,
                    me.espera_motivo,
                    me.espera_ate IS NOT NULL AND COALESCE(s.ult_lead, '-infinity'::timestamp with time zone) <= me.espera_em AS ativa
                   FROM mari_conversas me
                  WHERE me.id = s.id) e ON true
          WHERE s.venda_id IS NULL AND s.coluna <> 'encerrada'::text) j
     LEFT JOIN mari_conversas c ON c.id = j.conversa_id
     LEFT JOIN vendas vv ON vv.id = j.venda_id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN c.handoff_em IS NOT NULL AND c.handoff_em > (now() - '30 days'::interval) AND (c.status = 'handoff_realizado'::text OR j.venda_id IS NOT NULL) AND (COALESCE(c.handoff_motivo, ''::text) <> ALL (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'sem_contato'::text, 'ja_cliente_nio'::text])) AND COALESCE(j.dono_tipo, 'mari'::text) <> 'pessoa'::text AND NOT COALESCE(c.nao_contatar, false) AND (j.nivel <> ALL (ARRAY['ok'::text, 'fora'::text])) AND NOT j.pendencia AND COALESCE(j.status_venda, ''::text) <> 'saida'::text THEN minutos_uteis(c.handoff_em, now(), c.cidade)
                    ELSE NULL::integer
                END AS min,
            c.handoff_em,
            COALESCE(vv.nio_pedido, ''::text) ~~* 'PROV-%'::text AS prov,
            vv.nio_pedido AS pedido,
            COALESCE(vv.nio_pedido_em, vv.criado_em) AS pedido_em) y
     CROSS JOIN LATERAL ( SELECT q.conf_desde,
                CASE
                    WHEN q.conf_desde IS NOT NULL THEN minutos_uteis(q.conf_desde, now(), c.cidade)
                    ELSE NULL::integer
                END AS conf_min
           FROM ( SELECT
                        CASE
                            WHEN c.id IS NOT NULL AND (c.status = 'handoff_realizado'::text OR COALESCE(c.humano_atribuido, false) OR c.chatwoot_agente IS NOT NULL) AND NOT COALESCE(c.nao_contatar, false) AND NOT j.pendencia AND (j.nivel <> ALL (ARRAY['ok'::text, 'fora'::text])) AND COALESCE(j.status_venda, ''::text) <> 'saida'::text THEN cliente_confirmou_desde(c.id, NULL::timestamp with time zone)
                            ELSE NULL::timestamp with time zone
                        END AS conf_desde) q) z
     CROSS JOIN LATERAL ( SELECT COALESCE(y.min, 0) > 30 AS furo,
            COALESCE(y.prov AND COALESCE(j.status_venda, ''::text) <> 'saida'::text AND y.pedido_em < (now() - '24:00:00'::interval), false) AS prov_vencido,
            z.conf_desde IS NOT NULL AS confirmou,
            COALESCE(z.conf_desde IS NOT NULL AND NOT j.precisa_acao AND z.conf_min >= COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::integer AS int4
                   FROM config_regras
                  WHERE config_regras.chave = 'confirmacao_retorno_min'::text), 240), false) AS conf_vencida) x;

-- (1b) R13 achou mais 4 (B2, B3, F3, X5): cliente em Saída ou Instalado que volta a escrever aparecia na Live com "Assumir", que a
--      porta recusa ("Em Saída: reabra antes de assumir"). O botão passa a ser "Responder" (time_respondeu vale em qualquer situação).
create or replace view public.v_jornada as   -- (sem security_invoker, como hoje)
 SELECT j.tipo,
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
    j.precisa_acao OR a.usa OR COALESCE(p.sobe, false) OR cx.n = 5 AS precisa_acao,
        CASE
            WHEN a.usa THEN a.nivel
            WHEN p.k IS NOT NULL THEN p.nivel
            WHEN cx.n = 5 THEN 'hoje'::text
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN a.usa THEN a.texto
            WHEN p.k IS NOT NULL THEN p.texto
            WHEN cx.n = 5 THEN 'Sem caixa: ninguém vai falar com o cliente · assuma, devolva à Mari com retorno ou dê Saída'::text
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN (CASE WHEN a.usa THEN a.botao ELSE j.botao END) = 'assumir'::text
                 AND (j.etapa = ANY (ARRAY[0, 5]) OR COALESCE(mc.funil_destino, 'em_andamento'::text) <> 'em_andamento'::text) THEN 'responder'::text
            WHEN a.usa THEN a.botao
            ELSE j.botao
        END AS botao,
        CASE
            WHEN a.usa THEN a.em
            WHEN p.k IS NOT NULL THEN p.desde
            WHEN cx.n = 5 THEN COALESCE(mc.ultima_msg_lead_at, j.desde)
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
    COALESCE(p.k = 'parado'::text, false) AS cliente_parado,
    cx.n AS caixa,
    _caixa_nome(cx.n) AS caixa_nome,
    mc.cadencia_proximo_em AS proximo_toque_em
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
     CROSS JOIN ( SELECT COALESCE((r.valor ->> 'parado_min'::text)::integer, 60) AS parado_min,
            COALESCE((r.valor ->> 'janela_fecha_h'::text)::integer, 23) AS janela_fecha_h,
            COALESCE((r.valor ->> 'sobe_h'::text)::integer, 3) AS sobe_h,
            COALESCE((r.valor ->> 'dias_max'::text)::integer, 15) AS dias_max
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
                    WHEN 'janela'::text THEN ((('Cliente parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) || ' · a janela de 24 h fecha às '::text) || to_char(((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text), 'HH24:MI'::text)) || ' · cutucar agora (texto livre)'::text
                    ELSE ('Vez do cliente · parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) ||
                    CASE
                        WHEN (mc.ultima_msg_lead_at + '24:00:00'::interval) > now() THEN ' · janela de 24 h até '::text || to_char(((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM HH24:MI'::text)
                        ELSE ' · janela fechada (só template)'::text
                    END
                END AS texto,
            mc.ultima_msg_mari_at AS desde
           FROM ( SELECT
                        CASE
                            WHEN mc.id IS NULL OR j.precisa_acao OR a.usa OR j.pendencia OR COALESCE(j.dono_tipo, 'mari'::text) <> 'mari'::text OR mc.status <> 'ativo'::text OR COALESCE(mc.nao_contatar, false) OR mc.ultima_msg_lead_at IS NULL OR mc.ultima_msg_mari_at IS NULL OR mc.ultima_msg_mari_at < mc.ultima_msg_lead_at OR mc.ultima_msg_lead_at < (now() - make_interval(days => cp.dias_max)) THEN NULL::text
                            WHEN COALESCE(mc.chatwoot_resolvida, false) AND COALESCE(mc.funil_destino, 'em_andamento'::text) <> 'em_andamento'::text THEN NULL::text
                            WHEN COALESCE(mc.chatwoot_resolvida, false) THEN 'resolvida'::text
                            WHEN mc.ultima_msg_mari_at > (now() - make_interval(mins => cp.parado_min)) THEN NULL::text
                            WHEN (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) > now() AND (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) <= (now() + make_interval(hours => cp.sobe_h)) THEN 'janela'::text
                            ELSE 'parado'::text
                        END AS k) q
          WHERE q.k IS NOT NULL) p ON true
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN j.precisa_acao OR a.usa OR COALESCE(p.sobe, false) THEN 2
                    WHEN j.etapa = 0 OR (COALESCE(mc.funil_destino, 'em_andamento'::text) <> ALL (ARRAY['em_andamento'::text, 'instalada'::text])) THEN 6
                    WHEN j.etapa = 5 OR mc.funil_destino = 'instalada'::text THEN 7
                    WHEN j.tipo = 'venda'::text THEN 4
                    WHEN (j.dono_tipo = ANY (ARRAY['pessoa'::text, 'time'::text])) OR j.pendencia OR COALESCE(j.cliente_confirmou, false) THEN 3
                    WHEN mc.status = 'ativo'::text AND mc.ultima_msg_lead_at > COALESCE(mc.ultima_msg_mari_at, '-infinity'::timestamp with time zone) THEN 1
                    WHEN mc.cadencia_proximo_em IS NOT NULL THEN 1
                    ELSE 5
                END AS n) cx;

-- ── (2) o robô do GED360 na tabela ──
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('nio:biometria:*', 'andamento', '{=,qualificado_biometria}', true, null, '0272: GED360 viu a biometria (link enviado/pendente): o lead passa a esperar a biometria', null)
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota, exige = excluded.exige;

-- ── (3) biometria à mão só sem leitura do GED360 ──
insert into public.config_regras (chave, valor, descricao) values
  ('biometria_manual_horas', '2'::jsonb, 'Biometria marcada à mão (Validada / Com risco) só depois de N horas sem leitura do GED360 desta venda, ou pelo admin (0272)')
on conflict do nothing;

alter table public.config_transicao drop constraint if exists config_transicao_exige_check;
alter table public.config_transicao add constraint config_transicao_exige_check
  check (exige is null or exige in ('admin', 'cliente_escreveu_depois', 'ged_sem_leitura'));

update public.config_transicao
   set exige = 'ged_sem_leitura',
       frase = 'O GED360 está lendo esta biometria: use ⟳ Consultar o GED360 agora. Marcar à mão só depois de 2 h sem leitura, ou o admin.'
 where evento = 'momento:biometria:validada' and de = 'andamento';
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('momento:biometria:risco', 'andamento', '{=}', true,
   'O GED360 está lendo esta biometria: use ⟳ Consultar o GED360 agora. Marcar à mão só depois de 2 h sem leitura, ou o admin.',
   '0272: biometria é fato da Nio', 'ged_sem_leitura')
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota, exige = excluded.exige;

insert into public.config_efeito (evento, efeito) values
  ('momento:biometria:risco', 'Marca a biometria com risco (o que o GED360 ou o portal mostram); a venda fica esperando a conferência.')
on conflict (evento) do update set efeito = excluded.efeito;

-- a leitura recente do GED360 desta venda (null = sem leitura nas últimas N horas)
create or replace function public._ged_fresco(p_venda uuid) returns text
language sql stable security definer set search_path = public as $$
  select b.resultado || ' · lido há ' || greatest(1, round(extract(epoch from now() - b.ultima_leitura) / 60))::int || ' min'
    from public.nio_biometria b
   where p_venda is not null and b.venda_id = p_venda
     and b.ultima_leitura > now() - make_interval(secs => 3600 * coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'biometria_manual_horas'), 2))
   order by b.ultima_leitura desc limit 1
$$;
revoke execute on function public._ged_fresco(uuid) from public, anon;
grant execute on function public._ged_fresco(uuid) to authenticated, service_role;

create or replace function public._porta_conferir(p_evento text, p_conversa uuid, p_venda uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare antes text; r record; ged text;
begin
  antes := public._porta_situacao(p_conversa, p_venda);
  select * into r from public.porta_prever(antes, p_evento);
  if r.aceito is false then
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação.');
  end if;
  if r.aceito and r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  if r.aceito and r.exige = 'ged_sem_leitura' and coalesce(public.meu_perfil(), '') <> 'admin' then   -- 0272
    ged := public._ged_fresco(coalesce(p_venda, (select c.venda_id from public.mari_conversas c where c.id = p_conversa)));
    if ged is not null then raise exception '%', r.frase || ' (GED360: ' || ged || ')'; end if;
  end if;
  -- sem regra (r.aceito is null): passa — a casca anota e a conferência mostra o buraco
end $$;
revoke execute on function public._porta_conferir(text, uuid, uuid) from public, anon, authenticated;

create or replace function public.porta_botoes(p_conversa uuid default null, p_venda uuid default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  s text; achou boolean := false; conv uuid := p_conversa; vend uuid := p_venda; sit jsonb; admin boolean; ged text; ged_lido boolean := false;
  ev text; r record; ok boolean; destino text; efeito text; nomes text[]; frase text;
  opt_ok boolean := null; out jsonb := '{}'::jsonb;
begin
  if p_conversa is null and p_venda is null then raise exception 'Informe a conversa ou a venda.'; end if;
  select ls.situacao, ls.conversa_id, ls.venda_id, true into s, conv, vend, achou from public.v_lead_situacao ls
   where (p_conversa is not null and ls.conversa_id = p_conversa) or (p_venda is not null and ls.venda_id = p_venda)
   limit 1;
  if not achou then return null; end if;   -- não existe ou o RLS não deixa ver
  conv := coalesce(conv, p_conversa);
  s := coalesce(s, '(sem situação)');
  admin := coalesce(public.meu_perfil(), '') = 'admin';
  select to_jsonb(x) into sit from (select codigo, numero, nome, vez, chatwoot, mari, lembretes from public.config_situacao where codigo = s) x;

  for ev in
    select distinct t.evento from public.config_transicao t
     where t.evento <> '*' and split_part(t.evento, ':', 1) not in ('nio', 'funil', 'prazo', 'mari_passou', 'conversa')
       and t.evento <> 'cliente_escreveu'
     order by 1
  loop
    select * into r from public.porta_prever(s, ev);
    ok := r.aceito is not false;
    frase := r.frase;
    if r.aceito and r.exige = 'admin' and not admin then
      ok := false;
    elsif r.aceito and r.exige = 'ged_sem_leitura' then   -- 0272: biometria à mão só sem leitura recente do GED360 (ou o admin)
      if not ged_lido then ged := public._ged_fresco(vend); ged_lido := true; end if;
      ok := admin or ged is null;
      if not ok then frase := r.frase || ' (GED360: ' || ged || ')'; end if;
    elsif r.aceito and r.exige = 'cliente_escreveu_depois' then
      if opt_ok is null then   -- mesma conta da porta (0265): o cliente escreveu depois de pedir para parar?
        opt_ok := not exists (
          select 1 from (select max(t.created_at) as em from public.mari_turnos t
                          where t.conversa_id = conv and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%') o
           where o.em is not null
             and not exists (select 1 from public.mari_turnos t where t.conversa_id = conv and t.papel = 'lead' and t.created_at > o.em));
      end if;
      ok := opt_ok;
    end if;
    if r.aceito is not true then frase := coalesce(frase, 'Esta ação não vale nesta situação.'); elsif ok then frase := null; end if;
    -- para onde vai, em nomes
    select array_agg(case p when '=' then 'fica em ' || coalesce(sit ->> 'nome', s)
                             when 'andamento' then 'volta à etapa onde parou'
                             when '*' then 'qualquer situação'
                             else coalesce((select cs.nome from public.config_situacao cs where cs.codigo = p), p) end order by n)
      into nomes from unnest(r.para) with ordinality u(p, n);
    -- o que acontece: o efeito do evento + o que a situação de destino manda (quando o destino é um só)
    efeito := public._efeito_de(ev);
    if r.aceito and array_length(r.para, 1) = 1 and r.para[1] not in ('=', 'andamento', '*') then
      select concat_ws(' · ', 'Depois: ' || cs.nome, 'vez: ' || cs.vez, 'Mari: ' || cs.mari)
        into destino from public.config_situacao cs where cs.codigo = r.para[1];
      efeito := concat_ws(' ', efeito, regexp_replace(destino, '\s*\([^)]*\)', '', 'g') || '.');
    end if;
    out := out || jsonb_build_object(ev, jsonb_build_object(
      'ok', ok, 'aceito', r.aceito, 'exige', r.exige, 'frase', frase, 'para', to_jsonb(nomes), 'efeito', efeito));
  end loop;

  return jsonb_build_object('situacao', coalesce(sit, jsonb_build_object('codigo', s)), 'admin', admin, 'eventos', out);
end $$;
revoke execute on function public.porta_botoes(uuid, uuid) from public, anon;
grant execute on function public.porta_botoes(uuid, uuid) to authenticated, service_role;

commit;
