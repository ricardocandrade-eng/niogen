-- NIOGEN | supabase/migrations/0112_funil_instalacoes_resultado.sql | 10/11/2026 ~20h — Claude Code (Opus)
-- Prompt: docs/Prompt_funil_instalacoes_resultado_101126_1645.md (Parte 1 + Parte 2) · protótipo docs/LAYOUT_funil_instalacoes_resultado_101126_1640.html
-- Resultado (regra 18): mais vendas instaladas de primeira e menos receita perdida depois da instalação.
--   1. config_regras: ritmo_limiares (cor da frase do ritmo), osab_alerta_horas / osab_critico_horas, instalacao_confirmacao
--      (botões dos templates nio_lembrete_instalacao e nio_instalacao_agendada), protecao_receita (reativação 30 d).
--   2. eventos_venda.parceiro_id (regra 15) + gatilho em mari_turnos: resposta do cliente ao botão "Tudo certo/Confirmo" ou
--      "Preciso remarcar" com instalação marcada → evento instalacao_confirmada / instalacao_remarcar.
--   3. v_instalacao_confirmacao (security_invoker): por venda agendada — resposta desde o último agendamento, lembrete da véspera.
--   4. v_jornada: "Preciso remarcar" vira ação AGORA (botão Reagendar) — mesma camada dos alertas do portal/GED360.
--   5. painel_meta_ritmo: campos aditivos (dias úteis passados, ritmo por dia, projeção do mês, onde deveria estar hoje).
--   6. Parte 2 — config_oportunidades O6 (saída recuperável) · O7 (não confirmou a visita) · O8/O9 (1ª fatura — DESLIGADAS até
--      existir o extrato de faturas) + texto op_O6; v_oportunidades ganha as linhas por venda (mesmo grupo 🔥, mesmo teto, mesma medição).
-- Contrato: comissão sempre previsão; saída de cliente/endereço já na base Nio ou fraude nunca volta; sem desconto na retomada.

-- ───────── 1. config ─────────
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('ritmo_limiares', '{"ok_pct": 100, "atencao_pct": 80}'::jsonb,
   'Cor da frase do ritmo da meta (Funil): ritmo atual ≥ ok_pct % do necessário = verde; ≥ atencao_pct % = âmbar; abaixo = vermelho.', 'dharma'),
  ('osab_alerta_horas', '24'::jsonb, 'Instalações: "OSAB lido há N h" em âmbar acima disto (a comissão só conta quando o OSAB confirma).', 'dharma'),
  ('osab_critico_horas', '48'::jsonb, 'Instalações: o aviso do OSAB fica vermelho acima disto.', 'dharma'),
  ('instalacao_confirmacao', '{"confirma": ["tudo certo", "confirmo"], "remarcar": ["preciso remarcar"]}'::jsonb,
   'Respostas (botões) dos templates nio_lembrete_instalacao / nio_instalacao_agendada que confirmam a visita ou pedem para remarcar. Comparação sem acento, caixa e pontuação.', 'dharma'),
  ('protecao_receita', '{"reativacao_dias": 30, "janela_meses": 10}'::jsonb,
   'Instalações › proteger a receita: reativação ≤ reativacao_dias estorna 100 % (contrato); cartão aparece para instaladas nos últimos janela_meses. Downgrade vem de v_funil.downgrade_ate; M-10 de vendas.bonus_m10_potencial.', 'dharma')
on conflict (chave) do nothing;

-- ───────── 2. evento da resposta ao botão ─────────
alter table public.eventos_venda add column if not exists parceiro_id text not null default 'dharma';

create or replace function public._norm_resposta(p text)
returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(lower(translate(coalesce(p, ''), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇç', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCc')), '[^a-z0-9 ]+', '', 'g'))
$$;

create or replace function public.mari_turnos_confirmacao_instalacao()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v      public.vendas;
  cfg    jsonb;
  t      text;
  tipo   text;
begin
  if new.papel <> 'lead' or coalesce(btrim(new.texto), '') = '' or length(new.texto) > 60 then return new; end if;
  select v2.* into v from public.mari_conversas c join public.vendas v2 on v2.id = c.venda_id
   where c.id = new.conversa_id
     and v2.status in ('1_vendido', '2_aguardando_instalacao')
     and v2.instalacao_agendada_para is not null
     and v2.instalacao_agendada_para > now() - interval '12 hours';
  if v.id is null then return new; end if;
  select valor into cfg from public.config_regras where chave = 'instalacao_confirmacao';
  t := public._norm_resposta(new.texto);
  if t in (select public._norm_resposta(x) from jsonb_array_elements_text(coalesce(cfg -> 'remarcar', '["preciso remarcar"]'::jsonb)) x) then
    tipo := 'instalacao_remarcar';
  elsif t in (select public._norm_resposta(x) from jsonb_array_elements_text(coalesce(cfg -> 'confirma', '["tudo certo","confirmo"]'::jsonb)) x) then
    tipo := 'instalacao_confirmada';
  else
    return new;
  end if;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_em, parceiro_id)
  values (v.id, tipo, jsonb_build_object('agendada_para', v.instalacao_agendada_para, 'texto', left(new.texto, 60),
                                         'conversa_id', new.conversa_id, 'turno_id', new.id), coalesce(new.created_at, now()), 'dharma');
  return new;
exception when others then
  return new;   -- nunca derruba a gravação da fala do cliente
end $$;

drop trigger if exists mari_turnos_confirmacao_instalacao on public.mari_turnos;
create trigger mari_turnos_confirmacao_instalacao after insert on public.mari_turnos
  for each row execute function public.mari_turnos_confirmacao_instalacao();

-- ───────── 3. v_instalacao_confirmacao ─────────
create or replace view public.v_instalacao_confirmacao with (security_invoker = true) as
select v.id as venda_id,
       'dharma'::text as parceiro_id,
       v.instalacao_agendada_para as agendada_para,
       r.resposta, r.resposta_em, r.texto as resposta_texto,
       (select max(cc.em) from public.contatos_cliente cc where cc.venda_id = v.id and cc.toque = 'VESPERA'
          and cc.em >= coalesce(v.agendamento_registrado_em, '-infinity'::timestamptz)) as lembrete_em,
       (select max(cc.em) from public.contatos_cliente cc where cc.venda_id = v.id and cc.toque = 'INSTALACAO'
          and cc.em >= coalesce(v.agendamento_registrado_em, '-infinity'::timestamptz)) as aviso_em
  from public.vendas v
  left join lateral (
    select case e.tipo when 'instalacao_confirmada' then 'confirmou' else 'remarcar' end as resposta,
           e.criado_em as resposta_em, e.detalhe ->> 'texto' as texto
      from public.eventos_venda e
     where e.venda_id = v.id and e.tipo in ('instalacao_confirmada', 'instalacao_remarcar')
       and e.criado_em >= coalesce(v.agendamento_registrado_em, '-infinity'::timestamptz)
     order by e.criado_em desc limit 1) r on true
 where v.status in ('1_vendido', '2_aguardando_instalacao') and v.instalacao_agendada_para is not null;
comment on view public.v_instalacao_confirmacao is
  '0112: confirmação da visita por venda agendada — resposta ao botão (confirmou | remarcar | null = ainda não) desde o último agendamento e hora do lembrete da véspera (toque VESPERA da cadência).';
grant select on public.v_instalacao_confirmacao to authenticated;

-- ───────── 4. v_jornada: "Preciso remarcar" = ação agora (Reagendar) ─────────
create or replace view public.v_jornada with (security_invoker = true) as
 SELECT j.tipo, j.chave, j.venda_id, j.conversa_id, j.chatwoot_conversation_id, j.nome, j.cidade, j.plano, j.origem, j.etapa, j.etapa_nome,
    (j.precisa_acao OR a.usa) AS precisa_acao,
    CASE WHEN a.usa THEN a.nivel ELSE j.nivel END AS nivel,
    CASE WHEN a.usa THEN a.texto ELSE j.o_que_fazer END AS o_que_fazer,
    CASE WHEN a.usa THEN a.botao ELSE j.botao END AS botao,
    CASE WHEN a.usa THEN a.em ELSE j.desde END AS desde,
    j.dono_tipo, j.dono_nome, j.pendencia, j.acao_id, j.status_venda, j.parceiro_id, j.sem_dono_min, j.pedido_provisorio,
    j.cliente_confirmou, j.confirmou_em,
    an.portal_status, an.portal_desde AS portal_status_desde, an.bio_resultado AS biometria_ged, an.bio_desde AS biometria_ged_desde
   FROM v_jornada_base j
     LEFT JOIN v_venda_andamento an ON an.venda_id = j.venda_id
     LEFT JOIN v_instalacao_confirmacao ic ON ic.venda_id = j.venda_id AND ic.resposta = 'remarcar'
     LEFT JOIN LATERAL ( SELECT x.texto, x.nivel, x.em, x.botao
           FROM ( VALUES (an.portal_alerta, an.portal_alerta_nivel, an.portal_desde, 'abrir'::text),
                         (an.bio_alerta, an.bio_alerta_nivel, an.bio_desde, 'abrir'::text),
                         (CASE WHEN ic.venda_id IS NOT NULL THEN 'Cliente pediu para remarcar a instalação · reagendar no portal e gravar'::text END,
                          'agora'::text, ic.resposta_em, 'reagendar'::text)) x(texto, nivel, em, botao)
          WHERE x.texto IS NOT NULL
          ORDER BY CASE x.nivel WHEN 'agora'::text THEN 0 ELSE 1 END, x.em
         LIMIT 1) al ON true
     CROSS JOIN LATERAL ( SELECT al.texto, al.nivel, al.em, al.botao,
            COALESCE(al.texto IS NOT NULL AND j.etapa > 0 AND (j.nivel <> 'agora'::text OR (al.botao = 'reagendar'::text AND j.botao = 'responder'::text)) AND
                CASE al.nivel WHEN 'agora'::text THEN 0 ELSE 1 END <= CASE j.nivel WHEN 'hoje'::text THEN 1 ELSE 2 END, false) AS usa) a;

-- ───────── 5. painel_meta_ritmo: campos aditivos ─────────
create or replace function public.painel_meta_ritmo(p_hoje date default ((now() at time zone 'America/Sao_Paulo'::text))::date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_ini date := date_trunc('month', p_hoje)::date;
  v_fim date := (date_trunc('month', p_hoje) + interval '1 month - 1 day')::date;
  v_meta int; v_inst int; v_faltam int; v_dias int; v_pass int; v_ritmo numeric;
begin
  if auth.role() <> 'service_role' and public.meu_perfil() is null then
    return null;
  end if;
  select meta_vendas into v_meta from public.config_metas where mes = v_ini and parceiro_id = 'dharma';
  select count(*) into v_inst
    from public.vendas v
   where v.instalado_em is not null
     and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
     and (v.instalado_em at time zone 'America/Sao_Paulo')::date between v_ini and v_fim;
  v_meta := coalesce(v_meta, 0);
  v_faltam := greatest(v_meta - v_inst, 0);
  -- 0099: dias úteis = dias de contato (sem domingo e sem feriado nacional/estadual), de hoje ao fim do mês.
  select count(*) into v_dias from generate_series(p_hoje, v_fim, interval '1 day') g(d)
   where public.mari_dia_permitido(g.d::date, null);
  -- 0112: dias úteis já passados no mês (do dia 1 até ontem) → ritmo atual e projeção.
  select count(*) into v_pass from generate_series(v_ini, p_hoje - 1, interval '1 day') g(d)
   where public.mari_dia_permitido(g.d::date, null);
  v_ritmo := case when v_pass > 0 then v_inst::numeric / v_pass else null end;
  return jsonb_build_object(
    'mes', to_char(v_ini, 'YYYY-MM'),
    'meta', v_meta,
    'instaladas', v_inst,
    'faltam', v_faltam,
    'dias_restantes', v_dias,
    'dias_uteis', true,
    'por_dia', case when v_dias > 0 then round(v_faltam::numeric / v_dias, 1) else v_faltam end,
    'pct', case when v_meta > 0 then round(100.0 * v_inst / v_meta, 1) else null end,
    'dias_passados', v_pass,
    'dias_mes', v_pass + v_dias,
    'ritmo_dia', round(coalesce(v_ritmo, 0), 2),
    'projecao', round(v_inst + coalesce(v_ritmo, 0) * v_dias),
    'deveria_hoje', case when v_pass + v_dias > 0 then round(v_meta::numeric * v_pass / (v_pass + v_dias), 1) else 0 end
  );
end $function$;

-- ───────── 6. Parte 2: O6–O9 ─────────
insert into public.config_oportunidades (codigo, parceiro_id, nome, ativo, pontos, ordem, parametros, descricao) values
  ('O6', 'dharma', 'Saída recuperável', true, 25, 60,
   '{"dias": {"Interesse futuro (com data)": 7, "Desistiu": 15, "Preço": 15, "Achou caro": 15, "Sem contato (cadência esgotada)": 15},
     "nunca": ["Já é cliente Nio", "Endereço já na base Nio", "Fraude", "Suspeita de fraude"],
     "fora_area": ["Sem cobertura", "Fora da área"], "max_dias_depois": 30}'::jsonb,
   'Venda em Saída com motivo em "dias" volta ao Live depois de N dias da saída (interesse futuro com data: no dia combinado), uma vez só (até max_dias_depois). Nunca: motivos em "nunca", conferência já cliente/fraude/pedido na Nio, endereço já na base (DFV). "fora_area" = avisar se a cobertura chegar (só rótulo no Funil). É também a lista do resumo da Saída no Funil.'),
  ('O7', 'dharma', 'Não confirmou a visita', true, 55, 70, '{"hora": "20:00"}'::jsonb,
   'Instalação amanhã sem "Tudo certo/Confirmo" até a hora (SP) → ligar hoje. "Preciso remarcar" não entra aqui: vira ação AGORA no Live (reagendar).'),
  ('O8', 'dharma', '1ª fatura em aberto D+5', false, 60, 80, '{"dias_atraso": 5, "valor_m10": 150}'::jsonb,
   'DESLIGADA até existir o extrato de faturas da Nio (v_adimplencia não aplicada). 1ª fatura confirmada em aberto há ≥ dias_atraso → ligar hoje — 15 dias sem pagar perde o M-10.'),
  ('O9', 'dharma', 'D−2 sem leitura do boleto', false, 20, 90, '{"dias_antes": 2}'::jsonb,
   'DESLIGADA até existir o extrato de faturas e o registro de entrega da régua. 1ª fatura vence em dias_antes e a régua não tem entrega → conferir se o cliente recebeu o boleto.')
on conflict (codigo) do nothing;

insert into public.config_mari_textos (chave, texto) values
  ('op_O6', 'Oi[, {nome}]! Aqui é {agente}, que cuidou do seu pedido de internet fibra 😊 Lembrei de você: ainda faz sentido a gente retomar a instalação? Posso te mostrar de novo os planos.')
on conflict (chave) do nothing;

-- v_oportunidades: as regras por conversa de antes (O1–O5) + as por venda (O6–O9), um só ranking e o mesmo teto max_dia.
create or replace view public.v_oportunidades with (security_invoker = true) as
WITH cfg AS (
         SELECT COALESCE(((g.p ->> 'ligado'::text))::boolean, true) AS ligado,
            COALESCE(((g.p ->> 'max_dia'::text))::integer, 5) AS max_dia,
            COALESCE(((g.p ->> 'max_por_conversa_dia'::text))::integer, 1) AS max_conv,
            COALESCE(((g.p ->> 'max_parado_dias'::text))::numeric, (7)::numeric) AS max_dias,
            COALESCE(((g.p ->> 'janela_horas'::text))::numeric, (23)::numeric) AS janela_h,
            (g.p ->> 'template'::text) AS tpl,
            ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date AS hoje
           FROM ( SELECT COALESCE(( SELECT config_oportunidades.parametros
                           FROM config_oportunidades
                          WHERE (config_oportunidades.codigo = 'geral'::text)), '{}'::jsonb) AS p) g
        ), regra AS (
         SELECT config_oportunidades.codigo,
            config_oportunidades.nome,
            config_oportunidades.pontos,
            config_oportunidades.ordem,
            config_oportunidades.parametros AS p
           FROM config_oportunidades
          WHERE (config_oportunidades.ativo AND (config_oportunidades.codigo <> 'geral'::text))
        ), tpl AS (
         SELECT t.nome
           FROM config_templates_waba t,
            cfg cfg_1
          WHERE ((t.uso = 'oportunidade'::text) AND (t.status = 'APPROVED'::text) AND ((cfg_1.tpl IS NULL) OR (t.nome = cfg_1.tpl)))
          ORDER BY t.nome
         LIMIT 1
        ), feitas_hoje AS (
         SELECT l.conversa_id,
            count(*) AS n
           FROM oportunidades_log l,
            cfg cfg_1
          WHERE ((l.tipo = ANY (ARRAY['enviada'::text, 'dispensada'::text])) AND (((l.criado_em AT TIME ZONE 'America/Sao_Paulo'::text))::date = cfg_1.hoje))
          GROUP BY l.conversa_id
        ), eu AS (
         SELECT NULLIF(split_part(btrim(u.nome), ' '::text, 1), ''::text) AS nome
           FROM usuarios u
          WHERE (u.id = auth.uid())
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
            COALESCE(NULLIF(split_part(btrim((c.dados ->> 'nome'::text)), ' '::text, 1), ''::text),
                CASE
                    WHEN c.nome_confiavel THEN NULLIF(split_part(btrim(c.nome_contato), ' '::text, 1), ''::text)
                    ELSE NULL::text
                END) AS primeiro_nome,
            mari_cadencia_nome(c.*) AS nome_template,
            (c.ultima_msg_lead_at + ((cfg_1.janela_h)::double precision * '01:00:00'::interval)) AS janela_fecha_em,
            minutos_uteis(q.ultima_em, now(), q.cidade) AS min_uteis,
            (EXISTS ( SELECT 1
                   FROM mari_turnos t
                  WHERE ((t.conversa_id = q.id) AND (t.papel = 'mari'::text) AND (t.tags ? 'carrossel'::text)))) AS viu_planos
           FROM ((v_mari_quadro q
             JOIN mari_conversas c ON ((c.id = q.id)))
             CROSS JOIN cfg cfg_1)
          WHERE (cfg_1.ligado AND (NOT q.teste) AND (q.coluna = ANY (ARRAY['novo'::text, 'qualificando'::text, 'planos'::text, 'dados'::text, 'retomada'::text])) AND (q.vez = 'cliente'::text) AND (COALESCE(q.ultima_quem, ''::text) <> 'humano'::text) AND (q.venda_id IS NULL) AND (c.canal = 'whatsapp'::text) AND (COALESCE(c.chatwoot_conversation_id, ''::text) <> ''::text) AND (NOT COALESCE(c.nao_contatar, false)) AND (NOT COALESCE(c.humano_atribuido, false)) AND (c.chatwoot_agente IS NULL) AND ((c.espera_ate IS NULL) OR (c.espera_ate <= now())) AND (q.trava_cliente_nio <> 'bloqueia'::text) AND (q.trava_viabilidade <> 'bloqueia'::text) AND (q.trava_endereco_nio <> 'bloqueia'::text) AND (q.ultima_em > (now() - ((cfg_1.max_dias)::double precision * '1 day'::interval))) AND (COALESCE(( SELECT f.n
                   FROM feitas_hoje f
                  WHERE (f.conversa_id = q.id)), (0)::bigint) < cfg_1.max_conv) AND (NOT (EXISTS ( SELECT 1
                   FROM oportunidades_log l
                  WHERE ((l.conversa_id = q.id) AND (l.tipo = 'enviada'::text) AND (l.criado_em > COALESCE(c.ultima_msg_lead_at, '-infinity'::timestamp with time zone)))))))
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
           FROM (base b
             JOIN regra r ON (
                CASE r.codigo
                    WHEN 'O1'::text THEN ((b.janela_fecha_em > now()) AND (b.janela_fecha_em <= (now() + ((COALESCE(((r.p ->> 'fecha_em_horas'::text))::numeric, (4)::numeric))::double precision * '01:00:00'::interval))) AND ((b.itens_validados >= COALESCE(((r.p ->> 'termometro_min'::text))::integer, 2)) OR b.viu_planos OR (b.coluna = 'planos'::text)))
                    WHEN 'O2'::text THEN ((b.coluna = 'planos'::text) AND ((b.min_uteis)::numeric >= (COALESCE(((r.p ->> 'min_horas_uteis'::text))::numeric, (2)::numeric) * (60)::numeric)) AND (b.parado_desde >= (now() - ((COALESCE(((r.p ->> 'max_horas'::text))::numeric, (48)::numeric))::double precision * '01:00:00'::interval))))
                    WHEN 'O3'::text THEN ((((b.dados ->> 'objecao'::text) IN ( SELECT jsonb_array_elements_text(COALESCE((r.p -> 'objecoes'::text), '[]'::jsonb)) AS jsonb_array_elements_text)) OR (b.alertas && ARRAY( SELECT jsonb_array_elements_text(COALESCE((r.p -> 'alertas'::text), '[]'::jsonb)) AS jsonb_array_elements_text))) AND ((b.min_uteis)::numeric >= (COALESCE(((r.p ->> 'min_horas_uteis'::text))::numeric, (1)::numeric) * (60)::numeric)))
                    WHEN 'O4'::text THEN ((b.itens_validados >= COALESCE(((r.p ->> 'termometro_min'::text))::integer, 6)) AND ((b.min_uteis)::numeric >= (COALESCE(((r.p ->> 'min_horas_uteis'::text))::numeric, (1)::numeric) * (60)::numeric)))
                    WHEN 'O5'::text THEN ((b.trava_viabilidade = 'ok'::text) AND (b.trava_endereco_nio = 'ok'::text) AND ((b.min_uteis)::numeric >= (COALESCE(((r.p ->> 'min_horas_uteis'::text))::numeric, (1)::numeric) * (60)::numeric)))
                    ELSE false
                END))
        ), agg AS (
         SELECT bate.conversa_id,
            (array_agg(bate.codigo ORDER BY bate.pontos DESC, bate.ordem))[1] AS codigo,
            array_agg(bate.codigo ORDER BY bate.pontos DESC, bate.ordem) AS regras,
            (sum(bate.pontos))::integer AS pontos
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
                    WHEN (b.janela_fecha_em > now()) THEN 'livre'::text
                    WHEN (EXISTS ( SELECT 1
                       FROM tpl)) THEN 'template'::text
                    ELSE 'ligar'::text
                END AS canal,
            ( SELECT t.nome
                   FROM tpl t) AS template,
            (
                CASE a.codigo
                    WHEN 'O1'::text THEN (('Janela de 24 h fecha em '::text || _oport_dur((b.janela_fecha_em - now()))) ||
                    CASE
                        WHEN ((b.coluna = 'planos'::text) OR b.viu_planos) THEN ' · já viu os planos'::text
                        ELSE ''::text
                    END)
                    WHEN 'O2'::text THEN (('Viu os planos há '::text || _oport_dur((now() - b.parado_desde))) || ' e não escolheu'::text)
                    WHEN 'O3'::text THEN ((
                    CASE
                        WHEN ('desconto'::text = ANY (b.alertas)) THEN 'Pediu desconto'::text
                        ELSE ('Objeção: '::text || COALESCE(
                        CASE (b.dados ->> 'objecao'::text)
                            WHEN 'preco'::text THEN 'achou caro'::text
                            WHEN 'pensar'::text THEN 'vai pensar'::text
                            WHEN 'consultar_alguem'::text THEN 'vai ver com alguém'::text
                            WHEN 'ja_tem'::text THEN 'já tem internet'::text
                            WHEN 'marca'::text THEN 'não conhece a Nio'::text
                            WHEN 'sem_5g'::text THEN 'não precisa do 5G'::text
                            ELSE NULL::text
                        END, (b.dados ->> 'objecao'::text)))
                    END || ' · sem resposta há '::text) || _oport_dur((now() - b.parado_desde)))
                    WHEN 'O4'::text THEN ((((('Quase pronto: '::text || b.itens_validados) || '/'::text) || b.itens_total) || ' dados · parou há '::text) || _oport_dur((now() - b.parado_desde)))
                    WHEN 'O5'::text THEN ('Viabilidade ok e endereço livre · parou há '::text || _oport_dur((now() - b.parado_desde)))
                    ELSE NULL::text
                END ||
                CASE
                    WHEN ((a.codigo <> 'O1'::text) AND ('O1'::text = ANY (a.regras))) THEN (' · janela fecha em '::text || _oport_dur((b.janela_fecha_em - now())))
                    ELSE ''::text
                END) AS motivo
           FROM ((agg a
             JOIN base b ON ((b.conversa_id = a.conversa_id)))
             LEFT JOIN LATERAL _oport_plano(b.plano_escolhido, b.forma_pagamento, b.cluster, b.segmento) pv(plano, valor) ON (true))
        ), regra_v AS (
         SELECT config_oportunidades.codigo, config_oportunidades.pontos, config_oportunidades.ordem, config_oportunidades.parametros AS p
           FROM config_oportunidades
          WHERE config_oportunidades.ativo AND config_oportunidades.codigo = ANY (ARRAY['O6'::text, 'O7'::text, 'O8'::text, 'O9'::text])
        ), vbase AS (
         SELECT v.id AS venda_id, v.status, v.cliente_nome, v.cidade, v.motivo_saida, v.interesse_futuro_em, v.comissao_prevista,
            v.valor_mensal, v.instalacao_agendada_para, v.instalacao_turno, v.agendamento_registrado_em, v.dfv_hp_livre, v.conferencia_motivo,
            COALESCE(pl.nome_curto, pl.nome) AS plano_nome,
            c.id AS conversa_id, c.chatwoot_conversation_id, c.telefone,
            COALESCE(NULLIF(split_part(btrim(v.cliente_nome), ' '::text, 1), ''::text), 'tudo bem'::text) AS primeiro_nome,
            mari_cadencia_nome(c.*) AS nome_template,
            (c.ultima_msg_lead_at + ((cfg_1.janela_h)::double precision * '01:00:00'::interval)) AS janela_fecha_em,
            CASE WHEN v.interesse_futuro_em IS NOT NULL THEN 'Interesse futuro (com data)'::text ELSE v.motivo_saida END AS chave_motivo,
            COALESCE(( SELECT max(e.criado_em) FROM eventos_venda e
                  WHERE e.venda_id = v.id AND e.tipo = 'status'::text AND (e.detalhe ->> 'para'::text) = 'saida'::text), v.criado_em) AS saida_em,
            ic.resposta AS confirmacao
           FROM vendas v
             JOIN LATERAL ( SELECT c2.* FROM mari_conversas c2
                  WHERE c2.venda_id = v.id AND c2.canal = 'whatsapp'::text AND COALESCE(c2.chatwoot_conversation_id, ''::text) <> ''::text
                  ORDER BY c2.updated_at DESC NULLS LAST LIMIT 1) c ON true
             LEFT JOIN config_planos pl ON pl.id = v.plano_id
             LEFT JOIN v_instalacao_confirmacao ic ON ic.venda_id = v.id
             CROSS JOIN cfg cfg_1
          WHERE cfg_1.ligado AND (v.status = ANY (ARRAY['saida'::text, '2_aguardando_instalacao'::text]))
            AND NOT COALESCE(c.nao_contatar, false) AND COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text
            AND COALESCE(( SELECT f.n FROM feitas_hoje f WHERE f.conversa_id = c.id), (0)::bigint) < cfg_1.max_conv
        ), vbate AS (
         SELECT b.*, r.codigo, r.pontos, r.ordem, x.volta_em
           FROM vbase b
             CROSS JOIN regra_v r
             CROSS JOIN LATERAL ( SELECT CASE WHEN r.codigo = 'O6'::text THEN
                    CASE WHEN b.interesse_futuro_em IS NOT NULL THEN ((b.interesse_futuro_em)::timestamp without time zone + '09:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text
                         ELSE b.saida_em + ((((r.p -> 'dias'::text) ->> b.chave_motivo))::numeric)::double precision * '1 day'::interval END
                    ELSE NULL::timestamp with time zone END AS volta_em) x
             CROSS JOIN cfg cfg_1
          WHERE CASE r.codigo
                WHEN 'O6'::text THEN b.status = 'saida'::text
                  AND ((r.p -> 'dias'::text) ? b.chave_motivo)
                  AND NOT (COALESCE(b.motivo_saida, ''::text) IN ( SELECT jsonb_array_elements_text(COALESCE(r.p -> 'nunca'::text, '[]'::jsonb))))
                  AND COALESCE(b.conferencia_motivo, ''::text) <> ALL (ARRAY['ja_cliente_nio'::text, 'suspeita_fraude'::text, 'ja_tem_pedido_nio'::text])
                  AND (b.dfv_hp_livre IS NULL OR b.dfv_hp_livre > 0)   -- 0 HP livre = endereço já ocupado na Nio
                  AND x.volta_em IS NOT NULL AND now() >= x.volta_em
                  AND now() < x.volta_em + ((COALESCE(((r.p ->> 'max_dias_depois'::text))::numeric, (30)::numeric))::double precision * '1 day'::interval)
                  AND NOT (EXISTS ( SELECT 1 FROM oportunidades_log l WHERE l.conversa_id = b.conversa_id AND l.codigo = 'O6'::text AND l.tipo = 'enviada'::text))
                WHEN 'O7'::text THEN b.status = '2_aguardando_instalacao'::text
                  AND ((b.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text))::date = (cfg_1.hoje + 1)
                  AND ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::time without time zone >= COALESCE(((r.p ->> 'hora'::text))::time without time zone, '20:00:00'::time without time zone)
                  AND b.confirmacao IS NULL
                -- O8/O9: só com fatura CONFIRMADA pelo extrato da Nio. O importador do extrato ainda não existe
                -- (v_adimplencia não aplicada) → nunca batem até ele existir (ver config_oportunidades.descricao).
                ELSE false
                END
        ), vagg AS (
         SELECT vbate.conversa_id,
            (array_agg(vbate.codigo ORDER BY vbate.pontos DESC, vbate.ordem))[1] AS codigo,
            array_agg(vbate.codigo ORDER BY vbate.pontos DESC, vbate.ordem) AS regras,
            (sum(vbate.pontos))::integer AS pontos
           FROM vbate GROUP BY vbate.conversa_id
        ), vlinha AS (
         SELECT a.conversa_id, a.codigo, a.regras, a.pontos,
            b.cliente_nome AS nome, b.primeiro_nome, b.nome_template, b.cidade,
            CASE WHEN b.status = 'saida'::text THEN 'saida'::text ELSE 'instalacao'::text END AS coluna,
            CASE WHEN a.codigo = 'O6'::text THEN b.saida_em ELSE COALESCE(b.agendamento_registrado_em, b.instalacao_agendada_para) END AS parado_desde,
            b.janela_fecha_em, b.chatwoot_conversation_id,
            NULL::bigint AS itens_validados, NULL::bigint AS itens_total, b.telefone,
            b.plano_nome AS plano, b.valor_mensal AS valor_mes,
            CASE WHEN a.codigo <> 'O6'::text THEN 'ligar'::text
                 WHEN b.janela_fecha_em > now() THEN 'livre'::text
                 WHEN (EXISTS ( SELECT 1 FROM tpl)) THEN 'template'::text
                 ELSE 'ligar'::text END AS canal,
            ( SELECT t.nome FROM tpl t) AS template,
            CASE a.codigo
                WHEN 'O6'::text THEN ((('Saída há '::text || _oport_dur((now() - b.saida_em))) || ' · '::text) || lower(COALESCE(b.chave_motivo, 'sem motivo'::text)))
                  || COALESCE(((' · R$ '::text || _oport_reais(b.comissao_prevista)) || ' de comissão se voltar'::text), ''::text)
                WHEN 'O7'::text THEN (('Instala amanhã ('::text || CASE WHEN COALESCE(b.instalacao_turno, CASE WHEN EXTRACT(hour FROM (b.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)) >= 12::numeric THEN 'tarde'::text ELSE 'manha'::text END) = 'tarde'::text THEN '13–17h'::text ELSE '8–12h'::text END) || ') e não confirmou a visita · ligar hoje'::text)
                  || COALESCE(((' · R$ '::text || _oport_reais(b.comissao_prevista)) || ' de comissão em jogo'::text), ''::text)
                ELSE NULL::text
            END AS motivo
           FROM vagg a
             JOIN LATERAL ( SELECT vb.* FROM vbate vb WHERE vb.conversa_id = a.conversa_id AND vb.codigo = a.codigo LIMIT 1) b ON true
        ), todas AS (
         SELECT * FROM linha
        UNION ALL
         SELECT * FROM vlinha
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
            row_number() OVER (ORDER BY l.pontos DESC, l.janela_fecha_em, l.parado_desde) AS n
           FROM todas l
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
              WHERE (x.chave = ('op_'::text || n.codigo))), jsonb_build_object('nome', n.primeiro_nome, 'cidade', n.cidade, 'plano', n.plano, 'valor', _oport_reais(n.valor_mes), 'agente', COALESCE(( SELECT eu.nome
               FROM eu), 'o time'::text)))
            WHEN 'template'::text THEN mari_render_template(n.template, jsonb_build_array(n.nome_template, COALESCE(( SELECT eu.nome
               FROM eu), 'o time'::text)))
            ELSE NULL::text
        END AS texto_sugerido,
    n.n AS ordem,
    n.telefone
   FROM numerada n,
    cfg
  WHERE ((n.n)::numeric <= GREATEST(((cfg.max_dia)::numeric - COALESCE(( SELECT sum(f.n) AS sum
           FROM feitas_hoje f), (0)::numeric)), (0)::numeric));

