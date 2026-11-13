-- NIOGEN | 0181_dono_do_lead.sql | 13/11/2026 — Claude Code (etapa 6, fatia 6c: dono do lead — decisão D7 do plano)
-- D7: "Quem assume vira dono. Lead da Mari sem dono fica com 'time' e prazo. Cada usuário com o seu vínculo de agente do Chatwoot."
--   1. usuarios.chatwoot_agente_nome: o nome do agente COMO O CHATWOOT ESCREVE (é o que o espelho da conversa guarda em
--      mari_conversas.chatwoot_agente). Junto com chatwoot_agente_id (0082), é o vínculo editável em Configurações › Equipe.
--      Dois logins do NIOGEN podem apontar para o mesmo agente (hoje: os dois logins do Ricardo).
--   2. v_leads.dono: quem ASSUMIU no Chatwoot vem antes do vendedor da venda (antes era o contrário, e divergia da Live).
--   3. v_leads.meu (coluna nova, no fim): o lead é de quem está logado — pelo vínculo do Chatwoot quando há alguém atribuído,
--      pelo id do vendedor quando não há. A tela deixa de comparar nomes.
-- O que NÃO muda aqui: o espelho do Chatwoot continua mandando o NOME do agente (mari_chatwoot_sync); guardar o id exigiria
-- mexer nos fluxos da Mari e fica para depois. v_leads recriada a partir da produção (pg_get_viewdef em 13/11/2026).

alter table public.usuarios add column if not exists chatwoot_agente_nome text;
comment on column public.usuarios.chatwoot_agente_nome is
  'Nome do agente como o Chatwoot escreve (o mesmo de mari_conversas.chatwoot_agente). Vínculo editado em Configurações › Equipe. 0181.';
update public.usuarios set chatwoot_agente_nome = nome where chatwoot_agente_id is not null and chatwoot_agente_nome is null;

create or replace view public.v_leads with (security_invoker = true) as
 WITH par AS (
         SELECT c_1.id AS conversa_id,
            v_1.id AS venda_id,
            row_number() OVER (PARTITION BY (COALESCE(v_1.id::text, c_1.id::text)) ORDER BY c_1.ultima_msg_lead_at DESC NULLS LAST, c_1.created_at DESC) AS rn
           FROM ( SELECT mari_conversas.id,
                    mari_conversas.telefone,
                    mari_conversas.nome_contato,
                    mari_conversas.nome_confiavel,
                    mari_conversas.canal,
                    mari_conversas.chatwoot_conversation_id,
                    mari_conversas.status,
                    mari_conversas.etapa,
                    mari_conversas.cep,
                    mari_conversas.numero,
                    mari_conversas.complemento,
                    mari_conversas.endereco_cep,
                    mari_conversas.cidade,
                    mari_conversas.uf,
                    mari_conversas.cluster,
                    mari_conversas.dentro_area,
                    mari_conversas.segmento,
                    mari_conversas.mei,
                    mari_conversas.elegibilidade,
                    mari_conversas.dfv_resultado,
                    mari_conversas.dfv_detalhe,
                    mari_conversas.plano_escolhido,
                    mari_conversas.forma_pagamento,
                    mari_conversas.visita_preferencia,
                    mari_conversas.dados,
                    mari_conversas.lgpd_enviada,
                    mari_conversas.upsell_oferecido,
                    mari_conversas.nao_contatar,
                    mari_conversas.ultima_msg_lead_at,
                    mari_conversas.followup_next_at,
                    mari_conversas.followup_count,
                    mari_conversas.agendamento_retorno,
                    mari_conversas.origem,
                    mari_conversas.handoff_motivo,
                    mari_conversas.handoff_em,
                    mari_conversas.venda_id,
                    mari_conversas.ultima_entrada_ts,
                    mari_conversas.processando_ate,
                    mari_conversas.created_at,
                    mari_conversas.updated_at,
                    mari_conversas.ultima_msg_mari_at,
                    mari_conversas.cadencia_passo,
                    mari_conversas.cadencia_passo_em,
                    mari_conversas.cadencia_proximo_em,
                    mari_conversas.cadencia_retorno_em,
                    mari_conversas.visita_confirmada_para,
                    mari_conversas.humano_atribuido,
                    mari_conversas.time_atribuido,
                    mari_conversas.chatwoot_resolvida,
                    mari_conversas.handoff_briefing,
                    mari_conversas.nio_viab_resultado,
                    mari_conversas.nio_viab_velocidade,
                    mari_conversas.nio_viab_interesse_id,
                    mari_conversas.nio_viab_em,
                    mari_conversas.instalacao_preferencia,
                    mari_conversas.nio_viab_endereco_portal,
                    mari_conversas.bio_lembrete_em,
                    mari_conversas.instalacao_avisada_para,
                    mari_conversas.instalacao_avisada_em,
                    mari_conversas.instalacao_lembrada_para,
                    mari_conversas.ciclos_encerrados,
                    mari_conversas.ciclo_anterior,
                    mari_conversas.chatwoot_status,
                    mari_conversas.chatwoot_agente,
                    mari_conversas.chatwoot_time,
                    mari_conversas.chatwoot_etiquetas,
                    mari_conversas.chatwoot_sync_em,
                    mari_conversas.etiqueta_futuro_em,
                    mari_conversas.etiqueta_futuro_para,
                    mari_conversas.quadro_encerrada_motivo,
                    mari_conversas.quadro_encerrada_em,
                    mari_conversas.quadro_encerrada_por,
                    mari_conversas.espera_ate,
                    mari_conversas.espera_motivo,
                    mari_conversas.espera_em,
                    mari_conversas.espera_por,
                    mari_conversas.cobertura_decisao,
                    mari_conversas.cobertura_detalhe,
                    mari_conversas.cobertura_em,
                    mari_conversas.viab_consultas,
                    mari_conversas.nio_pedido_aberto,
                    mari_conversas.nio_pedido_aberto_em,
                    mari_conversas.dup_consultas,
                    mari_conversas.credito_autorizado_em,
                    mari_conversas.credito_autorizacao_frase,
                    mari_conversas.credito_recusado_em,
                    mari_conversas.credito_resultado,
                    mari_conversas.credito_formas,
                    mari_conversas.credito_em,
                    mari_conversas.credito_consultas,
                    mari_conversas.dispensada_em,
                    mari_conversas.dispensada_por,
                    mari_conversas.funil_etapa,
                    mari_conversas.funil_destino,
                    mari_conversas.funil_detalhe,
                    mari_conversas.funil_destino_em,
                    mari_conversas.funil_evento,
                    mari_conversas.funil_alerta,
                    mari_conversas.funil_alerta_em,
                    mari_conversas.saida_motivo,
                    mari_conversas.saida_sub,
                    mari_conversas.saida_volta_em,
                    mari_conversas.saida_em
                   FROM mari_conversas
                  WHERE mari_conversas.canal = 'whatsapp'::text) c_1
             FULL JOIN vendas v_1 ON v_1.id = c_1.venda_id
        )
 SELECT COALESCE(p.venda_id::text, 'c:'::text || p.conversa_id::text) AS lead_id,
    p.conversa_id,
    p.venda_id,
    'dharma'::text AS parceiro_id,
    COALESCE(NULLIF(btrim(v.cliente_nome), ''::text), NULLIF(btrim(c.dados ->> 'nome'::text), ''::text), NULLIF(btrim(c.nome_contato), ''::text), 'Contato'::text) AS nome,
    COALESCE(c.telefone, v.cliente_whatsapp) AS telefone,
    COALESCE(NULLIF(btrim(v.cidade), ''::text), NULLIF(btrim(c.cidade), ''::text)) AS cidade,
    COALESCE(NULLIF(c.origem, ''::text), NULLIF(v.origem, ''::text)) AS origem,
    COALESCE(pl.nome_curto, pl.nome, NULLIF(c.plano_escolhido, ''::text)) AS plano,
    v.valor_mensal,
    v.comissao_prevista,
    e.etapa,
    ce.ordem AS etapa_ordem,
    ce.nome AS etapa_nome,
    s.status,
    cs.nome AS status_nome,
    cs.ajuda AS status_ajuda,
    d.destino,
        CASE
            WHEN d.destino <> 'em_andamento'::text THEN NULL::text
            WHEN s.vez = 'mari'::text AND (COALESCE(c.humano_atribuido, false) OR COALESCE(c.time_atribuido, false) OR c.status = 'handoff_realizado'::text OR c.chatwoot_agente IS NOT NULL) THEN 'time'::text
            ELSE s.vez
        END AS vez,
        CASE
            WHEN d.destino <> 'em_andamento'::text THEN NULL::timestamp with time zone
            WHEN s.status = 'aguardando_instalacao'::text THEN v.instalacao_agendada_para
            WHEN s.base_em IS NOT NULL AND cs.prazo_horas IS NOT NULL THEN s.base_em + make_interval(mins => (cs.prazo_horas * 60::numeric)::integer)
            ELSE NULL::timestamp with time zone
        END AS prazo_em,
    d.destino = 'em_andamento'::text AND s.status <> 'aguardando_instalacao'::text AND s.base_em IS NOT NULL AND cs.prazo_horas IS NOT NULL AND (s.base_em + make_interval(mins => (cs.prazo_horas * 60::numeric)::integer)) < now() AND esp.motivo IS NULL AS atrasado,
    d.destino = 'em_andamento'::text AND esp.motivo IS NOT NULL AS em_espera,
    esp.motivo AS espera_motivo,
    esp.quem AS espera_quem,
    esp.revisar_em AS espera_revisar_em,
        CASE
            WHEN d.destino = 'saida'::text THEN e.etapa
            ELSE NULL::text
        END AS etapa_parou,
    sm.saida_motivo,
    cm.nome AS saida_nome,
    cm.ajuda AS saida_ajuda,
        CASE
            WHEN d.destino = 'saida'::text THEN COALESCE(
            CASE
                WHEN v.status = 'saida'::text THEN COALESCE(v.saida_sub, NULLIF(btrim(v.motivo_saida), ''::text))
                ELSE NULL::text
            END, c.saida_sub, c.funil_detalhe)
            ELSE NULL::text
        END AS saida_sub,
        CASE
            WHEN d.destino = 'saida'::text THEN COALESCE(v.interesse_futuro_em, c.saida_volta_em)
            ELSE NULL::date
        END AS volta_em,
    COALESCE(c.chatwoot_agente, u.nome,
        CASE
            WHEN COALESCE(c.time_atribuido, false) OR COALESCE(c.humano_atribuido, false) THEN 'time'::text
            ELSE NULL::text
        END,
        CASE
            WHEN d.destino = 'em_andamento'::text AND c.id IS NOT NULL THEN 'Mari'::text
            ELSE NULL::text
        END) AS dono,
    v.vendedor_id,
    COALESCE(c.created_at, v.criado_em) AS criado_em,
    GREATEST(c.ultima_msg_lead_at, c.ultima_msg_mari_at, c.funil_destino_em, v.criado_em) AS ultima_em,
    c.funil_etapa AS funil_etapa_antiga,
    c.funil_destino AS funil_destino_antigo,
    v.status AS venda_status,
    v.cancelada_apos_instalar_em,
    v.cancelada_apos_instalar_motivo,
    NULLIF(btrim(v.nio_pedido), ''::text) IS NOT NULL OR NULLIF(btrim(v.nio_os), ''::text) IS NOT NULL AS tem_pedido_nio,
    c.ultima_msg_lead_at,
    CASE
        WHEN c.chatwoot_agente IS NOT NULL THEN c.chatwoot_agente = ( SELECT COALESCE(NULLIF(btrim(eu.chatwoot_agente_nome), ''::text), eu.nome)
               FROM usuarios eu
              WHERE eu.id = auth.uid())
        ELSE COALESCE(v.vendedor_id = auth.uid(), false)
    END AS meu
   FROM par p
     LEFT JOIN mari_conversas c ON c.id = p.conversa_id
     LEFT JOIN vendas v ON v.id = p.venda_id
     LEFT JOIN config_planos pl ON pl.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     CROSS JOIN LATERAL ( SELECT COALESCE(v.instalado_em IS NOT NULL OR (v.status = ANY (ARRAY['3_instalado'::text, '4_ativo_provisorio'::text, '5_comissao_firme'::text])), false) AS instalada,
            COALESCE(NULLIF(btrim(v.nio_os), ''::text) IS NOT NULL OR (v.status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text])), false) AS tem_os,
            COALESCE(v.credito_resultado = ANY (ARRAY['aprovado'::text, 'so_cartao'::text]), false) OR COALESCE(c.credito_resultado ~ '^(aprovado|cartao)'::text, false) AS credito_ok) f
     CROSS JOIN LATERAL ( SELECT
                CASE GREATEST(
                    CASE
                        WHEN f.instalada THEN 6
                        WHEN f.tem_os THEN 5
                        WHEN v.id IS NOT NULL AND c.id IS NULL THEN 4
                        ELSE 0
                    END,
                    CASE COALESCE(c.funil_etapa, 'nova'::text)
                        WHEN 'instalada'::text THEN 6
                        WHEN 'agendada'::text THEN 5
                        WHEN 'qualificada'::text THEN 4
                        WHEN 'pedido'::text THEN 4
                        WHEN 'biometria'::text THEN 4
                        WHEN 'viu_planos'::text THEN 3
                        WHEN 'cep'::text THEN 2
                        WHEN 'area_ok'::text THEN 2
                        WHEN 'viavel'::text THEN 2
                        ELSE 1
                    END)
                    WHEN 6 THEN 'instalada'::text
                    WHEN 5 THEN 'instalacao'::text
                    WHEN 4 THEN 'qualificado'::text
                    WHEN 3 THEN 'pre_qualificado'::text
                    WHEN 2 THEN 'viabilidade'::text
                    ELSE 'atendimento'::text
                END AS etapa) e
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN c.funil_destino = 'teste_duplicada'::text THEN 'teste_duplicada'::text
                    WHEN v.status = 'saida'::text AND v.saida_motivo = 'teste_duplicada'::text THEN 'teste_duplicada'::text
                    WHEN f.instalada THEN 'instalada'::text
                    WHEN c.id IS NOT NULL THEN
                    CASE COALESCE(c.funil_destino, 'em_andamento'::text)
                        WHEN 'em_andamento'::text THEN 'em_andamento'::text
                        WHEN 'instalada'::text THEN 'instalada'::text
                        ELSE 'saida'::text
                    END
                    WHEN v.status = 'saida'::text THEN 'saida'::text
                    ELSE 'em_andamento'::text
                END AS destino) d
     CROSS JOIN LATERAL ( SELECT x.status,
            x.base_em,
            k.vez
           FROM ( SELECT
                        CASE e.etapa
                            WHEN 'instalada'::text THEN 'instalada'::text
                            WHEN 'instalacao'::text THEN
                            CASE
                                WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN 'pendencia_nio'::text
                                WHEN v.instalacao_agendada_para IS NULL THEN 'agendar'::text
                                ELSE 'aguardando_instalacao'::text
                            END
                            WHEN 'qualificado'::text THEN
                            CASE
                                WHEN v.biometria_status = 'validada'::text THEN 'abrir_os'::text
                                WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN 'aguarda_biometria'::text
                                WHEN f.credito_ok THEN 'fazer_pedido'::text
                                ELSE 'rodar_credito'::text
                            END
                            WHEN 'pre_qualificado'::text THEN 'viu_planos'::text
                            WHEN 'viabilidade'::text THEN 'consultando_cep'::text
                            ELSE
                            CASE
                                WHEN COALESCE(c.funil_etapa, 'nova'::text) = 'nova'::text THEN 'nova'::text
                                ELSE 'respondeu'::text
                            END
                        END AS status,
                        CASE e.etapa
                            WHEN 'instalacao'::text THEN
                            CASE
                                WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN v.nio_osab_em
                                WHEN v.instalacao_agendada_para IS NULL THEN GREATEST(v.biometria_validada_em, v.vendido_em, v.nio_os_em)
                                ELSE NULL::timestamp with time zone
                            END
                            WHEN 'qualificado'::text THEN
                            CASE
                                WHEN v.biometria_status = 'validada'::text THEN v.biometria_validada_em
                                WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN COALESCE(v.biometria_link_enviado_em, v.credito_em)
                                WHEN f.credito_ok THEN COALESCE(v.credito_em, c.credito_em, c.handoff_em)
                                ELSE COALESCE(c.handoff_em, v.criado_em)
                            END
                            ELSE
                            CASE
                                WHEN c.status = 'handoff_realizado'::text THEN c.handoff_em
                                ELSE NULL::timestamp with time zone
                            END
                        END AS base_em) x
             LEFT JOIN config_lead k ON k.parceiro_id = 'dharma'::text AND k.tipo = 'status'::text AND k.codigo = x.status) s
     LEFT JOIN LATERAL ( SELECT pe.motivo,
            pe.quem_destrava AS quem,
            pe.revisar_em::timestamp with time zone AS revisar_em
           FROM venda_pendencias pe
          WHERE pe.venda_id = v.id AND pe.encerrada_em IS NULL
        UNION ALL
         SELECT COALESCE(c.espera_motivo, 'aguardando'::text) AS "coalesce",
            'cliente'::text AS text,
            c.espera_ate
          WHERE c.espera_ate IS NOT NULL AND c.espera_ate > now()
 LIMIT 1) esp ON true
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN d.destino = 'teste_duplicada'::text THEN 'teste_duplicada'::text
                    WHEN d.destino <> 'saida'::text THEN NULL::text
                    WHEN v.status = 'saida'::text AND v.saida_motivo IS NOT NULL THEN v.saida_motivo
                    WHEN c.saida_motivo IS NOT NULL THEN c.saida_motivo
                    WHEN v.status = 'saida'::text AND v.motivo_saida ~~* 'Nio:%'::text THEN
                    CASE
                        WHEN v.motivo_saida ~* '(indevida|errada|duplicad|j[aá] possui)'::text THEN 'venda_indevida_fraude'::text
                        WHEN v.motivo_saida ~* '(desist|concorr)'::text THEN 'recusou'::text
                        ELSE 'nio_nao_instalou'::text
                    END
                    WHEN v.status = 'saida'::text AND v.motivo_saida ~* 'fraude'::text THEN 'venda_indevida_fraude'::text
                    ELSE
                    CASE COALESCE(c.funil_destino, funil_destino_de_motivo(v.motivo_saida))
                        WHEN 'fora_area'::text THEN 'cidade_nao_atendida'::text
                        WHEN 'sem_cobertura'::text THEN 'fachada_nao_atendida'::text
                        WHEN 'recusou'::text THEN
                        CASE
                            WHEN COALESCE(c.nao_contatar, false) AND c.funil_detalhe = 'não contatar'::text THEN 'nao_contatar'::text
                            ELSE 'recusou'::text
                        END
                        WHEN 'teste_duplicada'::text THEN 'teste_duplicada'::text
                        ELSE COALESCE(c.funil_destino, funil_destino_de_motivo(v.motivo_saida))
                    END
                END AS saida_motivo) sm
     LEFT JOIN config_lead ce ON ce.parceiro_id = 'dharma'::text AND ce.tipo = 'etapa'::text AND ce.codigo = e.etapa
     LEFT JOIN config_lead cs ON cs.parceiro_id = 'dharma'::text AND cs.tipo = 'status'::text AND cs.codigo = s.status
     LEFT JOIN config_lead cm ON cm.parceiro_id = 'dharma'::text AND cm.tipo = 'saida'::text AND cm.codigo = sm.saida_motivo
  WHERE p.rn = 1;
