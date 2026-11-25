-- NIOGEN | supabase/migrations/0385_cadencia_para_no_provavel_bloqueio.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 24/11: "Para a cadência para quem estiver com provável bloqueio" (depois do selo 📵 Provável bloqueio na conversa).
-- O que muda:
--   1. public._provavel_bloqueio(conversa, agora): a mesma regra do selo da tela (docs/assets/conversa.js, bloqueioDe) — depois da
--      última fala do cliente em mari_msg_cw, 2+ mensagens nossas paradas em "enviada" há mais de 24 h e nenhuma entregue/lida, ou
--      2+ que falharam. Mensagem sem status (antes de 25/11 01h UTC) interrompe a contagem: sem dado, sem bloqueio. Só lê.
--   2. mari_cadencia_avaliar: com provável bloqueio, o toque automático (D3/D7/D15, F1–F5, L15…) fica bloqueado com o motivo
--      ("provável bloqueio: … — ligue"), que aparece na trilha dos lembretes. Volta sozinho quando uma mensagem é entregue ou o cliente
--      fala. Avisos da venda (BIO*, CARTAO*, INSTALACAO, VESPERA) e o RETORNO pedido pelo cliente seguem (regra de ouro 6).
--      Corpo = o de produção em 24/11 (pg_get_functiondef) + o bloco 0385.
-- Regra 20: (1) nenhuma situação nova — é um motivo de bloqueio, como os outros; (2) não fica em silêncio: o selo diz "ligue" e o
-- motivo aparece na ficha; (3) não grava estado; (4) fonte = os tiques do Chatwoot (mari_msg_cw); (5) sem número novo para conferir.
-- Desempenho: 1 leitura indexada (mari_msg_cw_conversa, até 30 linhas) por conversa que chegaria a tocar — medido no Diário.
begin;

create or replace function public._provavel_bloqueio(p_conversa uuid, p_agora timestamptz default now())
returns text language sql stable set search_path = public as $$
  with ult as (
    select x.direcao, x.status, x.criado_em, row_number() over (order by x.criado_em desc) rn
      from (select m.direcao, m.status, m.criado_em from public.mari_msg_cw m
             where m.conversa_id = p_conversa order by m.criado_em desc limit 30) x
  ), corte as (
    select coalesce(min(rn) filter (where direcao is distinct from 'out' or status is null), 1000000) c from ult
  ), nossas as (
    select u.* from ult u, corte where u.rn < corte.c
  )
  select case
    when count(*) < 2 or coalesce(bool_or(status in ('entregue', 'lida')), false) then null
    when count(*) filter (where status = 'falhou') >= 2 then
      'provável bloqueio: ' || count(*) filter (where status = 'falhou') || ' mensagens recusadas pelo WhatsApp desde '
      || to_char(min(criado_em) filter (where status = 'falhou') at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' — ligue (📵 na conversa)'
    when count(*) filter (where status = 'enviada' and criado_em < p_agora - interval '24 hours') >= 2 then
      'provável bloqueio: ' || count(*) filter (where status = 'enviada' and criado_em < p_agora - interval '24 hours')
      || ' mensagens paradas em ✓ desde '
      || to_char(min(criado_em) filter (where status = 'enviada' and criado_em < p_agora - interval '24 hours') at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
      || ' — ligue (📵 na conversa)'
  end
  from nossas;
$$;
revoke all on function public._provavel_bloqueio(uuid, timestamptz) from public, anon;
grant execute on function public._provavel_bloqueio(uuid, timestamptz) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.mari_cadencia_avaliar(p_agora timestamp with time zone DEFAULT now(), p_conversa uuid DEFAULT NULL::uuid)
 RETURNS TABLE(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text, passo_atual text, passo_em timestamp with time zone, proximo_passo text, proximo_em timestamp with time zone, pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text, janela_aberta boolean, janela_fecha_em timestamp with time zone, toques_hoje integer, toques_mes integer, ligar_sugerido boolean, venda_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  v_tq     record;
  v_teto   record;   -- 0102: config_regras.contato_teto_dia/_mes (nulo = sem teto)
  L        timestamptz;   -- última msg do lead
  M        timestamptz;   -- última msg da Mari
  B        timestamptz;   -- base dos D (lead, retorno ou 1º contato)
  f1_at    timestamptz; f_base timestamptz; f_ant timestamptz; fats timestamptz[]; fval timestamptz[]; k int; k2 int; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  v_turno  text; v_dia date;
  v_dom    boolean;   -- 0209: véspera no domingo/feriado (exceção do Ricardo, 15/11)
  v_inst   boolean;
  v_bio    boolean;   -- 0253 (D9): venda com biometria pendente e link já enviado — o lembrete é aviso da venda
  v_volta  timestamptz;   -- 0196   -- 0114: venda com instalação agendada (aviso/lembrete são da venda, não da conversa)
  v_hum    timestamptz;   -- 0274: última fala do time
  v_aviso_h numeric := coalesce(nullif(public._bo_cfg('aviso_venda_espera_horas', '2'::jsonb) #>> '{}', '')::numeric, 2);
  v_pausa  text := nullif(public._bo_cfg('retomada_pausa_regex', 'null'::jsonb) #>> '{}', '');
  v_vtpl   text; v_vpar jsonb;   -- 0381: variante do D3 pela etapa
  l15_at   timestamptz; v_ab_em timestamptz; v_ab_tags jsonb;   -- 0070: lembrete leve da abertura B2
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
  select * into v_teto from public.contato_teto();
  for c in
    select * from public.mari_conversas mc
     where (p_conversa is null or mc.id = p_conversa)
       and mc.canal in ('teste', 'whatsapp')
       and (mc.status = 'ativo'
            or (mc.status = 'handoff_realizado' and mc.venda_id is not null))   -- biometria pendente / instalação agendada
     order by mc.updated_at desc
  loop
    v_passo := null; v_at := null; v_bloq := null; v_acao := null; v_tpl := null; v_cat := null;
    v_params := null; v_txt := null; v_exc := null; v_pode := false; v_lig := false;
    L := c.ultima_msg_lead_at; M := c.ultima_msg_mari_at;
    v_janela := L is not null and p_agora < L + interval '23 hours';
    select * into v_tq from public.mari_toques(c.telefone, p_agora);
    -- ── paradas absolutas ──
    if c.nao_contatar then v_bloq := 'cliente pediu para não ser contatado';
    -- 0274: a Retomada (D3 → Ligar → D7 → D15) sai pela fila do NIOGEN, não pela escada do n8n
    elsif c.retomada_desde is not null and c.retomada_fim_em is null then v_bloq := 'Retomada pelo NIOGEN (D3 → Ligar → D7 → D15)';
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
    -- 0227 (D10): ⏸ Aguardar pausa a cadência até a data (se o cliente escrever, a Mari responde normalmente)
    -- 0379 (agenda de retornos): a espera não segura o RETORNO combinado que chegou a hora (a Mari chama; a espera segue até 2 h depois)
    elsif c.espera_ate is not null and c.espera_ate > p_agora
          and not (c.agendamento_retorno is not null and c.agendamento_retorno <= p_agora
                   and c.agendamento_retorno > coalesce(c.ultima_msg_lead_at, c.created_at)
                   and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno)) then
      v_bloq := 'em espera (⏸) até ' || to_char(c.espera_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    -- 0227 (D5): destino de saída pela regra (CEP fora da área, sem cobertura, já é cliente Nio) não recebe toque
    elsif c.funil_destino in ('fora_area', 'sem_cobertura', 'ja_cliente_nio') then
      v_bloq := 'destino de saída pela regra (' || c.funil_destino || ')';
    elsif c.canal = 'whatsapp' and c.telefone like '5500000000%' then v_bloq := 'telefone de teste';
    -- 0064 (08/11): venda "Em espera" (pendência com terceiro aberta) pausa toda a cadência até a pendência ser encerrada.
    elsif c.venda_id is not null and exists (select 1 from public.venda_pendencias vp
                                              where vp.venda_id = c.venda_id and vp.encerrada_em is null) then
      v_bloq := 'venda em espera (pendência com terceiro)';
    end if;
    -- 0114 (Ricardo, 10/11 ~20h40 "Sim, faça os dois"): o aviso do agendamento (C2) e o lembrete da véspera (C3) são da VENDA —
    -- saem com a conversa em qualquer estado (ativa ou em handoff), com humano/time atribuído, resolvida no Chatwoot ou com
    -- pendência aberta. Só "não contatar" e telefone de teste param.
    v_inst := c.venda_id is not null and exists (select 1 from public.vendas vi where vi.id = c.venda_id
                and vi.status = '2_aguardando_instalacao' and vi.instalacao_agendada_para > p_agora);
    -- 0253 (D9, regra de ouro 6: "aviso da venda sai sempre; só Saída e Não contatar barram"): o lembrete da biometria também.
    -- Antes, com o time atribuído (o normal depois do handoff de venda), o BIO1 ficava barrado e nunca saía.
    v_bio := c.venda_id is not null and exists (select 1 from public.vendas vb where vb.id = c.venda_id
               and vb.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
               and vb.biometria_status = 'pendente' and vb.biometria_link_enviado_em is not null);
    if (v_inst or v_bio) and not coalesce(c.nao_contatar, false) and not (c.canal = 'whatsapp' and c.telefone like '5500000000%') then
      v_bloq := null;
    end if;
    if c.status = 'handoff_realizado' or v_inst or v_bio then
      -- ── venda remota (05/11): biometria pendente e instalação agendada ──
      if v_bloq is not null then continue; end if;
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em, v.forma_pagamento, v.biometria_validada_em,
             exists (select 1 from public.os_andamento oa where oa.venda_id = v.id and oa.estado is not null
                       and oa.pedido = btrim(v.nio_pedido)   -- 0278: só a OS atual (a OS cancelada de um pedido reemitido não conta)
                       and oa.estado not in ('aguardando_pagamento', 'rascunho', 'cancelada', 'cancelando', 'reprovada')
                       and oa.mudou_em > v.biometria_validada_em) as cartao_ok,
             v.nio_pedido,
             (select oa.estado from public.os_andamento oa where oa.pedido = btrim(v.nio_pedido)
                and oa.estado in ('rascunho', 'cancelada', 'cancelando', 'reprovada') limit 1) as os_parada,
             v.instalacao_agendada_para, v.instalacao_turno, v.logradouro, v.numero, v.complemento, v.bairro
        into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.status <> 'saida';
      if not found then continue; end if;
      -- 0191: a biometria vem DEPOIS da OS — os lembretes valem também com a venda já contada (Ativação/Agenda).
      if v_venda.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao') and v_venda.biometria_status = 'pendente' and v_venda.biometria_link_enviado_em is not null then
        select q.fim into v_volta from public.biometria_quedas q
         where q.fim is not null and q.fim > p_agora - interval '48 hours' and q.inicio > v_venda.biometria_link_enviado_em - interval '15 days'
           and v_venda.biometria_link_enviado_em < q.fim
         order by q.fim desc limit 1;
        if v_volta is not null and (c.bio_volta_em is null or c.bio_volta_em < v_volta) then
          -- 0196: a biometria da Nio voltou depois de uma queda e este cliente ficou esperando: a Mari avisa (só na janela de 24 h).
          v_passo := 'BIOVOLTA'; v_at := v_volta;
          select replace(t.texto, '{nome}', public.mari_cadencia_nome(c)) into v_txt from public.config_mari_textos t where t.chave = 'mari_bio_voltou';
          v_acao := 'texto'; v_tpl := null;
          if not v_janela then v_bloq := 'janela de 24 h fechada: o time fala com o cliente (Live)'; end if;
        elsif c.bio_lembrete_em is null or c.bio_lembrete_em < v_venda.biometria_link_enviado_em then
          -- BIO1: D+1 do link, uma vez só. 0032: o link é da Nio (WhatsApp + e-mail, na hora do pedido) — a contagem parte
          -- da hora do pedido e o lembrete é o C1 v2 (sem botão de link): lembra que a Nio mandou, conferir o spam, ajuda por aqui.
          v_passo := 'BIO1';
          v_at := public.mari_proximo_horario(v_venda.biometria_link_enviado_em + interval '1 day', c.cidade);
          v_tpl := 'nio_lembrete_biometria_v2';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
          if v_janela then
            v_acao := 'texto'; v_tpl := null;   -- texto livre (janela de 24 h): o mesmo texto do C1 v2
          else
            v_acao := 'template'; v_cat := 'UTILITY';
          end if;
          if p_agora < v_at then v_bloq := 'aguardando o D+1 do link da biometria (hora do pedido)';
          end if;
        else
          -- BIO3: D+3 sem biometria → o humano liga. Nunca automático.
          v_passo := 'BIO3'; v_acao := 'ligar';
          v_at := v_venda.biometria_link_enviado_em + interval '3 days';
          v_lig := p_agora >= v_at;
          v_bloq := case when p_agora < v_at then 'aguardando o D+3 do link da biometria (hora do pedido)'
                         else 'D+3 sem biometria: o nosso time liga para o cliente (nunca automático)' end;
        end if;
      elsif v_venda.status = '2_aguardando_instalacao' and v_venda.instalacao_agendada_para > p_agora
            and v_venda.biometria_status = 'validada' then   -- 0191: confirmação da instalação só depois da biometria aprovada
        v_dia := (v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date;
        v_turno := coalesce(v_venda.instalacao_turno,
                            case when extract(hour from v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12
                                 then 'tarde' else 'manha' end);
        if v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_avisado_em is null then
          -- 0191 (Ricardo, 14/11): cartão — biometria aprovada, a Nio manda o link do cadastro do cartão. A Mari avisa com jeitinho.
          v_passo := 'CARTAO'; v_at := p_agora;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_aviso';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_lembrete_em is null then
          -- 0191: 24 h sem o cadastro do cartão → um lembrete gentil. 48 h → o time liga (v_jornada / Live).
          v_passo := 'CARTAO2';
          -- 0198 (Ricardo/Rogério, 14/11): a Nio agenda mesmo sem o cartão, mas sem o cadastro NÃO instala — o lembrete sai
          -- em 24 h ou na véspera da visita, o que vier primeiro (nunca antes de 2 h do aviso).
          vis_dia := v_dia - 1;
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          v_at := greatest(c.cartao_avisado_em + interval '2 hours',
                    least(public.mari_proximo_horario(c.cartao_avisado_em + interval '24 hours', c.cidade),
                          public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade)));
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_lembrete';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
          if p_agora < v_at then v_bloq := 'aguardando o lembrete do cartão (24 h ou a véspera da visita)'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok then
          continue;   -- 0191: lembrete já saiu; esperando o cadastro do cartão (48 h → o time liga)
        elsif c.instalacao_avisada_para is distinct from v_venda.instalacao_agendada_para then
          -- C2: assim que agendar (ou reagendar).
          v_passo := 'INSTALACAO'; v_at := p_agora;
          v_params := jsonb_build_array(
            public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end,
            concat_ws(', ', nullif(btrim(v_venda.logradouro), ''), nullif(btrim(v_venda.numero), ''),
                      nullif(btrim(v_venda.complemento), ''), nullif(btrim(v_venda.bairro), '')));
          v_tpl := 'nio_instalacao_agendada';
        elsif c.instalacao_lembrada_para is distinct from v_venda.instalacao_agendada_para then
          -- C3: véspera (dia permitido anterior).
          vis_dia := v_dia - 1;
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          -- 0209 (Ricardo, 15/11: "nesse caso, pode abrir uma exceção e enviar no domingo"): se o aviso do agendamento (C2) saiu
          -- no dia da véspera permitida ou depois (ex.: instalação na segunda agendada no sábado à tarde), a véspera não teria dia
          -- nenhum — então ela sai no dia anterior à instalação mesmo sendo domingo/feriado, das 10h às 16h.
          v_dom := c.instalacao_avisada_em is not null
                   and vis_dia <= (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date
                   and (v_dia - 1) > (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date;
          if v_dom then vis_dia := v_dia - 1; end if;
          vis_ini := case when v_dom then (vis_dia::timestamp + time '10:00') at time zone 'America/Sao_Paulo'
                          else public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade) end;
          v_passo := 'VESPERA'; v_at := vis_ini;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), to_char(v_dia, 'DD/MM'),
                                        case v_turno when 'tarde' then 'tarde' else 'manhã' end);
          v_tpl := 'nio_lembrete_instalacao';
          if p_agora < v_at then v_bloq := 'aguardando a véspera da instalação';
          -- 0114: o texto diz "é amanhã" — nunca sai no próprio dia da instalação.
          elsif (p_agora at time zone 'America/Sao_Paulo')::date >= v_dia then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
          elsif v_dom and p_agora >= (vis_dia::timestamp + time '16:00') at time zone 'America/Sao_Paulo' then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif v_dom then v_exc := 'véspera no domingo/feriado: sem outro dia antes da instalação';   -- passa pela regra do horário (só 10h–16h, acima)
          end if;
        else
          continue;
        end if;
        if v_passo in ('INSTALACAO', 'VESPERA') then
        v_txt := public.mari_render_template(v_tpl, v_params);
        -- 0114: aviso e lembrete da instalação saem SEMPRE como template (com os botões Confirmo/Tudo certo · Preciso remarcar),
        -- mesmo com a janela aberta — a resposta ao botão é o que preenche "Confirmou?" (0112).
        v_acao := 'template'; v_cat := 'UTILITY';
        end if;
      else
        continue;   -- nada a fazer nesta conversa em handoff
      end if;
    elsif v_bloq is null and c.status = 'ativo' then
      -- 0050 (Ricardo, 06/11): venda em Saída não recebe nada da cadência ("Interesse futuro" vira etiqueta no
      -- Chatwoot, 0052; "Sem cobertura" não ganha nada).
      if c.venda_id is not null and exists (select 1 from public.vendas vs where vs.id = c.venda_id and vs.status = 'saida') then
        continue;
      end if;
      -- ── retorno pedido pelo cliente: prioridade, pode sair fora do horário ──
      if c.agendamento_retorno is not null
         and c.agendamento_retorno > coalesce(L, c.created_at)
         and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno) then
        v_passo := 'RETORNO'; v_at := c.agendamento_retorno; v_exc := 'pedido do cliente';
        if v_janela then
          v_acao := 'texto';
          v_txt := 'Oi' || case when public.mari_cadencia_nome(c) <> 'tudo bem' then ', ' || public.mari_cadencia_nome(c) else '' end
                   || '! Como combinamos, estou passando pra gente retomar. Quer seguir de onde paramos? 😊';
        else
          v_acao := 'template'; v_tpl := 'nio_retomada_lead_d3'; v_cat := 'MARKETING';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if p_agora < v_at then v_bloq := 'retorno agendado pelo cliente'; end if;
      elsif c.processando_ate is not null and c.processando_ate > p_agora then
        v_bloq := 'Mari respondendo agora';
      elsif L is null and c.origem not in ('meta_ads', 'site', 'indicacao') then
        continue;   -- sem mensagem do lead e sem origem de formulário: não há escada
      -- 0199 (trava A): a resposta do TIME também é resposta. Antes, o time respondia, devolvia para a Mari e a escada nunca
      -- recomeçava (M < L para sempre) — Leandro e Lucia Dias parados em silêncio.
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum'
            and not exists (select 1 from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano' and th.created_at >= L) then
        v_bloq := 'aguardando a Mari responder';
      else
        -- ── a escada ──
        B := greatest(coalesce(L, '-infinity'::timestamptz), coalesce(c.cadencia_retorno_em, '-infinity'::timestamptz));
        if L is null then
          B := coalesce((select min(cc.em) from public.contatos_cliente cc where cc.conversa_id = c.id and cc.toque = 'P1'),
                        c.cadencia_passo_em, c.created_at);
          seq := array['P1', 'D7', 'D15', 'ENCERRAR'];
          ats := array[c.created_at, B + interval '7 days', B + interval '15 days', null];
          validos := array[B + interval '7 days', B + interval '15 days', 'infinity'::timestamptz, 'infinity'::timestamptz];
        else
          -- 0141 (Ricardo, 12/11): 5 cutucadas na janela de 24 h, em QUALQUER etapa: 15 min, 1 h, 3 h e 6 h depois da última fala
          -- REAL da Mari e a última chamada ~20 h depois da mensagem do cliente. Fora do horário do contrato (seg–sex 9–21, sáb
          -- 10–16, nunca domingo/feriado) vai para a abertura seguinte, com no mínimo 45 min entre duas, se ainda couber na janela
          -- (até L + 23 h); senão é pulada. O cliente respondeu → L muda e a escada recomeça. Substitui L15/F1/F2.
          -- 0199: a última fala real é da Mari OU do time (a cutucada não sai 15 min depois de uma fala velha da Mari
          -- quando o time acabou de responder).
          f_base := coalesce((select max(t.created_at) from public.mari_turnos t
                               where t.conversa_id = c.id and t.papel in ('mari', 'humano') and coalesce(t.tags ->> 'cadencia', '') = ''), M);
          fats := array[f_base + interval '15 minutes', f_base + interval '1 hour', f_base + interval '3 hours',
                        f_base + interval '6 hours', L + interval '20 hours'];
          -- 0274 (caso Kika, Ricardo 18/11): o cliente disse "vou ver / depois te mando" → 24 h sem cutucada (a escada segue no D3)
          if v_pausa is not null and exists (select 1 from public.mari_turnos tl where tl.conversa_id = c.id and tl.papel = 'lead'
                                               and tl.created_at > L - interval '10 minutes' and tl.texto ~* v_pausa) then
            for k in 1..5 loop
              if fats[k] < L + interval '24 hours' then fats[k] := null; end if;
            end loop;
          end if;
          f_ant := null;
          for k in 1..5 loop
            if c.cadencia_retorno_em is not null then fats[k] := null; continue; end if;
            if f_ant is not null and fats[k] < f_ant + interval '45 minutes' then fats[k] := f_ant + interval '45 minutes'; end if;
            if not public.mari_no_horario(fats[k], c.cidade) then fats[k] := public.mari_proximo_horario(fats[k], c.cidade); end if;
            if fats[k] is null or fats[k] >= L + interval '23 hours' then fats[k] := null; else f_ant := fats[k]; end if;
          end loop;
          fval := array[null, null, null, null, null]::timestamptz[];
          for k in 1..5 loop
            fval[k] := L + interval '23 hours';
            if k < 5 then
              for k2 in (k + 1)..5 loop
                if fats[k2] is not null then fval[k] := least(fats[k2], fval[k]); exit; end if;
              end loop;
            end if;
          end loop;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          seq := array['F1', 'F2', 'F3', 'F4', 'F5', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[fats[1], fats[2], fats[3], fats[4], fats[5], d3_at, d7_at, d15_at, null];
          validos := array[fval[1], fval[2], fval[3], fval[4], fval[5], d7_at, d15_at,
                           'infinity'::timestamptz, 'infinity'::timestamptz];
        end if;
        if c.cadencia_passo = 'D15' then
          ats[array_length(seq, 1)] := c.cadencia_passo_em + interval '48 hours';
        end if;
        idx_atual := coalesce(array_position(seq, c.cadencia_passo), 0);
        if c.cadencia_passo = 'F2' and seq[1] = 'P1' then idx_atual := 1; end if;
        alvo := null; prox := null;
        for i in (idx_atual + 1)..array_length(seq, 1) loop
          if ats[i] is null then continue; end if;
          if seq[i] in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
          if ats[i] <= p_agora and p_agora < validos[i] then alvo := i;
          elsif ats[i] > p_agora and prox is null then prox := i;
          end if;
        end loop;
        if alvo is not null then
          v_passo := seq[alvo]; v_at := ats[alvo];
        elsif prox is not null then
          v_passo := seq[prox]; v_at := ats[prox]; v_bloq := 'aguardando';
        else
          continue;
        end if;
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_acao := 'texto'; v_txt := public.mari_cadencia_texto(c, v_passo);
        elsif v_passo = 'ENCERRAR' then
          v_acao := 'encerrar'; v_txt := null;
        else
          v_acao := 'template';
          v_tpl := case v_passo when 'P1' then 'nio_primeiro_contato' when 'D3' then 'nio_retomada_lead_d3'
                                when 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end;
          v_cat := 'MARKETING';
          v_params := case when v_tpl = 'nio_retomada_lead_d3'
                           then jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c))
                           else jsonb_build_array(public.mari_cadencia_nome(c)) end;
          -- 0381 (B4, Parte 4): D3 pela variante da etapa, se o template dela já foi aprovado (igual ao _retomada_tick).
          if v_passo = 'D3' then
            select vr.tpl, vr.params into v_vtpl, v_vpar from public._retomada_variante(c, public.mari_cadencia_nome(c)) vr;
            if v_vtpl is not null and exists (select 1 from public.config_templates_waba w where w.nome = v_vtpl and w.status = 'APPROVED') then
              v_tpl := v_vtpl; v_params := v_vpar;
            end if;
          end if;
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        -- 0050 (Ricardo, 06/11): venda já criada NUNCA sai sozinha e não recebe a escada de templates de lead —
        -- só as cutucadas F1/F2 dentro da janela; o resto é do backoffice, pela venda.
        if c.venda_id is not null and v_passo not in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_bloq := 'venda criada: o backoffice segue pela venda (a cadência não manda D3/D7/D15 nem encerra)';
        end if;
        v_lig := c.cadencia_passo = 'D3' and p_agora >= c.cadencia_passo_em + interval '1 day' and p_agora < B + interval '6 days';
      end if;
    end if;
    if v_passo is null then
      if v_bloq is null then continue; end if;
    end if;
    -- 0110 (Ricardo, 10/11 16h02): o time mandou (ou ligou) pela 🔥 oportunidade HOJE e o cliente ainda não respondeu →
    -- nenhum toque automático no mesmo dia (nunca dois toques num dia: um do humano e um da Mari); o próximo vai para o dia
    -- útil seguinte. Retorno pedido pelo cliente (v_exc) segue valendo. Cliente respondeu → L passa da mensagem e a regra é a de sempre.
    if v_bloq is null and v_passo is not null and v_exc is null and v_acao in ('texto', 'template')
       and v_passo not in ('INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIOVOLTA')   -- 0114: aviso/lembrete da instalação não são toque de venda
       and (exists (select 1 from public.oportunidades_log ol
                    where ol.conversa_id = c.id and ol.tipo = 'enviada'
                      and ol.criado_em > coalesce(L, '-infinity'::timestamptz)
                      and (ol.criado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)
            -- 0226 (M7): vale para QUALQUER fala do time hoje (NIOGEN ou Chatwoot), não só o 🔥
            or exists (select 1 from public.mari_turnos th
                        where th.conversa_id = c.id and th.papel = 'humano'
                          and th.created_at > coalesce(L, '-infinity'::timestamptz)
                          and (th.created_at at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)) then
      v_bloq := 'o time falou com o cliente hoje (🔥 oportunidade): o toque vai para o próximo dia útil';
      v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
    end if;
    -- 0274 (caso Lucas, Ricardo 18/11): o LEMBRETE automático da venda espera 2 h depois de alguém do time falar com o cliente.
    -- O aviso imediato do que o time acabou de fazer (INSTALACAO com os botões, CARTAO com o link) sai na hora, como antes (E1, E2).
    if v_bloq is null and v_passo in ('BIO1', 'BIOVOLTA', 'CARTAO2', 'VESPERA') then
      select max(th.created_at) into v_hum from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano';
      if v_hum is not null and v_hum > p_agora - make_interval(hours => v_aviso_h::int) then
        v_bloq := 'o time falou com o cliente há menos de ' || v_aviso_h::int || ' h: o aviso da venda espera';
        v_at := greatest(v_at, v_hum + make_interval(hours => v_aviso_h::int));
      end if;
    end if;
    -- 0278 (caso de 18/11, troca da forma de pagamento): a Consulta OS diz que a OS da venda foi cancelada ou virou rascunho no portal
    -- (o time está reemitindo o pedido) → nenhum aviso da venda sai com dado velho. Volta sozinho quando a OS nova é gravada
    -- (Reemitir pedido) ou a OS volta a andar. O motivo aparece na trilha dos lembretes da ficha.
    if v_bloq is null and v_passo in ('BIO1', 'BIO3', 'BIOVOLTA', 'CARTAO', 'CARTAO2', 'INSTALACAO', 'VESPERA') then
      -- (v_venda só existe no ramo da venda; estes passos só nascem lá)
      if v_venda.os_parada is not null then
        v_bloq := 'a OS ' || coalesce(v_venda.nio_pedido, '') || ' está '
               || case v_venda.os_parada when 'rascunho' then 'em rascunho (Draft)' when 'cancelando' then 'em cancelamento' else v_venda.os_parada end
               || ' no portal: o aviso da venda espera a OS nova (ficha › Reemitir pedido)';
      end if;
    end if;
    -- 0385 (Ricardo, 24/11: "Para a cadência para quem estiver com provável bloqueio"): mensagens nossas paradas em ✓ há +24 h
    -- (ou recusadas) depois da última fala do cliente → o toque automático não sai; o time liga (selo 📵 na conversa).
    -- Aviso da venda e retorno pedido pelo cliente seguem (regra de ouro 6: só Saída e Não contatar barram).
    if v_bloq is null and v_passo is not null and v_acao is distinct from 'encerrar' and v_acao is distinct from 'ligar'
       and v_passo not in ('RETORNO', 'BIO1', 'BIO3', 'BIOVOLTA', 'CARTAO', 'CARTAO2', 'INSTALACAO', 'VESPERA') then
      v_bloq := public._provavel_bloqueio(c.id, p_agora);
    end if;
    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      -- 0226 (M5): o retorno pedido pelo cliente também respeita a madrugada (só o horário, não as outras regras)
      if (v_exc is null or v_passo = 'RETORNO') and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_teto.dia is not null and v_tq.hoje >= v_teto.dia then
        v_bloq := 'limite do dia (' || v_teto.dia || ' toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_teto.mes is not null and v_tq.mes >= v_teto.mes then
        v_bloq := 'limite do mês (' || v_teto.mes || ' toques)';
      elsif v_acao = 'template' and not exists (select 1 from public.config_templates_waba t where t.nome = v_tpl and t.status = 'APPROVED') then
        v_bloq := 'template não aprovado';
      else
        v_proib := public.mari_texto_proibido(v_txt);
        if v_proib is not null then v_bloq := 'texto reprovado no filtro (' || v_proib || ')'; end if;
      end if;
    end if;
    v_pode := v_passo is not null and v_bloq is null and v_acao is distinct from 'ligar';
    conversa_id := c.id; telefone := c.telefone; canal := c.canal; chatwoot_conversation_id := c.chatwoot_conversation_id;
    status := c.status; etapa := c.etapa; passo_atual := c.cadencia_passo; passo_em := c.cadencia_passo_em;
    proximo_passo := v_passo; proximo_em := v_at; pode_enviar := v_pode; bloqueio := v_bloq; acao := v_acao;
    template := v_tpl; categoria := v_cat; params := v_params; texto := v_txt; excecao := v_exc;
    janela_aberta := v_janela; janela_fecha_em := case when L is not null then L + interval '24 hours' end;
    toques_hoje := v_tq.hoje; toques_mes := v_tq.mes; ligar_sugerido := v_lig; venda_id := c.venda_id;
    return next;
  end loop;
end;
$function$;

commit;
