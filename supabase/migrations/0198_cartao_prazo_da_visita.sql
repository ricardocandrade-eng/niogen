-- NIOGEN | supabase/migrations/0198_cartao_prazo_da_visita.sql | 14/11/2026 — Claude Code (Opus 5.5)
-- Venda do Ivon (14/11): a Consulta OS mostra "Aguardando Pagamento" com "Agendamento Realizado" (16/11 13h–18h). O Rogério
-- confirmou que é assim: a Nio agenda mesmo sem o cartão, mas sem o cadastro do cartão a instalação NÃO acontece (Ricardo).
-- O prazo do cartão passa a ser o que vier primeiro: 48 h da biometria aprovada OU a data da visita.
--   cadência CARTAO2: lembrete em 24 h ou na véspera da visita (o que vier primeiro, nunca antes de 2 h do aviso);
--   v_jornada_base: véspera sem cartão = hoje · dia da visita sem cartão = agora · visita que passou sem cartão = agora (reagendar);
--   texto do lembrete e ajuda do status aguarda_cartao dizem que sem o cadastro não há instalação.
-- A confirmação da instalação (C2) e a véspera (C3) já esperavam o cartão (0194): não mudam.

begin;
set local lock_timeout = '8s';

update public.config_mari_textos set atualizado_em = now(), texto =
'Oi, {nome}! Passando para lembrar do cadastro do cartão no link que a Nio te mandou 😊 É ele que confirma a visita do técnico em {dia}, {periodo}: sem o cadastro, a Nio não consegue fazer a instalação. Se não achou a mensagem (vale olhar o spam) ou se teve alguma dificuldade, me conta que eu te ajudo.'
 where chave = 'mari_cartao_lembrete';
update public.config_lead set ajuda =
'Biometria aprovada e pagamento no cartão: a Nio mandou o link para o cliente cadastrar o cartão. A Nio agenda a visita mesmo assim, mas SEM o cadastro NÃO instala. A Mari avisa na hora e lembra em 24 h ou na véspera da visita; véspera sem cartão = fale com o cliente; dia da visita sem cartão = ligue já. Sai daqui sozinho quando a Consulta OS deixa de mostrar "Aguardando Pagamento".'
 where parceiro_id = 'dharma' and tipo = 'status' and codigo = 'aguarda_cartao';

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
  v_inst   boolean;
  v_volta  timestamptz;   -- 0196   -- 0114: venda com instalação agendada (aviso/lembrete são da venda, não da conversa)
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
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
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
    if v_inst and not coalesce(c.nao_contatar, false) and not (c.canal = 'whatsapp' and c.telefone like '5500000000%') then
      v_bloq := null;
    end if;
    if c.status = 'handoff_realizado' or v_inst then
      -- ── venda remota (05/11): biometria pendente e instalação agendada ──
      if v_bloq is not null then continue; end if;
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em, v.forma_pagamento, v.biometria_validada_em,
             exists (select 1 from public.os_andamento oa where oa.venda_id = v.id and oa.estado is not null
                       and oa.estado <> 'aguardando_pagamento' and oa.mudou_em > v.biometria_validada_em) as cartao_ok,
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
          while not public.mari_dia_permitido(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
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
          while not public.mari_dia_permitido(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          vis_ini := public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade);
          v_passo := 'VESPERA'; v_at := vis_ini;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), to_char(v_dia, 'DD/MM'),
                                        case v_turno when 'tarde' then 'tarde' else 'manhã' end);
          v_tpl := 'nio_lembrete_instalacao';
          if p_agora < v_at then v_bloq := 'aguardando a véspera da instalação';
          -- 0114: o texto diz "é amanhã" — nunca sai no próprio dia da instalação.
          elsif (p_agora at time zone 'America/Sao_Paulo')::date >= v_dia then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
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
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum' then
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
          f_base := coalesce((select max(t.created_at) from public.mari_turnos t
                               where t.conversa_id = c.id and t.papel = 'mari' and coalesce(t.tags ->> 'cadencia', '') = ''), M);
          fats := array[f_base + interval '15 minutes', f_base + interval '1 hour', f_base + interval '3 hours',
                        f_base + interval '6 hours', L + interval '20 hours'];
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
       and exists (select 1 from public.oportunidades_log ol
                    where ol.conversa_id = c.id and ol.tipo = 'enviada'
                      and ol.criado_em > coalesce(L, '-infinity'::timestamptz)
                      and (ol.criado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date) then
      v_bloq := 'o time falou com o cliente hoje (🔥 oportunidade): o toque vai para o próximo dia útil';
      v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
    end if;
    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      if v_exc is null and not public.mari_no_horario(p_agora, c.cidade) then
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
                            WHEN vd.etapa = 3 THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em) < (now() - '02:00:00'::interval) THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Crédito aprovado · no portal: forma de pagamento, agenda e OS · gravar a OS e a data'::text, 'os', COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em))
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
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1 FROM os_andamento oa WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date < cfg.hoje THEN jsonb_build_array('agora', ('Visita de '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' não aconteceu: cartão não cadastrado · falar com o cliente e reagendar no portal'::text, 'cartao', vd.instalacao_agendada_para)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1 FROM os_andamento oa WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date = cfg.hoje THEN jsonb_build_array('agora', 'Visita HOJE e o cartão não foi cadastrado · ligar agora: sem o cadastro no link da Nio não há instalação'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1 FROM os_andamento oa WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND vd.biometria_validada_em < (now() - '48:00:00'::interval) THEN jsonb_build_array('agora', ('Cartão sem cadastro há '::text || _h_txt(vd.biometria_validada_em)) || ' · ligar: sem o cadastro no link da Nio não há instalação'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1 FROM os_andamento oa WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date <= (cfg.hoje + 1) THEN jsonb_build_array('hoje', ('Visita amanhã ('::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ') e o cartão não foi cadastrado · falar com o cliente: sem o cadastro a Nio não instala'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1 FROM os_andamento oa WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) THEN jsonb_build_array('espera', ('Biometria aprovada · esperando o cliente cadastrar o cartão no link da Nio (visita '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' depende disso; a Mari avisou)'::text, 'cartao', vd.biometria_validada_em)
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

notify pgrst, 'reload schema';

commit;
