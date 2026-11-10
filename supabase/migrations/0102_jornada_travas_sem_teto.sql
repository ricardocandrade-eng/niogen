-- NIOGEN | supabase/migrations/0102_jornada_travas_sem_teto.sql | 10/11/2026 — Claude Code
-- Prompt docs/Prompt_tres_telas_travas_sem_teto_101126_1030.md (Cowork, 10/11 10:30).
-- Por quê: Minha vez / Conversas / Mari IA se sobrepunham; faltavam travas onde o erro do operador custa multa, estorno ou venda
-- esfriando; e o Ricardo encerrou o teto 2/dia · 15/mês (10/11 10h29: "para uma revenda não pode ser assim" — não reabrir).
-- O quê:
--   C. Teto vira config: config_regras.contato_teto_dia / contato_teto_mes (jsonb null = SEM teto; valor atual null) + contato_teto().
--      mari_cadencia_avaliar e parceiro_conferencia_tentativa leem a config (definição viva, só o trecho do teto trocado).
--      O backoffice já estava sem teto desde a 0095. Ficam: horário/domingo/feriado dos toques automáticos, janela 24 h,
--      não contatar, intervalos da cadência e da régua, Fila Vero (1/dia, 2 no total), registro em contatos_cliente.
--   B2. minutos_uteis(desde, ate, cidade) (só horário de atendimento) + v_jornada.sem_dono_min: lead passado pela Mari (handoff)
--      sem pessoa dona há > 30 min úteis → nível "agora", botão Assumir. A v_jornada viva vira a subconsulta (colunas e ordem
--      iguais; sem_dono_min e pedido_provisorio no fim).
--   B4. Pedido PROV-: v_jornada.pedido_provisorio; 24 h depois do pedido ainda PROV- → "Trocar nº provisório do pedido" (hoje).
--      Sinal derivado, NÃO linha em venda_pendencias: a tabela aceita UMA pendência aberta por venda, e pendência aberta pausa a
--      cadência e esconde o passo da biometria/OS (prazo de 4 h). Some sozinho quando o nº real é gravado.
--   B1. venda_conferencia_recompra(venda, selos, origem) → eventos_venda tipo conferencia_recompra (quem, quando, selos).
--   B3. Gatilho em mari_turnos (papel humano = eco do Chatwoot) sem item na outbox chatwoot_acoes → mari_erros
--      'resposta_fora_niogen' (conta no Painel) + nota privada "Respondido pelo Chatwoot…" (no máx. 1 por conversa/dia).
--   A2. jornada_furo_registrar(conversas[]) → mari_erros 'jornada_furo' (1 por conversa/dia): Conversas deveria contar 0.
--   Alarme WABA: tabela waba_qualidade (leitura do quality_rating pelo n8n waba_qualidade; o Painel avisa se não for GREEN).
-- Regra 15: config e tabela nova com parceiro_id. Contrato: nada sai para o cliente (a nota é privada).

begin;

-- ───────────────────────── C. teto de contatos = config (nulo = sem teto) ─────────────────────────
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('contato_teto_dia', 'null'::jsonb, 'Teto de contatos ativos por cliente por dia. null = sem teto (Ricardo, 10/11/2026 10h29).', 'dharma'),
  ('contato_teto_mes', 'null'::jsonb, 'Teto de contatos ativos por cliente por mês. null = sem teto (Ricardo, 10/11/2026 10h29).', 'dharma')
on conflict (chave) do update set valor = 'null'::jsonb, descricao = excluded.descricao, atualizado_em = now();

create or replace function public.contato_teto(out dia integer, out mes integer)
language sql stable set search_path = public as $$
  select (select case when jsonb_typeof(valor) = 'number' then (valor #>> '{}')::int end from public.config_regras where chave = 'contato_teto_dia'),
         (select case when jsonb_typeof(valor) = 'number' then (valor #>> '{}')::int end from public.config_regras where chave = 'contato_teto_mes')
$$;
grant execute on function public.contato_teto() to authenticated, service_role;

-- ───────────────────────── C. cadência da Mari e conferência de parceiro: teto pela config ─────────────────────────
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

CREATE OR REPLACE FUNCTION public.parceiro_conferencia_tentativa(p_venda uuid, p_canal text, p_atendeu boolean, p_resumo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v       public.vendas%rowtype;
  tel     text;
  n_hoje  int;
  n_mes   int;
  v_teto  record;   -- 0102
  n_sem   int;
  desde   timestamptz;
  v_max   int;
  devolvida boolean := false;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice registram a conferência.' using errcode = '42501';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found or v.origem <> 'parceiro_pap' then
    raise exception 'Venda de parceiro não encontrada.' using errcode = 'P0001';
  end if;
  if v.conferencia_status <> 'pendente' then
    raise exception 'A conferência desta venda não está pendente (%).', v.conferencia_status using errcode = 'P0001';
  end if;
  if p_canal not in ('whatsapp', 'ligacao') then
    raise exception 'Canal da conferência: whatsapp ou ligacao.' using errcode = 'P0001';
  end if;
  if not public.mari_no_horario(now(), v.cidade) then
    raise exception 'Fora do horário de contato do contrato (seg–sex 9–21, sáb 10–16, nunca domingo/feriado).' using errcode = 'P0001';
  end if;
  tel := public.tel_norm(v.cliente_whatsapp);
  if tel is null then
    raise exception 'A venda não tem telefone do cliente.' using errcode = 'P0001';
  end if;
  select t.hoje, t.mes into n_hoje, n_mes from public.mari_toques(tel) t;
  select * into v_teto from public.contato_teto();
  if (v_teto.dia is not null and n_hoje >= v_teto.dia) or (v_teto.mes is not null and n_mes >= v_teto.mes) then
    raise exception 'Teto de contatos configurado atingido para este cliente: hoje %, mês %.', n_hoje, n_mes
      using errcode = 'P0001';
  end if;

  insert into public.contatos_cliente (venda_id, canal, direcao, por, resumo, toque, tipo)
  values (p_venda, p_canal, 'saida', 'vendedor', p_resumo,
          case when p_atendeu then 'CONF_ATENDEU' else 'CONF_SEM_RESPOSTA' end, 'ativo');

  -- Só conta desde a última (re)abertura da conferência (depois de devolvida, o parceiro reenvia e recomeça).
  select coalesce(max(criado_em), v.criado_em) into desde from public.eventos_venda
   where venda_id = p_venda and tipo = 'conferencia' and detalhe ->> 'para' = 'pendente';
  select count(*) into n_sem from public.contatos_cliente
   where venda_id = p_venda and toque = 'CONF_SEM_RESPOSTA' and em >= desde;
  select conferencia_max_tentativas into v_max from public.config_parceiros;
  if not p_atendeu and n_sem >= coalesce(v_max, 3) then
    update public.vendas set conferencia_status = 'devolvida', conferencia_motivo = 'cliente_nao_atende',
           conferencia_obs = coalesce(conferencia_obs || E'\n', '') || n_sem || ' tentativas sem resposta.'
     where id = p_venda;
    devolvida := true;
  end if;
  return jsonb_build_object('sem_resposta', n_sem, 'max', coalesce(v_max, 3), 'devolvida', devolvida,
                            'contatos_hoje', n_hoje + 1, 'contatos_mes', n_mes + 1);
end;
$function$;

-- ───────────────────────── B2. minutos úteis (horário de atendimento do contrato) ─────────────────────────
-- Soma, dia a dia, a interseção de [desde, ate] com a janela do dia (mari_janela_dia: seg–sex 9–21, sáb 10–16, nunca
-- domingo/feriado). Mais de 31 dias = 0 (quem usa já limita o período).
create or replace function public.minutos_uteis(p_desde timestamptz, p_ate timestamptz default now(), p_cidade text default null)
returns integer language sql stable set search_path = public as $$
  select coalesce(sum(greatest(0, extract(epoch from (least(j.fecha, a.l) - greatest(j.abre, d.l))) / 60)), 0)::int
    from (select p_desde at time zone 'America/Sao_Paulo' as l) d,
         (select p_ate at time zone 'America/Sao_Paulo' as l) a,
         lateral generate_series(d.l::date, a.l::date, interval '1 day') g(dia),
         lateral public.mari_janela_dia(g.dia::date, p_cidade) j
   where p_desde < p_ate and a.l::date - d.l::date <= 31 and j.abre is not null
$$;
grant execute on function public.minutos_uteis(timestamptz, timestamptz, text) to authenticated, service_role;

-- ───────────────────────── v_jornada: camada de fora (B2 sem dono · B4 pedido provisório) ─────────────────────────
create or replace view public.v_jornada with (security_invoker = true) as
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
    j.precisa_acao OR x.furo OR x.prov_vencido AS precisa_acao,
        CASE
            WHEN x.furo THEN 'agora'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN 'hoje'::text
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN ('Passado pela Mari sem dono há '::text ||
                CASE WHEN y.min < 60 THEN y.min || ' min'::text ELSE (y.min / 60) || ' h'::text END) || ' (horário de atendimento) · assumir'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN ('Trocar nº provisório do pedido ('::text || y.pedido) || ') pelo nº real do portal'::text
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN 'assumir'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN 'abrir'::text
            ELSE j.botao
        END AS botao,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN y.handoff_em
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN y.pedido_em
            ELSE j.desde
        END AS desde,
    j.dono_tipo,
    j.dono_nome,
    j.pendencia,
    j.acao_id,
    j.status_venda,
    j.parceiro_id,
    y.min AS sem_dono_min,
    y.prov AS pedido_provisorio
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
  WHERE s.venda_id IS NULL AND s.coluna <> 'encerrada'::text ) j
     LEFT JOIN mari_conversas c ON c.id = j.conversa_id
     LEFT JOIN vendas vv ON vv.id = j.venda_id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN c.handoff_em IS NOT NULL AND c.handoff_em > (now() - '30 days'::interval)
                     AND (c.status = 'handoff_realizado'::text OR j.venda_id IS NOT NULL)
                     AND (COALESCE(c.handoff_motivo, ''::text) <> ALL (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'sem_contato'::text, 'ja_cliente_nio'::text]))
                     AND COALESCE(j.dono_tipo, 'mari'::text) <> 'pessoa'::text
                     AND NOT COALESCE(c.nao_contatar, false)
                     AND (j.nivel <> ALL (ARRAY['ok'::text, 'fora'::text]))
                     AND NOT j.pendencia
                     AND COALESCE(j.status_venda, ''::text) <> 'saida'::text
                    THEN minutos_uteis(c.handoff_em, now(), c.cidade)
                    ELSE NULL::integer
                END AS min,
            c.handoff_em,
            COALESCE(vv.nio_pedido, ''::text) ~~* 'PROV-%'::text AS prov,
            vv.nio_pedido AS pedido,
            COALESCE(vv.nio_pedido_em, vv.criado_em) AS pedido_em) y
     CROSS JOIN LATERAL ( SELECT COALESCE(y.min, 0) > 30 AS furo,
            COALESCE(y.prov AND COALESCE(j.status_venda, ''::text) <> 'saida'::text AND y.pedido_em < (now() - '24:00:00'::interval), false) AS prov_vencido) x;

-- ───────────────────────── B1. conferência de recompra (não bloqueia; só registra) ─────────────────────────
create or replace function public.venda_conferencia_recompra(p_venda uuid, p_selos text[], p_origem text default 'ficha')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.vendas where id = p_venda) then raise exception 'Venda não encontrada.'; end if;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'conferencia_recompra',
          jsonb_build_object('selos', to_jsonb(coalesce(p_selos, '{}'::text[])), 'origem', left(coalesce(p_origem, 'ficha'), 20),
                             'texto', 'Conferi: não é cliente nem endereço Nio'),
          auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'evento', v_id);
end;
$$;
revoke all on function public.venda_conferencia_recompra(uuid, text[], text) from public, anon;
grant execute on function public.venda_conferencia_recompra(uuid, text[], text) to authenticated;

-- ───────────────────────── A2. furo da jornada (Conversas deveria contar 0) ─────────────────────────
create or replace function public.jornada_furo_registrar(p_conversas uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  n    int := 0;
  cid  uuid;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  j    record;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return 0; end if;
  foreach cid in array coalesce(p_conversas, '{}'::uuid[]) loop
    exit when n >= 50;
    continue when not exists (select 1 from public.mari_conversas where id = cid);
    continue when exists (select 1 from public.mari_erros e where e.conversa_id = cid and e.no_n8n = 'jornada_furo'
                            and (e.created_at at time zone 'America/Sao_Paulo')::date = hoje);
    select vj.nivel, vj.o_que_fazer, vj.dono_tipo, vj.precisa_acao into j from public.v_jornada vj where vj.conversa_id = cid limit 1;
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (cid, 'jornada_furo',
            'Cliente esperando e fora da Minha vez (Conversas deveria contar 0): '
              || coalesce(j.nivel || ' · ' || j.o_que_fazer, 'sem linha na v_jornada'),
            jsonb_build_object('nivel', j.nivel, 'o_que_fazer', j.o_que_fazer, 'dono_tipo', j.dono_tipo,
                               'precisa_acao', j.precisa_acao, 'visto_por', auth.uid()));
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.jornada_furo_registrar(uuid[]) from public, anon;
grant execute on function public.jornada_furo_registrar(uuid[]) to authenticated;

-- ───────────────────────── B3. resposta direta pelo Chatwoot (fora do NIOGEN) ─────────────────────────
-- O motor da Mari grava papel 'humano' quando o eco de uma fala do time chega do Chatwoot. Se essa fala não tem item na
-- outbox do NIOGEN (mesmo texto nas últimas 6 h, ou qualquer mensagem/nota do NIOGEN nos 5 min anteriores), ela foi digitada
-- direto no Chatwoot: registra (Painel conta) e deixa UMA nota privada por conversa por dia. Nunca derruba o insert do turno.
create or replace function public._resposta_fora_niogen()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c    public.mari_conversas;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if exists (select 1 from public.chatwoot_acoes a
              where a.conversa_id = new.conversa_id and a.tipo in ('mensagem', 'nota')
                and a.status in ('pendente', 'executando', 'feita')
                and a.momento <> 'resposta_fora_niogen'   -- a própria nota do aviso não conta como resposta pelo NIOGEN
                and (a.criada_em >= new.created_at - interval '5 minutes'
                     or (a.payload ->> 'content' = new.texto and a.criada_em >= new.created_at - interval '6 hours'))) then
    return null;
  end if;
  select * into c from public.mari_conversas where id = new.conversa_id;
  if not found or c.canal <> 'whatsapp' or coalesce(c.telefone, '') like '5500000000%' then return null; end if;
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (c.id, 'resposta_fora_niogen', 'Fala do time chegou pelo Chatwoot sem passar pelo NIOGEN',
          jsonb_build_object('turno_id', new.id, 'texto', left(coalesce(new.texto, ''), 200)));
  if coalesce(c.chatwoot_conversation_id, '') <> ''
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.momento = 'resposta_fora_niogen'
                       and (a.criada_em at time zone 'America/Sao_Paulo')::date = hoje) then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'resposta_fora_niogen', c.venda_id, c, 'nota',
      jsonb_build_object('content', 'Respondido pelo Chatwoot — responda pelo NIOGEN para a venda andar.'));
  end if;
  return null;
exception when others then
  return null;   -- o rastro nunca derruba a gravação da conversa
end;
$$;
revoke all on function public._resposta_fora_niogen() from public, anon, authenticated;
drop trigger if exists mari_turnos_resposta_fora_niogen on public.mari_turnos;
create trigger mari_turnos_resposta_fora_niogen after insert on public.mari_turnos
  for each row when (new.papel = 'humano') execute function public._resposta_fora_niogen();

-- ───────────────────────── alarme de qualidade da WABA Nio (não trava) ─────────────────────────
create table if not exists public.waba_qualidade (
  id                    bigserial primary key,
  parceiro_id           text not null default 'dharma',
  phone_number_id       text not null,
  quality_rating        text,          -- GREEN · YELLOW · RED · UNKNOWN
  messaging_limit_tier  text,
  status                text,
  bruto                 jsonb not null default '{}'::jsonb,
  lida_em               timestamptz not null default now()
);
create index if not exists waba_qualidade_lida_idx on public.waba_qualidade (lida_em desc);
alter table public.waba_qualidade enable row level security;
drop policy if exists waba_qualidade_ler on public.waba_qualidade;
create policy waba_qualidade_ler on public.waba_qualidade for select to authenticated
  using (public.meu_perfil() = any (array['admin', 'backoffice']));
revoke all on public.waba_qualidade from anon;
grant select on public.waba_qualidade to authenticated;
grant all on public.waba_qualidade to service_role;
grant usage, select on sequence public.waba_qualidade_id_seq to service_role;

commit;
