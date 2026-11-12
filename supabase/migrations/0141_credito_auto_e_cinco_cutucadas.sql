-- NIOGEN | supabase/migrations/0141_credito_auto_e_cinco_cutucadas.sql | 12/11/2026 — Claude Code
-- Ricardo, 12/11 ~10h ("Pode seguir com o plano"):
--  1. CRÉDITO SEM PERGUNTA ("nem o WhatsApp oficial da Nio pede autorização; isso pode travar o cliente"): roda sozinho com CPF
--     válido + e-mail confirmado. A linha da LGPD não muda. Negado → a Mari oferece o CPF de um parente/familiar: CPF novo na
--     conversa → crédito e duplicidade voltam à fila (até 2 consultas por conversa). Regra 5 do CLAUDE.md revista junto.
--  2. CINCO CUTUCADAS na janela de 24 h, em qualquer etapa (15 min · 1 h · 3 h · 6 h · ~20 h), no horário do contrato; o texto é
--     escrito pela Mari no n8n (mari_cadencia) com o fixo do banco como reserva.

-- 1a. crédito: sem autorização, até 2 consultas por conversa (titular + parente)
create or replace function public.mari_credito_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where c.credito_em is null and c.credito_consultas < 2
       and public._cpf_ok(c.dados->>'cpf')
       and coalesce(c.dados->>'email', '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
       and coalesce(c.dados->>'email_confirmado', '') <> 'false'
       and coalesce(c.nao_contatar, false) = false
       and coalesce(c.telefone, '') !~ '^55000000'
       and c.updated_at > now() - interval '12 hours'
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
    returning c.id, c.dados, c.telefone
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', id,
           'cpf', regexp_replace(dados->>'cpf', '\D', '', 'g'),
           'celular', right(regexp_replace(coalesce(dados->>'telefone', telefone, ''), '\D', '', 'g'), 11),
           'email', lower(dados->>'email'))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_credito_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_credito_pendentes(int) to service_role;

-- 1b. CPF novo (o parente que vira titular) → crédito e duplicidade voltam à fila; os avisos da Mari zeram
create or replace function public._mari_cpf_mudou() returns trigger language plpgsql as $$
begin
  if regexp_replace(coalesce(new.dados->>'cpf', ''), '\D', '', 'g') <> regexp_replace(coalesce(old.dados->>'cpf', ''), '\D', '', 'g')
     and coalesce(old.dados->>'cpf', '') <> '' and coalesce(new.dados->>'cpf', '') <> '' then
    if old.credito_em is not null then
      new.credito_em := null; new.credito_resultado := null; new.credito_formas := null;
    end if;
    if old.nio_pedido_aberto_em is not null then
      new.nio_pedido_aberto_em := null; new.nio_pedido_aberto := null;
    end if;
    new.dados := new.dados - 'credito_negado_avisado' - 'credito_cartao_avisado' - 'pedido_aberto_resposta';
  end if;
  return new;
end $$;
drop trigger if exists mari_cpf_mudou on public.mari_conversas;
create trigger mari_cpf_mudou before update of dados on public.mari_conversas
  for each row execute function public._mari_cpf_mudou();

-- 1c. duplicidade: até 2 por conversa (titular + parente)
create or replace function public.mari_dup_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where public._cpf_ok(c.dados->>'cpf')
       and c.plano_escolhido is not null
       and c.nio_pedido_aberto_em is null
       and c.dup_consultas < 2
       and coalesce(c.telefone, '') !~ '^55000000'
       and coalesce(c.nao_contatar, false) = false
       and c.updated_at > now() - interval '12 hours'
       and (c.venda_id is null or c.handoff_em > now() - interval '12 hours')
       -- 0137: CPFs diferentes por telefone (o mesmo CPF volta pelo cache de 24 h do operador e não pesa)
       and (select count(distinct regexp_replace(o.dados->>'cpf', '\D', '', 'g')) from public.mari_conversas o
             where o.telefone = c.telefone and o.dup_consultas > 0 and o.nio_pedido_aberto_em > now() - interval '7 days'
               and regexp_replace(o.dados->>'cpf', '\D', '', 'g') <> regexp_replace(c.dados->>'cpf', '\D', '', 'g')) < 3
     order by c.updated_at desc
     limit greatest(1, least(p_limite, 3))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set nio_pedido_aberto_em = now(), dup_consultas = c.dup_consultas + 1
      from alvo where c.id = alvo.id
    returning c.id, c.dados->>'cpf' cpf
  )
  select coalesce(jsonb_agg(jsonb_build_object('conversa_id', id, 'cpf', regexp_replace(cpf, '\D', '', 'g'))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_dup_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_dup_pendentes(int) to service_role;

-- 2a. passos novos
alter table public.mari_conversas drop constraint if exists mari_conversas_cadencia_passo_check;
alter table public.mari_conversas add constraint mari_conversas_cadencia_passo_check
  check (cadencia_passo in ('nenhum', 'L15', 'P1', 'F1', 'F2', 'F3', 'F4', 'F5', 'D3', 'D7', 'D15', 'encerrada'));

-- 2b. escada da janela (5 cutucadas)
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

-- 2c. registro: retorno pedido pelo cliente pula a escada até o F5
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
           cadencia_passo = case when cadencia_passo in ('nenhum', 'L15', 'F1', 'F2', 'F3', 'F4', 'P1') then 'F5' else cadencia_passo end,
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

-- 2d. ordem da fila
CREATE OR REPLACE FUNCTION public.mari_cadencia_candidatos(p_agora timestamp with time zone DEFAULT now(), p_canal text DEFAULT 'teste'::text, p_limite integer DEFAULT 30)
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select to_jsonb(a) from public.mari_cadencia_avaliar(p_agora, null) a
   where a.pode_enviar and a.canal = p_canal
   order by case a.proximo_passo when 'RETORNO' then 0 when 'INSTALACAO' then 1 when 'VESPERA' then 1 when 'BIO1' then 1
                                 when 'F1' then 2 when 'F2' then 3 when 'F3' then 3 when 'F4' then 3 when 'F5' then 3 else 4 end,
            a.proximo_em
   limit least(greatest(coalesce(p_limite, 30), 1), 30)
$function$;
