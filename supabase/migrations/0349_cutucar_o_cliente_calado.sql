-- NIOGEN | supabase/migrations/0349_cutucar_o_cliente_calado.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Caso L-233 (Maria Aparecida, 21/11): o time respondeu, a vez passou para a cliente e a linha desceu para o Radar › Acompanhando,
-- com o prazo gravado de antes da resposta (o do handoff, já vencido). Debate da Live com o Ricardo (21/11 ~22h), 4 decisões:
--   1. "3 horas": a cutucada vence 3 h depois da resposta do time (config_regras.cutucar_horas).
--   2. "Sobe para Sua fila": vencida e o cliente calado → a vez volta ao time (situação time_agora) e a linha entra no Para fazer,
--      com o texto "Cutucar o cliente" — conta no "faltam".
--   3. "Antecipa para dentro da janela": só no horário do time (config_regras.time_horario). Caiu fora → a próxima abertura, se
--      for antes de a janela de 24 h fechar; se não, 15 min antes do fim do turno em que o time respondeu; se nem isso (o time
--      respondeu fora do horário e a janela fecha antes da próxima abertura), não há cutucada: segue a regra de hoje (0322: a
--      janela fecha e a conversa volta para a Mari).
--   4. "Todo lead sem venda": vale para toda conversa sem venda, com o time dono, em que o time falou por último. Venda gravada
--      segue com os avisos da venda.
-- Uma cutucada por resposta do cliente: o time escreveu depois do vencimento → volta a "esperando o cliente" e o prazo passa a
-- ser o fechamento da janela (quando a 0322 devolve à Mari). O cliente escreveu → time_agora, como sempre.
-- O que muda:
--   (1) _cutucar_em(base, janela) e _cutucada(conversa): quando a cutucada vence, se já foi feita e o prazo de agora.
--   (2) v_leads: vez = 'time' quando a cutucada venceu (antes: 'cliente' sempre que o time falou por último); prazo_em de quem
--       espera o cliente = o vencimento da cutucada (ou o fechamento da janela) — antes era o prazo do status (o do handoff).
--       Recriada da versão no ar (pg_get_viewdef de 21/11 ~22h), só com esses dois trechos.
--   (3) _lead_estado_tick: a troca time_esperando → time_agora pelo relógio é anotada como prazo:cutucar (antes prazo:tempo).
--   (4) config_transicao: prazo:cutucar @ time_esperando → time_agora.
--   (5) live_situacoes: na time_agora com a cutucada vencida, o "o que fazer" diz "Cutucar o cliente · … · janela fecha …".
--       A tela (fila.html) não muda: a linha entra pela vez gravada, como qualquer time_agora (0342).
-- Regra 20: (1) toda conversa com o time ganha prazo de verdade (cutucada ou janela); (2) nenhum estado novo — a espera do
--   cliente ganha prazo que vira alerta (a linha sobe); (3) a situação muda pelo relógio da porta (_lead_estado_tick), com evento
--   prazo:cutucar e linha na config_transicao; nenhuma tela grava; (4) fonte: mari_turnos (quem falou e quando);
--   (5) conferência: nada novo — a linha que sobe para a Sua fila é a própria cobrança.
-- Desempenho: _cutucada só roda para conversa sem venda em que o time falou por último (índice mari_turnos(conversa_id, created_at)).
-- Cenário X75.
begin;

insert into public.config_regras (chave, valor, descricao) values
  ('cutucar_horas', '3'::jsonb, '0349: horas depois da resposta do time para cutucar o cliente calado (no horário do time, dentro da janela de 24 h)')
on conflict (chave) do nothing;

-- (1a) quando vence a cutucada de uma resposta do time dada em p_base, com a janela de 24 h fechando em p_janela
create or replace function public._cutucar_em(p_base timestamptz, p_janela timestamptz)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  h     jsonb := public._bo_cfg('time_horario', '{"1": [9, 21], "2": [9, 21], "3": [9, 21], "4": [9, 21], "5": [9, 21], "6": [10, 16]}'::jsonb);
  n     numeric := coalesce(nullif(public._bo_cfg('cutucar_horas', '3'::jsonb) #>> '{}', '')::numeric, 3);
  alvo  timestamptz;
  d     date;
  fx    jsonb;
  ini   timestamptz;
  fim   timestamptz;
  i     int;
  m     timestamptz;
begin
  if p_base is null or p_janela is null then return null; end if;
  alvo := p_base + make_interval(mins => (n * 60)::int);
  -- 1. o alvo cai no horário do time e antes de a janela fechar
  d := (alvo at time zone 'America/Sao_Paulo')::date;
  fx := h -> extract(isodow from d)::int::text;
  if fx is not null then
    ini := (d + make_time((fx ->> 0)::int, 0, 0)) at time zone 'America/Sao_Paulo';
    fim := (d + make_time((fx ->> 1)::int, 0, 0)) at time zone 'America/Sao_Paulo';
    if alvo >= ini and alvo < fim and alvo < p_janela then return alvo; end if;
  end if;
  -- 2. a próxima abertura do time depois do alvo, se for antes de a janela fechar (com 30 min de folga)
  for i in 0..7 loop
    d := (alvo at time zone 'America/Sao_Paulo')::date + i;
    fx := h -> extract(isodow from d)::int::text;
    continue when fx is null;
    ini := (d + make_time((fx ->> 0)::int, 0, 0)) at time zone 'America/Sao_Paulo';
    if ini > alvo then
      if ini < p_janela - interval '30 minutes' then return ini; end if;
      exit;
    end if;
  end loop;
  -- 3. antecipa: 15 min antes do fim do turno em que o time respondeu (e antes da janela), se der ao menos 30 min depois
  d := (p_base at time zone 'America/Sao_Paulo')::date;
  fx := h -> extract(isodow from d)::int::text;
  if fx is not null then
    ini := (d + make_time((fx ->> 0)::int, 0, 0)) at time zone 'America/Sao_Paulo';
    fim := (d + make_time((fx ->> 1)::int, 0, 0)) at time zone 'America/Sao_Paulo';
    if p_base >= ini and p_base < fim then
      m := least(alvo, p_janela, fim) - interval '15 minutes';
      if m >= p_base + interval '30 minutes' then return m; end if;
    end if;
  end if;
  -- 4. sem cutucada: a janela fecha e a 0322 devolve à Mari
  return null;
end $$;
revoke all on function public._cutucar_em(timestamptz, timestamptz) from public, anon;
grant execute on function public._cutucar_em(timestamptz, timestamptz) to authenticated, service_role;

-- (1b) a cutucada da conversa: null quando o time não falou por último
create or replace function public._cutucada(p_conversa uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ult   text;
  v_lead  timestamptz;
  v_base  timestamptz;
  v_hum   timestamptz;
  v_jan   timestamptz;
  v_vence timestamptz;
  v_feita boolean;
begin
  if p_conversa is null then return null; end if;
  select t.papel into v_ult from public.mari_turnos t
   where t.conversa_id = p_conversa and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
  if v_ult is distinct from 'humano' then return null; end if;
  select max(t.created_at) into v_lead from public.mari_turnos t where t.conversa_id = p_conversa and t.papel = 'lead';
  if v_lead is null then select m.created_at into v_lead from public.mari_conversas m where m.id = p_conversa; end if;
  select min(t.created_at), max(t.created_at) into v_base, v_hum from public.mari_turnos t
   where t.conversa_id = p_conversa and t.papel = 'humano' and t.created_at > v_lead;
  if v_base is null then return null; end if;
  v_jan := v_lead + interval '24 hours';
  v_vence := public._cutucar_em(v_base, v_jan);
  v_feita := v_vence is null or v_hum >= v_vence;   -- o time já escreveu depois do vencimento (ou não há cutucada)
  return jsonb_build_object(
    'resposta_em', v_base, 'vence', v_vence, 'janela', v_jan, 'feita', v_feita,
    'agora', not v_feita and now() >= v_vence and now() < v_jan,
    'prazo', case when not v_feita and now() < v_jan then v_vence else v_jan end);
end $$;
revoke all on function public._cutucada(uuid) from public, anon;
grant execute on function public._cutucada(uuid) to authenticated, service_role;

-- (2) v_leads
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
            WHEN s.vez = 'mari'::text AND (COALESCE(c.humano_atribuido, false) OR COALESCE(c.time_atribuido, false) OR c.status = 'handoff_realizado'::text OR c.chatwoot_agente IS NOT NULL) THEN
            CASE
                WHEN (( SELECT t.papel
                   FROM mari_turnos t
                  WHERE t.conversa_id = c.id AND (t.papel = ANY (ARRAY['lead'::text, 'mari'::text, 'humano'::text]))
                  ORDER BY t.created_at DESC
                 LIMIT 1)) = 'humano'::text THEN CASE WHEN v.id IS NULL AND COALESCE((_cutucada(c.id) ->> 'agora')::boolean, false) THEN 'time'::text ELSE 'cliente'::text END
                ELSE 'time'::text
            END
            WHEN s.vez = 'time'::text AND s.status = 'pediu_humano'::text AND (COALESCE(c.humano_atribuido, false) OR COALESCE(c.time_atribuido, false) OR c.status = 'handoff_realizado'::text OR c.chatwoot_agente IS NOT NULL) AND (( SELECT t.papel
               FROM mari_turnos t
              WHERE t.conversa_id = c.id AND (t.papel = ANY (ARRAY['lead'::text, 'mari'::text, 'humano'::text]))
              ORDER BY t.created_at DESC
             LIMIT 1)) = 'humano'::text THEN CASE WHEN v.id IS NULL AND COALESCE((_cutucada(c.id) ->> 'agora')::boolean, false) THEN 'time'::text ELSE 'cliente'::text END
            ELSE s.vez
        END AS vez,
        CASE
            WHEN d.destino <> 'em_andamento'::text THEN NULL::timestamp with time zone
            WHEN v.id IS NULL AND (s.vez = 'mari'::text OR (s.vez = 'time'::text AND s.status = 'pediu_humano'::text)) AND (COALESCE(c.humano_atribuido, false) OR COALESCE(c.time_atribuido, false) OR c.status = 'handoff_realizado'::text OR c.chatwoot_agente IS NOT NULL) AND _cutucada(c.id) IS NOT NULL THEN (_cutucada(c.id) ->> 'prazo')::timestamp with time zone
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
            WHEN c.chatwoot_agente IS NOT NULL THEN c.chatwoot_agente = (( SELECT COALESCE(NULLIF(btrim(eu.chatwoot_agente_nome), ''::text), eu.nome) AS "coalesce"
               FROM usuarios eu
              WHERE eu.id = auth.uid()))
            ELSE COALESCE(v.vendedor_id = auth.uid(), false)
        END AS meu
   FROM par p
     LEFT JOIN mari_conversas c ON c.id = p.conversa_id
     LEFT JOIN vendas v ON v.id = p.venda_id
     LEFT JOIN config_planos pl ON pl.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     CROSS JOIN LATERAL ( SELECT COALESCE(v.instalado_em IS NOT NULL OR (v.status = ANY (ARRAY['3_instalado'::text, '4_ativo_provisorio'::text, '5_comissao_firme'::text])), false) AS instalada,
            COALESCE(NULLIF(btrim(v.nio_os), ''::text) IS NOT NULL OR (v.status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text])), false) AS tem_os,
            COALESCE(v.credito_resultado = ANY (ARRAY['aprovado'::text, 'so_cartao'::text]), false) OR COALESCE(c.credito_resultado ~ '^(aprovado|cartao)'::text, false) AS credito_ok,
            COALESCE(c.cobertura_decisao = 'elegivel_200m'::text, false) AND COALESCE(c.nio_viab_resultado, ''::text) <> 'viavel'::text AND COALESCE(v.nio_viab_resultado, ''::text) <> 'viavel'::text AS so_200m,
            (c.id IS NULL OR COALESCE(c.funil_destino, 'em_andamento'::text) <> 'em_andamento'::text) AND (COALESCE(c.funil_destino = ANY (ARRAY['sem_cobertura'::text, 'fora_area'::text]), false) OR COALESCE(c.saida_motivo = ANY (ARRAY['fachada_nao_atendida'::text, 'cidade_nao_atendida'::text]), false) OR v.status = 'saida'::text AND COALESCE(v.saida_motivo = ANY (ARRAY['fachada_nao_atendida'::text, 'cidade_nao_atendida'::text]), false)) AS fora_cob) f
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN (e0.etapa = ANY (ARRAY['pre_qualificado'::text, 'qualificado'::text])) AND NOT f.tem_os AND NOT f.instalada AND (f.fora_cob OR e0.etapa = 'qualificado'::text AND f.so_200m) THEN 'viabilidade'::text
                    ELSE e0.etapa
                END AS etapa,
            e0.etapa = 'qualificado'::text AND f.so_200m AND NOT f.tem_os AND NOT f.instalada AND NOT f.fora_cob AS conferir_200m
           FROM ( SELECT
                        CASE GREATEST(
                            CASE
                                WHEN f.instalada THEN 6
                                WHEN f.tem_os THEN 5
                                WHEN f.credito_ok THEN 4
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
                        END AS etapa) e0) e
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
                        CASE
                            WHEN c.antifraude_situacao = 'conferir'::text AND (e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text])) THEN 'antifraude_conferir'::text
                            WHEN c.antifraude_situacao = 'defesa'::text AND (e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text])) THEN 'defesa_nio'::text
                            WHEN e.conferir_200m THEN 'conferir_200m'::text
                            WHEN v.id IS NULL AND c.status = 'handoff_realizado'::text AND (c.handoff_motivo = ANY (ARRAY['pedido_humano'::text, 'objecao'::text, 'urgencia_alta'::text])) THEN 'pediu_humano'::text
                            ELSE
                            CASE e.etapa
                                WHEN 'instalada'::text THEN 'instalada'::text
                                WHEN 'instalacao'::text THEN
                                CASE
                                    WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN 'pendencia_nio'::text
                                    WHEN (( SELECT max(er.criado_em) AS max
                                       FROM eventos_venda er
                                      WHERE er.venda_id = v.id AND er.tipo = 'instalacao_remarcar'::text)) > COALESCE(( SELECT max(ea.criado_em) AS max
                                       FROM eventos_venda ea
                                      WHERE ea.venda_id = v.id AND ea.tipo = 'backoffice'::text AND ((ea.detalhe ->> 'momento'::text) = ANY (ARRAY['agendar'::text, 'os_agendar'::text]))), '-infinity'::timestamp with time zone) THEN 'remarcar'::text
                                    WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN 'aguarda_biometria'::text
                                    WHEN v.instalacao_agendada_para IS NULL THEN 'agendar'::text
                                    WHEN v.forma_pagamento = 'cartao'::text AND v.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                                       FROM os_andamento oa
                                      WHERE oa.venda_id = v.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > v.biometria_validada_em)) THEN 'aguarda_cartao'::text
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
                            END
                        END AS status,
                        CASE
                            WHEN c.antifraude_situacao IS NOT NULL AND (e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text])) THEN c.antifraude_em
                            WHEN e.conferir_200m THEN COALESCE(c.handoff_em, v.criado_em)
                            WHEN v.id IS NULL AND c.status = 'handoff_realizado'::text AND (c.handoff_motivo = ANY (ARRAY['pedido_humano'::text, 'objecao'::text, 'urgencia_alta'::text])) THEN c.handoff_em
                            ELSE
                            CASE e.etapa
                                WHEN 'instalacao'::text THEN
                                CASE
                                    WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN v.nio_osab_em
                                    WHEN (( SELECT max(er.criado_em) AS max
                                       FROM eventos_venda er
                                      WHERE er.venda_id = v.id AND er.tipo = 'instalacao_remarcar'::text)) > COALESCE(( SELECT max(ea.criado_em) AS max
                                       FROM eventos_venda ea
                                      WHERE ea.venda_id = v.id AND ea.tipo = 'backoffice'::text AND ((ea.detalhe ->> 'momento'::text) = ANY (ARRAY['agendar'::text, 'os_agendar'::text]))), '-infinity'::timestamp with time zone) THEN ( SELECT max(er.criado_em) AS max
                                       FROM eventos_venda er
                                      WHERE er.venda_id = v.id AND er.tipo = 'instalacao_remarcar'::text)
                                    WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN COALESCE(v.biometria_link_enviado_em, v.nio_os_em, v.vendido_em)
                                    WHEN v.instalacao_agendada_para IS NULL THEN GREATEST(v.biometria_validada_em, v.vendido_em, v.nio_os_em)
                                    WHEN v.forma_pagamento = 'cartao'::text AND v.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                                       FROM os_andamento oa
                                      WHERE oa.venda_id = v.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > v.biometria_validada_em)) THEN v.biometria_validada_em
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

-- (3) o relógio da porta anota a cutucada com o nome dela
create or replace function public._lead_estado_tick(p_agora timestamp with time zone default now())
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d record; n int := 0;
begin
  for d in select * from public.v_lead_estado_divergencias limit 100 loop
    perform public._lead_estado_marcar(d.conversa_id, d.venda_id,
      case when d.gravada = 'em_espera' then 'prazo:espera_venceu'
           when d.gravada is null then 'prazo:sem_gravacao'
           when d.gravada = 'time_esperando' and d.calculada = 'time_agora' then 'prazo:cutucar'   -- 0349
           else 'prazo:tempo' end,
      '_porta_prazos');
    n := n + 1;
  end loop;
  return n;
end $function$;

-- (4) a transição
insert into public.config_transicao (evento, de, para, aceito, frase, nota) values
  ('prazo:cutucar', 'time_esperando', array['time_agora'], true, null,
   '0349: o time respondeu, 3 h no horário do time sem o cliente responder → a vez volta ao time para cutucar (uma vez)')
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota;

-- (5) a Live: o texto da cutucada (null quando ela não está vencida)
create or replace function public._cutucada_texto(p_conversa uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select 'Cutucar o cliente · calado desde a resposta das '
         || to_char(((j ->> 'resposta_em')::timestamptz at time zone 'America/Sao_Paulo'), 'HH24:MI')
         || ' · janela fecha ' || to_char(((j ->> 'janela')::timestamptz at time zone 'America/Sao_Paulo'), 'DD/MM HH24:MI')
    from (select public._cutucada(p_conversa) as j) x
   where coalesce((j ->> 'agora')::boolean, false)
$$;
revoke all on function public._cutucada_texto(uuid) from public, anon;
grant execute on function public._cutucada_texto(uuid) to authenticated, service_role;

create or replace function public.live_situacoes()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'conversa_id', e.conversa_id, 'venda_id', e.venda_id, 'situacao', e.situacao, 'nome', s.nome,
             'vez', e.vez, 'prazo_em', e.prazo_em, 'em', e.em,
             -- 0349: time_agora porque a cutucada venceu (o cliente não escreveu depois da resposta do time)
             'o_que_fazer', coalesce(case when e.situacao = 'time_agora' and e.venda_id is null and e.conversa_id is not null
                                          then public._cutucada_texto(e.conversa_id) end, s.o_que_fazer),
             'botao', s.botao))
      from public.lead_estado e
      left join public.config_situacao s on s.codigo = e.situacao), '[]'::jsonb);
end $$;
revoke all on function public.live_situacoes() from public, anon;
grant execute on function public.live_situacoes() to authenticated, service_role;

commit;
