-- NIOGEN | supabase/migrations/0101_conversa_em_espera.sql | 10/11/2026 — Claude Code
-- Por quê (Ricardo, 10/11, print da Valdirene #36: "estou esperando meu menino… quando ele chega eu entro em contato"):
-- "O próximo passo não pode ser simplesmente 'Abrir a conversa e responder', porque agora eu tenho é que aguardar, deixar em
-- standby. Estamos aguardando um parente do cliente para tomar decisão e poderia ser qq outra coisa."
-- O quê: ESPERA na conversa sem venda (a venda já tem a pendência "Em espera", 0064).
--   · mari_conversas.espera_ate / espera_motivo / espera_em / espera_por.
--   · RPC backoffice_conversa_espera(conversa, ate, motivo) — ate nulo = Retomar agora. Nota no Chatwoot e conversa ADIADA até
--     o dia (snoozed_until); o dono continua o mesmo (a Mari segue calada).
--   · v_jornada (conversa): em espera = fora da "Sua vez" ("⏸ Aguardando · motivo · até DD/MM", pendencia = true → aparece em
--     Acompanhando); no dia = "Retomar · motivo" (hoje). Se o cliente escrever depois de marcar, a espera cai e vale a regra de
--     sempre ("Cliente escreveu · responder"). v_conversas: em espera não conta como "Esperando resposta".
--   Views recriadas da definição viva (colunas e ordem iguais). Contrato: nada sai para o cliente.

begin;

alter table public.mari_conversas
  add column if not exists espera_ate    timestamptz,
  add column if not exists espera_motivo text,
  add column if not exists espera_em     timestamptz,
  add column if not exists espera_por    uuid;

create or replace view public.v_jornada with (security_invoker = true) as
 WITH cfg AS (
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
            c.chatwoot_agente,
            c.chatwoot_time,
            c.chatwoot_status,
            COALESCE(c.humano_atribuido, false) AS humano_atribuido,
            COALESCE(c.nao_contatar, false) AS nao_contatar,
            c.status AS conv_status,
            c.handoff_motivo,
            c.handoff_em,
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
             JOIN mari_conversas c ON c.id = q.id
             CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE t.papel = 'lead'::text) AS ult_lead,
                    GREATEST(max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])), ( SELECT max(a.criada_em) AS max
                           FROM chatwoot_acoes a
                          WHERE a.conversa_id = q.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text])))) AS ult_resp,
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
          WHERE c.canal = 'whatsapp'::text AND COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text
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
                    WHEN (cv.conv_status = 'handoff_realizado'::text OR cv.humano_atribuido OR cv.chatwoot_agente IS NOT NULL) AND cv.ult_lead > COALESCE(cv.ult_resp, '-infinity'::timestamp with time zone) AND cv.ult_lead > (now() - '7 days'::interval) THEN
                    CASE
                        WHEN cv.coluna = 'retomada'::text THEN 'Voltou a falar depois do time · responder'::text
                        ELSE 'Cliente escreveu · responder'::text
                    END
                    ELSE NULL::text
                END AS alerta_txt,
                CASE
                    WHEN cv.bloq_id IS NOT NULL THEN cv.bloq_em
                    WHEN cv.sem_resp_min IS NOT NULL THEN cv.sem_resp_desde
                    WHEN cv.alerta IS NOT NULL THEN cv.alerta_em
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
            jornada_etapa(v.status, v.nio_pedido) AS etapa,
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
             LEFT JOIN LATERAL ( SELECT x.id,
                    x.venda_id,
                    x.nome,
                    x.cidade,
                    x.origem,
                    x.plano_nome,
                    x.coluna,
                    x.itens_total,
                    x.itens_validados,
                    x.chatwoot_conversation_id,
                    x.ultima_em,
                    x.janela_24h_fecha_em,
                    x.contatos_hoje,
                    x.contatos_mes,
                    x.chatwoot_agente,
                    x.chatwoot_time,
                    x.chatwoot_status,
                    x.humano_atribuido,
                    x.nao_contatar,
                    x.conv_status,
                    x.handoff_motivo,
                    x.handoff_em,
                    x.ult_lead,
                    x.ult_resp,
                    x.ult_humano,
                    x.sem_resp_min,
                    x.sem_resp_desde,
                    x.alerta,
                    x.alerta_em,
                    x.bloq_id,
                    x.bloq_motivo,
                    x.bloq_em,
                    x.alerta_txt,
                    x.alerta_desde,
                    x.dono_tipo,
                    x.dono_nome
                   FROM sinal x
                  WHERE x.venda_id = v.id
                  ORDER BY x.ultima_em DESC NULLS LAST
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
                    WHEN vd.etapa = 2 THEN jsonb_build_array('hoje', 'Viável · abrir o pedido no portal e gravar o nº',
                    CASE
                        WHEN vd.sem_dono THEN 'assumir'::text
                        ELSE 'pedido'::text
                    END, COALESCE(vd.nio_viab_em, vd.criado_em))
                    WHEN vd.etapa = 3 AND vd.biometria_status = 'validada'::text THEN jsonb_build_array('agora', 'Biometria validada · abrir a OS no portal (prazo 4 h) · há '::text || _h_txt(vd.biometria_validada_em), 'os', vd.biometria_validada_em)
                    WHEN vd.etapa = 3 AND vd.credito_resultado = 'negado'::text THEN jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'biometria', vd.credito_em)
                    WHEN vd.etapa = 3 AND vd.biometria_status = 'com_risco'::text THEN jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', vd.biometria_em)
                    WHEN vd.etapa = 3 AND COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em) < (now() - '72:00:00'::interval) THEN jsonb_build_array('agora', ('Link da biometria há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em))) || ' · ligar para o cliente'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em))
                    WHEN vd.etapa = 3 AND COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em) < (now() - '24:00:00'::interval) THEN jsonb_build_array('hoje', ('Link da biometria há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em))) || ' · lembrar o cliente pela conversa'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em))
                    WHEN vd.etapa = 3 THEN jsonb_build_array('espera', 'Esperando a biometria do cliente · link da Nio há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em)), 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_pedido_em))
                    WHEN vd.etapa = 4 AND vd.instalacao_agendada_para IS NULL THEN jsonb_build_array('agora', 'OS aberta · agendar a instalação (prazo 4 h) · há '::text || _h_txt(COALESCE(vd.biometria_validada_em, vd.vendido_em)), 'agendar', COALESCE(vd.biometria_validada_em, vd.vendido_em))
                    WHEN vd.etapa = 4 AND (vd.nio_pendencia_cod IS NOT NULL OR vd.nio_pendencia_desc IS NOT NULL) THEN jsonb_build_array('hoje', "left"('Pendência Nio · '::text || concat_ws(' · '::text, vd.nio_pendencia_cod, vd.nio_pendencia_desc), 90) || ' · reagendar'::text, 'agendar', COALESCE(vd.nio_osab_em, vd.agendamento_registrado_em))
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
            WHEN (e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL) THEN false
            WHEN (e.ativa AND e.espera_ate <= now()) THEN true
            ELSE s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text
        END AS precisa_acao,
        CASE
            WHEN (e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL) THEN 'espera'::text
            WHEN (e.ativa AND e.espera_ate <= now()) THEN 'hoje'::text
            WHEN s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text THEN 'agora'::text
            ELSE 'espera'::text
        END AS nivel,
        CASE
            WHEN (e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL) THEN ((('⏸ Aguardando · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' · até '::text) || to_char(e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text, 'DD/MM'::text))
            WHEN (e.ativa AND e.espera_ate <= now()) THEN ((('Retomar · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' (combinado para '::text) || to_char(e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text, 'DD/MM'::text)) || ')'::text
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
            WHEN (e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL) OR (e.ativa AND e.espera_ate <= now()) THEN e.espera_ate
            WHEN s.alerta_txt IS NOT NULL THEN s.alerta_desde
            WHEN s.coluna = 'completo'::text THEN s.handoff_em
            ELSE s.ultima_em
        END AS desde,
    s.dono_tipo,
    s.dono_nome,
    COALESCE((e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL), false) AS pendencia,
    s.bloq_id AS acao_id,
    NULL::text AS status_venda,
    'dharma'::text AS parceiro_id
   FROM sinal s
     LEFT JOIN LATERAL ( SELECT me.espera_ate, me.espera_motivo,
            me.espera_ate IS NOT NULL AND COALESCE(s.ult_lead, '-infinity'::timestamp with time zone) <= me.espera_em AS ativa
           FROM mari_conversas me
          WHERE me.id = s.id) e ON true
  WHERE s.venda_id IS NULL AND s.coluna <> 'encerrada'::text;

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
    l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone) AND l.ult_lead > (now() - '7 days'::interval) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) AND NOT (c.espera_ate IS NOT NULL AND l.ult_lead <= c.espera_em) AS cliente_esperando,
        CASE
            WHEN l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) THEN floor(EXTRACT(epoch FROM now() - l.ult_lead) / 60::numeric)::integer
            ELSE NULL::integer
        END AS esperando_min,
    l.ult_lead,
    l.ult_lead IS NOT NULL AND l.ult_lead > (now() - '23:00:00'::interval) AS janela_aberta,
        CASE
            WHEN v.id IS NOT NULL THEN jornada_etapa(v.status, v.nio_pedido)
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

create or replace function public.backoffice_conversa_espera(p_conversa uuid, p_ate date, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c       public.mari_conversas;
  g       uuid := gen_random_uuid();
  quem    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  v_ate   timestamptz;
  v_mot   text := nullif(left(btrim(coalesce(p_motivo, '')), 80), '');
  tem_cw  boolean;
  feito   text[] := '{}';
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Esta conversa já tem venda: use a Pendência (⏸) da venda.'; end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');
  tem_cw := coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%';

  if p_ate is null then   -- Retomar agora
    if c.espera_ate is null then return jsonb_build_object('ok', true, 'feito', '[]'::jsonb, 'resumo', 'A conversa não estava em espera.'); end if;
    update public.mari_conversas set espera_ate = null, espera_motivo = null, espera_em = null, espera_por = null where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[espera encerrada no NIOGEN por ' || quem || ']', false);
    feito := feito || 'de volta na Minha vez'::text;
    if tem_cw then
      perform public._bo_enfileirar(g, 1, 'espera', null, c, 'nota', jsonb_build_object('content', '▶ Espera encerrada por ' || quem || ' em ' || agora_t || '.'));
      perform public._bo_enfileirar(g, 2, 'espera', null, c, 'resolver', jsonb_build_object('status', 'open'));
      feito := feito || 'nota'::text || 'conversa reaberta'::text;
    end if;
    return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ espera encerrada: a conversa volta para a Minha vez');
  end if;

  if p_ate <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Escolha uma data a partir de amanhã.'; end if;
  if p_ate > (now() at time zone 'America/Sao_Paulo')::date + 60 then raise exception 'No máximo 60 dias.'; end if;
  v_ate := (p_ate::text || ' 09:00')::timestamp at time zone 'America/Sao_Paulo';
  update public.mari_conversas
     set espera_ate = v_ate, espera_motivo = coalesce(v_mot, 'aguardando o cliente'), espera_em = now(), espera_por = auth.uid()
   where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[em espera até ' || to_char(p_ate, 'DD/MM') || ' — ' || coalesce(v_mot, 'aguardando o cliente') || ' — marcado no NIOGEN por ' || quem || ']', false);
  feito := feito || ('fora da Minha vez até ' || to_char(p_ate, 'DD/MM') || ' às 9h')::text;
  if tem_cw then
    perform public._bo_enfileirar(g, 1, 'espera', null, c, 'nota', jsonb_build_object('content',
      '⏸ Em espera até ' || to_char(p_ate, 'DD/MM') || ' — ' || coalesce(v_mot, 'aguardando o cliente') || ' (' || quem || ', ' || agora_t
      || '). Volta para a Minha vez no dia, ou antes se o cliente escrever.'));
    perform public._bo_enfileirar(g, 2, 'espera', null, c, 'resolver',
      jsonb_build_object('status', 'snoozed', 'snoozed_until', extract(epoch from v_ate)::bigint));
    feito := feito || 'nota'::text || ('adiada no Chatwoot até ' || to_char(p_ate, 'DD/MM'))::text;
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito),
    'resumo', '✓ em espera até ' || to_char(p_ate, 'DD/MM') || ' — volta antes se o cliente escrever');
end;
$$;
revoke all on function public.backoffice_conversa_espera(uuid, date, text) from public, anon;
grant execute on function public.backoffice_conversa_espera(uuid, date, text) to authenticated;

commit;
