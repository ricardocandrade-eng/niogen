-- NIOGEN | supabase/migrations/0212_negado_antifraude.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Caso Helton (15/11): o portal respondeu o crédito com o popup "Crédito negado · Negado - Critérios Antifraude" (print do Ricardo).
-- A Nio vê Nio no endereço (o DFV mostrava endereco_ocupado e o cliente confirmou "Nio ativa" à Mari). Até aqui isso virava "negado"
-- comum — e o caminho do negado oferece o CPF de um parente, que num endereço com Nio é exatamente o que a Nio lê como fraude/recompra
-- (estorno + multa de R$ 500). Ricardo, 15/11: "esse caso pode ter solução se for tratado pelo backoffice ... pode ser levado à Nio
-- para uma defesa ... o endereço já tem Nio, mas é de outro morador que se mudou". Então: NÃO é saída automática; é vez do backoffice.
-- O que muda:
--   mari_conversas ........... antifraude_situacao ('conferir' | 'defesa' | null), antifraude_em, antifraude_hist (quem, quando, o quê).
--                              credito_resultado aceita 'negado_antifraude' (robô: portal/credito.py; extensão 0.7.1).
--   _antifraude_antes ........ gatilho: o crédito vira negado_antifraude → situação 'conferir' (o robô, a ficha ou a Mari gravam;
--                              o gatilho abre o caso). Nunca fecha sozinho: só a decisão do backoffice fecha.
--   lead_antifraude_decidir .. admin/backoffice: 'dele' (Saída Já é cliente Nio) · 'outro_morador' (Defesa na Nio, com o que foi
--                              enviado e por onde) · 'cobrar' (segue conferindo; prazo reinicia) · 'liberado' (a Nio liberou: crédito
--                              volta a "não consultado") · 'recusado' (Saída Já é cliente Nio · defesa recusada).
--   config_lead .............. status 'antifraude_conferir' (vez time, 4 h) e 'defesa_nio' (vez Nio, 48 h → vira alerta).
--   v_leads .................. esses dois status valem em qualquer degrau antes da OS; o prazo conta de antifraude_em.
--   mari_credito_gravar ...... aceita negado_antifraude; nota no Chatwoot SEMPRE (mesmo com a Mari ainda na conversa) com o que fazer.
--   mari_credito_pendentes ... a Mari não consulta crédito com antifraude em aberto nem quando o cliente confirmou Nio ativa na unidade.
--   lead_registrar_consulta .. a ficha grava "Negado - Critérios Antifraude".
-- Regra 20: (1) o lead em antifraude tem etapa, status, destino, vez (time → Nio) e prazo (4 h / 48 h); (2) prazo vencido vira
-- "atrasado" na Live e no Conferir; (3) a situação só muda pelo gatilho e por lead_antifraude_decidir, com autor e motivo
-- (antifraude_hist + linha de sistema na conversa); (4) o veredito é da Nio (portal), o NIOGEN só registra; (5) conferencia_itens não
-- ganha item: os itens 2 (todo lead com status e vez) e 3 (prazo vencido) já cobrem os dois status novos.

begin;
set local lock_timeout = '8s';

-- 1. Colunas e resultado novo
alter table public.mari_conversas
  add column if not exists antifraude_situacao text,
  add column if not exists antifraude_em       timestamptz,
  add column if not exists antifraude_hist     jsonb not null default '[]'::jsonb;
alter table public.mari_conversas drop constraint if exists mari_conversas_antifraude_situacao_check;
alter table public.mari_conversas add constraint mari_conversas_antifraude_situacao_check
  check (antifraude_situacao is null or antifraude_situacao in ('conferir', 'defesa'));
comment on column public.mari_conversas.antifraude_situacao is
  '0212: crédito "Negado - Critérios Antifraude" em aberto. conferir = o backoffice pergunta ao cliente de quem é a Nio do endereço; defesa = levado à Nio (outro morador). Null = nada em aberto.';
comment on column public.mari_conversas.antifraude_hist is '0212: cada passo do antifraude {em, por, de, para, obs}.';

alter table public.mari_conversas drop constraint if exists mari_conversas_credito_resultado_check;
alter table public.mari_conversas add constraint mari_conversas_credito_resultado_check
  check (credito_resultado is null or credito_resultado in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente',
                                                            'negado', 'negado_antifraude', 'pedido_em_andamento', 'nao_decidiu'));

-- 2. Gatilho: o antifraude chegou → abre o caso para o backoffice
create or replace function public._antifraude_antes()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.credito_resultado = 'negado_antifraude'
     and (tg_op = 'INSERT' or old.credito_resultado is distinct from 'negado_antifraude')
     and new.antifraude_situacao is null then
    new.antifraude_situacao := 'conferir';
    new.antifraude_em := now();
    new.antifraude_hist := coalesce(new.antifraude_hist, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'em', now(), 'por', coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), 'portal'),
      'de', null, 'para', 'conferir', 'obs', 'portal: Negado - Critérios Antifraude'));
  end if;
  return new;
end $$;
drop trigger if exists mari_conversas_antifraude on public.mari_conversas;
create trigger mari_conversas_antifraude before insert or update of credito_resultado on public.mari_conversas
  for each row execute function public._antifraude_antes();

-- 3. Status da escada
insert into public.config_lead (tipo, codigo, nome, ordem, etapa, vez, prazo_horas, volta, etiqueta, ajuda) values
  ('status', 'antifraude_conferir', 'Antifraude: conferir com o cliente', 13, null, 'time', 4, null, null,
   'O portal negou o crédito por "Critérios Antifraude": a Nio vê Nio neste endereço. NÃO consulte outro CPF. Pergunte ao cliente se a Nio é dele (ou de alguém da casa) ou de outro morador que se mudou, e grave na ficha › Crédito.'),
  ('status', 'defesa_nio', 'Defesa na Nio', 14, null, 'nio', 48, null, null,
   'A Nio do endereço é de outro morador e o caso foi levado à Nio (comprovante de residência ou contrato no nome do cliente, data da mudança). A vez é da Nio; passou o prazo, cobre. Liberou → consulte o crédito de novo; recusou → Saída Já é cliente Nio.')
on conflict (parceiro_id, tipo, codigo) do update
  set nome = excluded.nome, ordem = excluded.ordem, etapa = excluded.etapa, vez = excluded.vez, prazo_horas = excluded.prazo_horas,
      volta = excluded.volta, etiqueta = excluded.etiqueta, ajuda = excluded.ajuda;

-- 4. A decisão do backoffice (única porta de saída do antifraude)
create or replace function public.lead_antifraude_decidir(p_conversa uuid, p_decisao text, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c     public.mari_conversas;
  quem  text;
  obs   text := nullif(btrim(coalesce(p_obs, '')), '');
  para  text;
  rot   text;
  r     jsonb := null;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.antifraude_situacao is null then raise exception 'Este lead não tem antifraude em aberto.'; end if;
  if p_decisao not in ('dele', 'outro_morador', 'cobrar', 'liberado', 'recusado') then
    raise exception 'Decisão desconhecida: %', p_decisao;
  end if;
  if p_decisao in ('liberado', 'recusado') and c.antifraude_situacao <> 'defesa' then
    raise exception 'Liberado ou recusado é a resposta da Nio à defesa: primeiro marque "é de outro morador".';
  end if;
  if p_decisao = 'outro_morador' and coalesce(length(obs), 0) < 10 then
    raise exception 'Diga o que foi enviado à Nio e por onde (ex.: "comprovante de residência e contrato de aluguel, e-mail ao Rogério").';
  end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  para := case p_decisao when 'outro_morador' then 'defesa' when 'cobrar' then c.antifraude_situacao else null end;
  rot  := case p_decisao when 'dele' then 'a Nio do endereço é do cliente (ou da casa) → Já é cliente Nio'
                         when 'outro_morador' then 'Nio de outro morador → defesa na Nio'
                         when 'cobrar' then 'cliente ainda não respondeu → segue conferindo'
                         when 'liberado' then 'a Nio liberou na defesa → consultar o crédito de novo'
                         else 'a Nio recusou a defesa → Já é cliente Nio' end;

  update public.mari_conversas
     set antifraude_situacao = para,
         antifraude_em = now(),
         antifraude_hist = antifraude_hist || jsonb_build_array(jsonb_build_object(
           'em', now(), 'por', quem, 'de', c.antifraude_situacao, 'para', coalesce(para, p_decisao), 'obs', obs)),
         -- liberado: o crédito volta a "não consultado" (consultar de novo no endereço do cliente)
         credito_resultado = case when p_decisao = 'liberado' then null else credito_resultado end,
         credito_em = case when p_decisao = 'liberado' then null else credito_em end
   where id = c.id;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[antifraude no NIOGEN por ' || quem || ': ' || rot || coalesce(' — ' || obs, '') || ']', false);

  if p_decisao in ('dele', 'recusado') then
    r := public.lead_sair(c.id, null, 'ja_cliente_nio',
                          case when p_decisao = 'dele' then 'antifraude — Nio do cliente' else 'antifraude — defesa recusada' end,
                          null, obs, null);
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ antifraude: ' || rot, 'saida', r);
end $$;
revoke all on function public.lead_antifraude_decidir(uuid, text, text) from public, anon;
grant execute on function public.lead_antifraude_decidir(uuid, text, text) to authenticated;

-- 5. v_leads: os dois status novos (antes da OS) e o prazo a partir de antifraude_em. Corpo = produção de 15/11 + os dois CASE.
CREATE OR REPLACE VIEW public.v_leads WITH (security_invoker = true) AS
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
                        CASE
                            WHEN c.antifraude_situacao = 'conferir'::text AND e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text]) THEN 'antifraude_conferir'::text
                            WHEN c.antifraude_situacao = 'defesa'::text AND e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text]) THEN 'defesa_nio'::text
                            ELSE
                        CASE e.etapa
                            WHEN 'instalada'::text THEN 'instalada'::text
                            WHEN 'instalacao'::text THEN
                            CASE
                                WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN 'pendencia_nio'::text
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
                        END END AS status,
                        CASE
                            WHEN c.antifraude_situacao IS NOT NULL AND e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text]) THEN c.antifraude_em
                            ELSE
                        CASE e.etapa
                            WHEN 'instalacao'::text THEN
                            CASE
                                WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN v.nio_osab_em
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
                        END END AS base_em) x
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

-- 6. Mari e ficha aceitam negado_antifraude (corpo = produção de 15/11 + as linhas marcadas 0212)
CREATE OR REPLACE FUNCTION public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_op text := p_saida->>'resultado'; v text; c record; v_formas text; v_fp text; v_fazer text;
        v_end text := case when p_saida->'endereco'->>'origem' = 'cliente' then 'cliente' when p_saida->'endereco'->>'origem' = 'padrao' then 'padrao' end;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(), credito_endereco = v_end,
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status,
                                   forma_pagamento, credito_consultas into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada', 'endereco', v_end,
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null or v = 'negado_antifraude') then   -- 0212: antifraude sempre vira nota
    v_formas := (select string_agg(case upper(x) when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão' when 'DACC' then 'débito em conta' else lower(x) end, ', ')
                   from jsonb_array_elements_text(case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' else '[]'::jsonb end) x);
    v_fp := case c.forma_pagamento when 'boleto' then 'boleto' when 'cartao' then 'cartão' when 'debito' then 'débito em conta' end;
    v_fazer := case
      when v = 'negado_antifraude' then 'NÃO consultar outro CPF. Perguntar ao cliente se a Nio do endereço é dele (ou de alguém da casa) ou de outro morador que se mudou; gravar a resposta na ficha › Crédito (Antifraude).'
      when v = 'pedido_em_andamento' then 'NÃO abrir outro pedido: conferir no portal o pedido que já existe no CPF (recompra = multa R$ 500).'
      when v_end = 'padrao' and v like 'aprovado%' then 'Consultar o crédito de novo no endereço do cliente (ficha › Crédito) antes de abrir o pedido.'
      when v = 'nao_decidiu' then 'Consultar o crédito na ficha (Crédito) — o portal não decidiu.'
      when v = 'pendente' then 'Aguardar a resposta da Nio (até 24 h) e avisar o cliente; não abrir o pedido antes.'
      when v = 'negado' and coalesce(c.credito_consultas, 0) >= 2 then 'Ver com o cliente outra pessoa da casa como titular; sem saída, encerrar pela Saída.'
      when v = 'negado' then 'Oferecer outra pessoa da casa como titular (CPF do parente → 1 nova consulta).'
      when v = 'aprovado_cartao' and coalesce(c.forma_pagamento, '') <> 'cartao' then 'Só o cartão foi liberado: confirmar se o cliente paga no cartão; se não, outra pessoa da casa como titular.'
      when v = 'aprovado_parcial' and c.forma_pagamento in ('boleto', 'cartao', 'debito')
           and not coalesce(p_saida->'formas_liberadas', '[]'::jsonb) ? (case c.forma_pagamento when 'boleto' then 'BOLETO' when 'cartao' then 'CREDITO' else 'DACC' end)
        then 'A forma escolhida (' || v_fp || ') não foi liberada: combinar com o cliente uma das liberadas (' || coalesce(v_formas, '?') || ').'
      else 'Gravar o crédito na ficha e abrir o pedido no portal' || coalesce(' no ' || v_fp, '') || '; avisar o cliente do link da biometria que a Nio manda.' end;
    insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload, status)
    values (gen_random_uuid(), 1, 'credito', c.venda_id, p_conversa, c.chatwoot_conversation_id, 'nota',
            jsonb_build_object('content', '💳 Crédito chegou (consulta automática da Mari'
              || coalesce(', ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '') || '): '
              || case v when 'aprovado_todas' then 'APROVADO — todas as formas'
                        when 'aprovado_parcial' then 'APROVADO — ' || coalesce(v_formas, 'formas: ?')
                        when 'aprovado_cartao' then 'APROVADO SÓ NO CARTÃO'
                        when 'pendente' then 'PENDENTE (a Nio responde em até 24 h)'
                        when 'negado' then case when coalesce(c.credito_consultas, 0) >= 2 then 'NEGADO nos 2 CPFs (titular e parente)' else 'NEGADO neste CPF' end
                        when 'negado_antifraude' then 'NEGADO — CRITÉRIOS ANTIFRAUDE (a Nio vê Nio neste endereço)'
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF'
                        else 'o portal não decidiu' end
              -- 0204: lido no endereço padrão → não vale para o endereço do cliente
              || case when v_end = 'padrao' and v like 'aprovado%' then ' · ⚠ lido no endereço PADRÃO, não no do cliente' else '' end
              || E'\n👉 Fazer agora: ' || v_fazer), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v, 'endereco', v_end);
end $function$;

CREATE OR REPLACE FUNCTION public.mari_credito_pendentes(p_limite integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where c.credito_em is null and c.credito_consultas < 2
       and public._cpf_ok(c.dados->>'cpf')
       and coalesce(c.dados->>'email', '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
       and coalesce(c.dados->>'email_confirmado', '') <> 'false'
       and coalesce(c.nao_contatar, false) = false
       -- 0212: antifraude em aberto ou cliente que confirmou Nio ativa na unidade → o backoffice decide; a Mari não consulta sozinha
       and c.antifraude_situacao is null
       and coalesce(c.handoff_briefing, '') !~* 'nio ativa nesta unidade'
       and coalesce(c.telefone, '') !~ '^55000000'
       and c.updated_at > now() - interval '12 hours'
       -- 0205 (Ricardo, 15/11: "a Mari não pode usar endereço padrão — isso é só para a tela Cobertura"): a Mari só consulta
       -- crédito com o ENDEREÇO DO CLIENTE e só depois da viabilidade dar VIÁVEL. Sem isso, não consulta (o time decide).
       and regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') ~ '^\d{8}$' and nullif(btrim(coalesce(c.numero, '')), '') is not null
       and (c.cobertura_decisao = 'viavel' or c.nio_viab_resultado = 'viavel')
       and (select count(distinct regexp_replace(o.dados->>'cpf', '\D', '', 'g')) from public.mari_conversas o
             where o.telefone = c.telefone and o.credito_consultas > 0 and o.credito_em > now() - interval '7 days'
               and regexp_replace(o.dados->>'cpf', '\D', '', 'g') <> regexp_replace(c.dados->>'cpf', '\D', '', 'g')) < 3
     order by c.updated_at
     limit greatest(1, least(p_limite, 2))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set credito_consultas = c.credito_consultas + 1, credito_em = now(),
           credito_autorizado_em = coalesce(c.credito_autorizado_em, now()),
           credito_autorizacao_frase = coalesce(c.credito_autorizacao_frase, 'automática — sem pergunta (Ricardo, 12/11)')
      from alvo where c.id = alvo.id
    returning c.id, c.dados, c.telefone, c.cep, c.numero, c.complemento, c.endereco_cep,
              (c.cobertura_decisao = 'viavel' or c.nio_viab_resultado = 'viavel') as viavel
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'conversa_id', id,
           'cpf', regexp_replace(dados->>'cpf', '\D', '', 'g'),
           'celular', right(regexp_replace(coalesce(dados->>'telefone', telefone, ''), '\D', '', 'g'), 11),
           'email', lower(dados->>'email'),
           -- 0204: endereço do cliente quando viável (null → o operador usa o endereço padrão e o resultado sai marcado)
           'endereco', case when true and regexp_replace(coalesce(cep, ''), '\D', '', 'g') ~ '^\d{8}$' and nullif(btrim(coalesce(numero, '')), '') is not null
             then jsonb_build_object('cep', regexp_replace(cep, '\D', '', 'g'), 'numero', btrim(numero),
                    'complemento', case when complemento ~* '(ap|apto|apartamento|bloco|bl|sala|loja|casa\s+[a-z0-9]\b|fundos|\d)'
                                         and complemento !~* '^\s*(casa|nenhum|nao|não|sem)\s*$' then left(btrim(complemento), 60) else '' end,
                    'referencia', left(coalesce(nullif(btrim(dados->>'referencia'), ''), 'Sem referência'), 80),
                    'logradouro_esperado', left(coalesce(nullif(btrim(dados->>'rua_confirmada'), ''), nullif(btrim(dados->>'rua_informada'), ''),
                                                         endereco_cep->>'logradouro', ''), 120)) end))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.lead_registrar_consulta(p_conversa uuid, p_tipo text, p_resultado text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.mari_conversas;
  rot  text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: registre na venda.'; end if;

  if p_tipo = 'viabilidade' then
    if p_resultado <> 'viavel' then
      raise exception 'Por aqui só se grava "viável". Sem viabilidade: use Saída › Fachada não atendida.';
    end if;
    update public.mari_conversas
       set nio_viab_resultado = 'viavel', nio_viab_em = now(),
           cobertura_decisao = 'viavel', cobertura_em = now(),
           cobertura_detalhe = coalesce(cobertura_detalhe, '{}'::jsonb) || jsonb_build_object('portal', 'viavel', 'registrado_na_ficha', true),
           rua_conferir_em = null   -- 0202: viável registrado na ficha = rua conferida
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('viabilidade', 'tela', auth.uid(), c.id, c.cep, c.numero, c.complemento, 'viavel', 'viavel', jsonb_build_object('registrado_na_ficha', true));
    rot := 'viabilidade: viável';

  elsif p_tipo = 'credito' then
    if p_resultado not in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'pedido_em_andamento') then
      raise exception 'Resultado de crédito desconhecido: %', p_resultado;
    end if;
    update public.mari_conversas
       set credito_resultado = p_resultado, credito_em = now(),
           nio_pedido_aberto = case when p_resultado = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, resultado, detalhe)
    values ('credito', 'tela', auth.uid(), c.id, p_resultado, jsonb_build_object('registrado_na_ficha', true));
    rot := 'crédito: ' || case p_resultado when 'aprovado_todas' then 'aprovado' when 'aprovado_parcial' then 'aprovado (parcial)'
                                           when 'aprovado_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente'
                                           when 'negado' then 'negado' when 'negado_antifraude' then 'negado por critérios antifraude — conferir com o cliente' else 'já tem pedido em andamento' end;
  else
    raise exception 'Tipo desconhecido: %', p_tipo;
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ registrado no lead — ' || rot);
end;
$function$;

commit;
