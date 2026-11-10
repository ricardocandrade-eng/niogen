-- NIOGEN | supabase/migrations/0114_vespera_da_venda_o7_fora_teto.sql | 10/11/2026 ~20h45 — Claude Code (Opus)
-- Ricardo, 10/11 ~20h40 ("Sim, faça os dois"), depois do prompt docs/Prompt_funil_instalacoes_resultado_101126_1645.md:
--   1. mari_cadencia_avaliar: o aviso do agendamento (INSTALACAO) e o lembrete da véspera (VESPERA) passam a ser da VENDA —
--      saem com a conversa ativa ou em handoff, com humano/time atribuído, resolvida ou com pendência aberta (antes só em handoff
--      e sem nenhum desses bloqueios; a Mirian, conversa "ativo" + atribuída + resolvida + pendência, nunca receberia).
--      Só "não contatar" e telefone de teste param. Saem sempre como TEMPLATE (botões Tudo certo/Confirmo · Preciso remarcar),
--      mesmo com a janela aberta, para a resposta preencher "Confirmou?". O lembrete nunca sai no próprio dia ("é amanhã").
--      A regra 0110 (time falou pela 🔥 hoje → sem toque automático no mesmo dia) não vale para eles.
--   2. v_oportunidades: proteção de receita (config_oportunidades.geral.fora_do_teto, padrão O7·O8·O9) fica FORA do teto
--      max_dia; o teto conta só as outras (enviadas/dispensadas hoje com código fora da lista).
update public.config_oportunidades
   set parametros = parametros || '{"fora_do_teto": ["O7", "O8", "O9"]}'::jsonb,
       descricao = descricao || ' · fora_do_teto (0114): regras de proteção de receita que não contam nem obedecem ao max_dia.'
 where codigo = 'geral' and not (parametros ? 'fora_do_teto');

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
  f1_at    timestamptz; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  v_turno  text; v_dia date;
  v_inst   boolean;   -- 0114: venda com instalação agendada (aviso/lembrete são da venda, não da conversa)
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
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em,
             v.instalacao_agendada_para, v.instalacao_turno, v.logradouro, v.numero, v.complemento, v.bairro
        into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.status <> 'saida';
      if not found then continue; end if;

      if v_venda.status = '0_qualificado' and v_venda.biometria_status = 'pendente' and v_venda.biometria_link_enviado_em is not null then
        if c.bio_lembrete_em is null or c.bio_lembrete_em < v_venda.biometria_link_enviado_em then
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
      elsif v_venda.status = '2_aguardando_instalacao' and v_venda.instalacao_agendada_para > p_agora then
        v_dia := (v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date;
        v_turno := coalesce(v_venda.instalacao_turno,
                            case when extract(hour from v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12
                                 then 'tarde' else 'manha' end);
        if c.instalacao_avisada_para is distinct from v_venda.instalacao_agendada_para then
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
        v_txt := public.mari_render_template(v_tpl, v_params);
        -- 0114: aviso e lembrete da instalação saem SEMPRE como template (com os botões Confirmo/Tudo certo · Preciso remarcar),
        -- mesmo com a janela aberta — a resposta ao botão é o que preenche "Confirmou?" (0112).
        v_acao := 'template'; v_cat := 'UTILITY';
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
          f1_at := M + interval '60 minutes';
          if c.cadencia_retorno_em is not null or not public.mari_no_horario(f1_at, c.cidade) or f1_at >= L + interval '20 hours' then
            f1_at := null;
          end if;
          -- 0050 (Ricardo, 06/11): F2 no MESMO dia, ~4 h depois da última fala da Mari (cutucada discreta, dentro do
          -- horário). Caiu fora do horário → próximo horário, se ainda dentro da janela; senão a regra antiga (fim do
          -- horário anterior às 20 h do lead). 0102: sem teto 2/dia · 15/mês (config nula).
          -- 0053: a base do F2 é a última fala REAL da Mari (sem tags.cadencia) — o turno do próprio F1 carimba
          -- ultima_msg_mari_at (gatilho da 0018) e empurrava o F2 para ~4 h depois do F1.
          f2_at := coalesce((select max(t.created_at) from public.mari_turnos t
                              where t.conversa_id = c.id and t.papel = 'mari'
                                and coalesce(t.tags ->> 'cadencia', '') = ''), M) + interval '4 hours';
          f2_ate := L + interval '23 hours';
          if c.cadencia_retorno_em is not null then
            f2_at := null;
          elsif not public.mari_no_horario(f2_at, c.cidade) then
            f2_at := public.mari_proximo_horario(f2_at, c.cidade);
          end if;
          if c.cadencia_retorno_em is not null then
            null;
          elsif f2_at is null or f2_at >= f2_ate then
            a_ant := public.mari_ultimo_horario(L + interval '20 hours', c.cidade);
            if a_ant is not null and a_ant >= greatest(M, coalesce(c.cadencia_passo_em, M), coalesce(f1_at, M)) + interval '30 minutes' then
              f2_at := a_ant; f2_ate := least(L + interval '23 hours', a_ant + interval '15 minutes');
            else
              f2_at := null;
            end if;
          end if;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          -- 0070 (abertura B2, 08/11): L15 = lembrete leve, UMA vez por conversa, 15 min depois da abertura B2 (ou da resposta
          -- fixa a um botão dela) sem resposta do cliente e sem CEP. Vale só até a hora do F1 (60 min): fora do horário do
          -- contrato não sai e não acumula. É contato ativo (contatos_cliente, 2/dia · 15/mês) como os outros passos.
          l15_at := null; v_ab_em := null; v_ab_tags := null;
          select t.created_at, t.tags into v_ab_em, v_ab_tags
            from public.mari_turnos t
           where t.conversa_id = c.id and t.papel = 'mari' and coalesce(t.tags ->> 'cadencia', '') = ''
           order by t.created_at desc limit 1;
          if coalesce(v_ab_tags ? 'abertura', false) and coalesce(v_ab_tags ->> 'abertura_botao', '') <> 'humano'
             and c.cep is null and M >= L and c.cadencia_retorno_em is null
             and not exists (select 1 from public.mari_turnos t2 where t2.conversa_id = c.id and t2.tags ->> 'cadencia' = 'L15') then
            l15_at := v_ab_em + interval '15 minutes';
          end if;
          seq := array['L15', 'F1', 'F2', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[l15_at, f1_at, f2_at, d3_at, d7_at, d15_at, null];
          validos := array[coalesce(v_ab_em, M) + interval '60 minutes',
                           least(L + interval '20 hours', coalesce(f2_at, 'infinity')), f2_ate, d7_at, d15_at,
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
          if seq[i] in ('L15', 'F1', 'F2') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
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

        if v_passo in ('L15', 'F1', 'F2') then
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
        if v_passo in ('L15', 'F1', 'F2') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        -- 0050 (Ricardo, 06/11): venda já criada NUNCA sai sozinha e não recebe a escada de templates de lead —
        -- só as cutucadas F1/F2 dentro da janela; o resto é do backoffice, pela venda.
        if c.venda_id is not null and v_passo not in ('L15', 'F1', 'F2') then
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
       and v_passo not in ('INSTALACAO', 'VESPERA')   -- 0114: aviso/lembrete da instalação não são toque de venda
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

create or replace view public.v_oportunidades with (security_invoker = true) as
WITH cfg AS (
         SELECT COALESCE(((g.p ->> 'ligado'::text))::boolean, true) AS ligado,
            COALESCE(((g.p ->> 'max_dia'::text))::integer, 5) AS max_dia,
            COALESCE(((g.p ->> 'max_por_conversa_dia'::text))::integer, 1) AS max_conv,
            COALESCE(((g.p ->> 'max_parado_dias'::text))::numeric, (7)::numeric) AS max_dias,
            COALESCE(((g.p ->> 'janela_horas'::text))::numeric, (23)::numeric) AS janela_h,
            (g.p ->> 'template'::text) AS tpl,
            COALESCE((g.p -> 'fora_do_teto'::text), '["O7", "O8", "O9"]'::jsonb) AS fora,
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
            row_number() OVER (ORDER BY l.pontos DESC, l.janela_fecha_em, l.parado_desde) AS n,
            row_number() OVER (PARTITION BY (l.codigo IN ( SELECT jsonb_array_elements_text(cfg_n.fora) AS x)) ORDER BY l.pontos DESC, l.janela_fecha_em, l.parado_desde) AS nc
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
  WHERE ((n.codigo IN ( SELECT jsonb_array_elements_text(cfg.fora) AS x))
     OR ((n.nc)::numeric <= GREATEST(((cfg.max_dia)::numeric - COALESCE(( SELECT (count(*))::numeric AS count
           FROM oportunidades_log lq
          WHERE ((lq.tipo = ANY (ARRAY['enviada'::text, 'dispensada'::text]))
            AND (((lq.criado_em AT TIME ZONE 'America/Sao_Paulo'::text))::date = cfg.hoje)
            AND NOT (COALESCE(lq.codigo, ''::text) IN ( SELECT jsonb_array_elements_text(cfg.fora) AS x)))), (0)::numeric)), (0)::numeric)));
