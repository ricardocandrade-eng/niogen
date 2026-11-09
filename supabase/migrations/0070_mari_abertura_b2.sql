-- NIOGEN | supabase/migrations/0070_mari_abertura_b2.sql | 08/11/2026 — Claude Code (docs/Prompt_mari_abertura_b2_081126_1310.md)
-- Abertura B2 da Mari (escolhida pelo Ricardo em 08/11 13h03): 1ª mensagem fixa com 3 botões, lembrete leve de 15 min e
-- medição antes × depois. Motivo: o lead do anúncio manda "Vi o anúncio…", a Mari pedia CEP + número e o lead sumia.
--   1. config_mari_textos: textos e títulos da abertura (regra 15 — nada fixo no código; o n8n lê por mari_config_interativo()).
--      Sem a chave 'abertura_versao' a B2 fica desligada (o 5b · Motor cai no Claude como antes).
--   2. cadência: passo L15 (lembrete, 1 vez, 15 min depois da abertura ou da resposta a um botão dela, sem resposta e sem CEP;
--      só no horário do contrato, não acumula; contato ativo = conta nos 2/dia e 15/mês, registrado em contatos_cliente).
--      F1/F2 da etapa abertura de quem recebeu a B2 pedem só o CEP (ou rua e bairro). Cadência 24h · D3 · D7 · D15 e
--      templates aprovados: sem mudança.
--   3. v_mari_abertura (security_invoker: só admin/backoffice, pelo RLS de mari_conversas): por dia e versão de abertura.
-- mari_conversas não tem parceiro_id (regra 15: a coluna entra quando a tabela for mexida no núcleo; a Mari é módulo).

insert into public.config_mari_textos (chave, texto) values
('abertura_versao', 'b2_081126'),
-- {nome} = 1º nome do contato, só se parecer nome de pessoa; sem nome a saudação vira "Oi, tudo bem? 😊".
('abertura_corpo', $t$Oi, {nome}, tudo bem? 😊

Aqui é a Mari, da Nio. Fiquei feliz com sua mensagem!

Te mostro rapidinho, sem compromisso nenhum. O que você prefere ver primeiro?$t$),
-- Títulos dos botões (≤ 20 caracteres). O Chatwoot devolve só o título: o 5b casa pelo título, sem o emoji.
('abertura_botao_rua', $t$📍 Ver minha rua$t$),
('abertura_botao_planos', $t$💰 Ver os planos$t$),
('abertura_botao_humano', $t$💬 Falar com alguém$t$),
('abertura_resp_rua', $t$Oba! 🥰 Me manda só o seu CEP que eu já confiro pra você.

Se não lembrar, tudo bem: pode mandar o nome da rua e o bairro 😉$t$),
-- Sem preço: a cidade ainda não é conhecida (o preço vem depois do CEP, pela cidade/cluster).
('abertura_resp_planos', $t$Claro! 😊 Os planos vão de 600 Mega a 1 Giga, com preço fixo até 2030.

O valor muda um pouquinho de cidade pra cidade. Me manda seu CEP (ou a rua e o bairro) que eu te mostro os planos e preços certinhos daí 👇$t$),
('abertura_resp_humano', $t$Claro! Já chamei nosso consultor, ele te responde por aqui 💚$t$),
-- Os botões não saíram (erro da Meta): este texto vai público pelo Chatwoot no lugar deles.
('abertura_fallback', $t$Oi, {nome}, tudo bem? 😊

Aqui é a Mari, da Nio. Fiquei feliz com sua mensagem!

Me manda seu CEP (ou o nome da rua e o bairro) que eu já te mostro os planos daí 😉$t$),
('abertura_lembrete', $t$Se ficar mais fácil, me manda só o nome da rua e o bairro 😉$t$)
on conflict (chave) do nothing;

alter table public.mari_conversas drop constraint if exists mari_conversas_cadencia_passo_check;
alter table public.mari_conversas add constraint mari_conversas_cadencia_passo_check
  check (cadencia_passo in ('nenhum', 'L15', 'P1', 'F1', 'F2', 'D3', 'D7', 'D15', 'encerrada'));

CREATE OR REPLACE FUNCTION public.mari_cadencia_texto(c mari_conversas, p_passo text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select case
    -- 0070 (abertura B2): L15 = lembrete leve (texto em config_mari_textos.abertura_lembrete). Depois da B2 o número da casa
    -- só é pedido quando a cidade já foi identificada — o F1/F2 da etapa abertura pede só o CEP (ou rua e bairro).
    when p_passo = 'L15' then coalesce((select t.texto from public.config_mari_textos t where t.chave = 'abertura_lembrete'),
                                       'Se ficar mais fácil, me manda só o nome da rua e o bairro 😉')
    when c.etapa = 'abertura' and c.cep is null and coalesce(c.dados ->> 'abertura', '') <> '' then case p_passo
      when 'F1' then 'Conseguiu achar o CEP? Com ele (ou a rua e o bairro) eu já te mostro os planos da sua região 😊'
      else 'Passando aqui rapidinho: se me mandar o CEP (ou a rua e o bairro), te mostro os planos da sua região 😊' end
    when c.etapa in ('abertura', 'endereco') then case p_passo
      when 'F1' then 'Conseguiu ver o CEP e o número da casa? Com eles eu já te mostro as opções 😊'
      else 'Passando aqui rapidinho: se me mandar o CEP e o número, te mostro os planos da sua região 😊' end
    when c.etapa = 'elegibilidade' then case p_passo
      when 'F1' then 'Só falta essa: hoje você usa internet de qual operadora? Com isso eu já te mostro as opções 😊'
      else 'Passando aqui rapidinho: me conta qual operadora você usa hoje que eu sigo com as opções 😊' end
    when c.etapa = 'planos' then case p_passo
      when 'F1' then 'Ficou alguma dúvida sobre os planos? Se quiser, te ajudo a escolher 😊'
      else 'Separei as opções da sua região. Qual delas te chamou mais atenção? 😊' end
    when c.etapa = 'coleta' then case p_passo
      when 'F1' then 'Estamos quase lá! Falta só ' || public.mari_cadencia_campo_falta(c) || ' pra eu adiantar seu pedido 😊'
      else 'Seu pedido está quase pronto — me passa ' || public.mari_cadencia_campo_falta(c) || ' quando puder? 😊' end
    else case p_passo   -- resumo (e qualquer etapa nova)
      when 'F1' then 'Conseguiu conferir os dados? Se estiver tudo certo, é só me confirmar 😊'
      else 'Seus dados estão prontos pra seguir — me confirma que está tudo certo? 😊' end
  end
$function$;

CREATE OR REPLACE FUNCTION public.mari_cadencia_avaliar(p_agora timestamp with time zone DEFAULT now(), p_conversa uuid DEFAULT NULL::uuid)
 RETURNS TABLE(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text, passo_atual text, passo_em timestamp with time zone, proximo_passo text, proximo_em timestamp with time zone, pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text, janela_aberta boolean, janela_fecha_em timestamp with time zone, toques_hoje integer, toques_mes integer, ligar_sugerido boolean, venda_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  v_tq     record;
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
  l15_at   timestamptz; v_ab_em timestamptz; v_ab_tags jsonb;   -- 0070: lembrete leve da abertura B2
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
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

    if c.status = 'handoff_realizado' then
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
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
          end if;
        else
          continue;
        end if;
        v_txt := public.mari_render_template(v_tpl, v_params);
        if v_janela then v_acao := 'texto'; v_tpl := null; else v_acao := 'template'; v_cat := 'UTILITY'; end if;
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
          -- horário anterior às 20 h do lead). Continua valendo o teto do contrato: 2 toques/dia, 15/mês por telefone.
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

    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      if v_exc is null and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_tq.hoje >= 2 then
        v_bloq := 'limite do dia (2 toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_tq.mes >= 15 then
        v_bloq := 'limite do mês (15 toques)';
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

CREATE OR REPLACE FUNCTION public.mari_cadencia_registrar(p_conversa uuid, p_passo text, p_ok boolean, p_erro text DEFAULT NULL::text, p_agora timestamp with time zone DEFAULT now(), p_texto text DEFAULT NULL::text, p_excecao text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas;
  v_bio timestamptz;
  v_inst timestamptz;
  v_prox record;
  v_eco int := 0;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;

  if not coalesce(p_ok, false) then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_cadencia', 'envio da cadência falhou (' || coalesce(p_passo, '?') || '): ' || coalesce(p_erro, 'sem detalhe'),
            jsonb_build_object('passo', p_passo, 'agora', p_agora));
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  if p_passo = 'ENCERRAR' then
    update public.mari_conversas set status = 'encerrado_ia', handoff_motivo = 'sem_contato',
           cadencia_passo = 'encerrada', cadencia_passo_em = p_agora, cadencia_proximo_em = null
     where id = p_conversa;
    insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
    values (p_conversa, 'sistema', 'Saída "Sem contato": 48 h sem resposta depois do D15.',
            jsonb_build_object('cadencia', 'ENCERRAR'), p_agora);
    return jsonb_build_object('ok', true, 'registrado', 'encerrada');
  end if;
  if p_passo = 'BIO3' then
    return jsonb_build_object('ok', false, 'erro', 'BIO3 é ligação do nosso time: nunca registrada como envio automático');
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
  values (p_conversa, 'mari', coalesce(p_texto, ''),
          jsonb_strip_nulls(jsonb_build_object('cadencia', p_passo, 'excecao', p_excecao, 'simulado', c.canal = 'teste')), p_agora);

  -- 0052: eco do próprio envio que chegou ao mari_principal ANTES deste registro (virou turno 'humano' falso).
  if c.canal = 'whatsapp' and coalesce(btrim(p_texto), '') <> '' then
    delete from public.mari_turnos t
     where t.conversa_id = p_conversa and t.papel = 'humano'
       and btrim(t.texto) = btrim(p_texto)
       and t.created_at >= p_agora - interval '1 minute'
       and t.created_at <= greatest(now(), p_agora) + interval '5 minutes';
    get diagnostics v_eco = row_count;
  end if;

  insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
  values (c.venda_id, c.id, c.telefone, 'whatsapp', 'saida', 'mari', p_agora, p_passo, 'ativo',
          'cadência ' || p_passo || coalesce(' · ' || p_excecao, '') || case when c.canal = 'teste' then ' (simulado)' else '' end);

  if p_passo = 'RETORNO' then
    update public.mari_conversas set cadencia_retorno_em = p_agora,
           cadencia_passo = case when cadencia_passo in ('nenhum', 'F1', 'P1') then 'F2' else cadencia_passo end,
           cadencia_passo_em = p_agora
     where id = p_conversa;
  elsif p_passo = 'VISITA' then   -- histórico (0018); não é mais gerado
    select biometria_em into v_bio from public.vendas where id = c.venda_id;
    update public.mari_conversas set visita_confirmada_para = v_bio where id = p_conversa;
  elsif p_passo = 'BIO1' then
    update public.mari_conversas set bio_lembrete_em = p_agora where id = p_conversa;
  elsif p_passo = 'INSTALACAO' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_avisada_para = v_inst, instalacao_avisada_em = p_agora where id = p_conversa;
  elsif p_passo = 'VESPERA' then
    select instalacao_agendada_para into v_inst from public.vendas where id = c.venda_id;
    update public.mari_conversas set instalacao_lembrada_para = v_inst where id = p_conversa;
  elsif p_passo = 'L15' then   -- 0070: lembrete da abertura B2 — passo + horário em dados (medição v_mari_abertura)
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora,
           dados = dados || jsonb_build_object('abertura_lembrete_em', p_agora)
     where id = p_conversa;
  else
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora where id = p_conversa;
  end if;

  select a.proximo_passo, a.proximo_em into v_prox
    from public.mari_cadencia_avaliar(p_agora + interval '1 second', p_conversa) a limit 1;
  update public.mari_conversas set cadencia_proximo_em = v_prox.proximo_em where id = p_conversa;

  return jsonb_build_object('ok', true, 'registrado', p_passo, 'proximo_passo', v_prox.proximo_passo,
                            'proximo_em', v_prox.proximo_em, 'eco_removido', v_eco);
end;
$function$;

-- ── medição antes × depois (sem teste A/B). Regra 10: a view mostra QUE mudou; nada de conclusão com < ~20 conversas por versão.
-- versao: dados.abertura ('b2_081126'); antes da 1ª B2 = 'v7_antiga'; depois dela, sem abertura (1ª mensagem já com CEP/
-- endereço, reclamação, desconto…) = 'sem_abertura'. Só WhatsApp real (fora canal teste, 5500000000… e telefones_teste).
create or replace view public.v_mari_abertura with (security_invoker = true) as
with ini as (
  select min(x.created_at) as b2_desde from public.mari_conversas x where x.dados ? 'abertura'
), base as (
  select c.id,
         (c.created_at at time zone 'America/Sao_Paulo')::date as dia,
         coalesce(c.dados ->> 'abertura',
                  case when c.created_at < coalesce(ini.b2_desde, 'infinity'::timestamptz) then 'v7_antiga' else 'sem_abertura' end) as versao,
         c.dados ->> 'abertura_botao' as botao,
         (c.cep is not null or coalesce(c.dados ->> 'rua_informada', '') <> '' or c.dados ? 'opcoes_rua') as mandou_endereco,
         (c.handoff_motivo = 'dados_completos' or c.ciclo_anterior ->> 'motivo' = 'dados_completos') as dados_completos,
         (c.dados ->> 'abertura_lembrete_em')::timestamptz as lembrete_em
    from public.mari_conversas c cross join ini
   where c.canal = 'whatsapp'
     and c.telefone not like '5500000000%'
     and position(c.telefone in coalesce((select t.texto from public.config_mari_textos t where t.chave = 'telefones_teste'), '')) = 0
)
select b.dia, b.versao,
       count(*)::int as conversas,
       count(*) filter (where b.botao is not null)::int as tocaram_botao,
       round(100.0 * count(*) filter (where b.botao is not null) / count(*), 1) as pct_tocou_botao,
       count(*) filter (where b.botao = 'rua')::int as botao_rua,
       count(*) filter (where b.botao = 'planos')::int as botao_planos,
       count(*) filter (where b.botao = 'humano')::int as botao_humano,
       count(*) filter (where b.mandou_endereco)::int as mandaram_cep_rua,
       round(100.0 * count(*) filter (where b.mandou_endereco) / count(*), 1) as pct_cep_rua,
       count(*) filter (where b.dados_completos)::int as dados_completos,
       round(100.0 * count(*) filter (where b.dados_completos) / count(*), 1) as pct_dados_completos,
       count(*) filter (where b.lembrete_em is not null)::int as lembretes,
       count(*) filter (where b.lembrete_em is not null and exists (
         select 1 from public.mari_turnos t where t.conversa_id = b.id and t.papel = 'lead' and t.created_at > b.lembrete_em))::int as responderam_lembrete
  from base b
 group by b.dia, b.versao
 order by b.dia desc, b.versao;

comment on view public.v_mari_abertura is
  'Abertura da Mari por dia e versão (0070): conversas, toque em botão, CEP/rua, dados_completos, lembrete L15. Só admin/backoffice (RLS de mari_conversas).';
revoke all on public.v_mari_abertura from anon;
grant select on public.v_mari_abertura to authenticated, service_role;
