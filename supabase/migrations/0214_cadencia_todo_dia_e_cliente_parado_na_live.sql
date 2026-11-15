-- NIOGEN | supabase/migrations/0214_cadencia_todo_dia_e_cliente_parado_na_live.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11 ~13h, casos Mauricio R. e José Lúcio Pinto): "não deveriam estar na Live para o bko acompanhar e
-- cutucar o cliente?" · "retirar qualquer trava que impede a cadência da Mari nos dias de semana e feriado. Única restrição fica
-- enviar na madrugada" · madrugada = 0h às 6h · risco do horário do contrato (anexo: "abordar só em horário comercial",
-- dias úteis 9–21, domingo/feriado proibido) ASSUMIDO pelo Ricardo em 15/11/2026.
--
-- 1. Toques automáticos (cadência, véspera, cartão, indicação, mensagens do backoffice pela fila, oportunidades): TODO DIA,
--    das 6h à 0h, inclusive domingo e feriado — config_regras.mari_horario_toques {abre, fecha, todos_os_dias}.
--    mari_no_horario / mari_proximo_horario / mari_ultimo_horario passam a ler mari_janela_toque. A véspera e o lembrete do
--    cartão caem no dia anterior de verdade (mari_dia_toque). A exceção da 0209 (véspera no domingo 10–16) deixa de disparar.
--    NÃO mudam: mari_dia_permitido / mari_janela_dia / minutos_uteis (prazo do time e ritmo da meta em dia útil) e o
--    "prazo do consultor" que a Mari promete (mari_contexto.no_horario → mari_atendimento_no_horario, horário do time).
-- 2. Live: conversa com a Mari, vez do cliente (a Mari falou por último), sem dono humano:
--    · parado há ≥ parado_min (60 min) → "Acompanhando" (cliente_parado), com há quanto tempo e até quando vai a janela;
--    · a janela de 24 h fecha em ≤ sobe_h (3 h) → "Sua vez" (hoje), "cutucar agora (texto livre)";
--    · resolvida no Chatwoot e ainda ativa no NIOGEN → "Sua vez": a Mari parou de cutucar e ninguém deu saída (Sergio Naves,
--      Marcelo Messias, Nancir Garcia, Waldir — parados desde 12–14/11). Parâmetros em config_regras.live_cliente_parado.
-- Regra 20: (1) etapa/status/destino não mudam; a vez e o prazo ficam explícitos no cartão. (2) é o "ninguém parado em
-- silêncio": o estado sem saída (resolvida sem saída) vira dono cobrado. (3) nenhum status é gravado pela tela. (4) fonte
-- única: mari_conversas. (5) sem estado nem número novo — a conferência da Live (jornada_furo) segue cobrindo.
-- Nada no mari_principal (o portão não se aplica).
begin;

insert into public.config_regras (chave, valor, descricao) values
  ('mari_horario_toques', '{"abre": "06:00", "fecha": "24:00", "todos_os_dias": true}',
   'Horário dos toques automáticos da Mari e das mensagens da fila (hora de Brasília). todos_os_dias=true: todo dia, domingo e feriado inclusive (Ricardo, 15/11/2026: "única restrição fica enviar na madrugada"; risco do contrato assumido). false = horário do contrato (seg–sex 9–21, sáb 10–16).'),
  ('live_cliente_parado', '{"parado_min": 60, "janela_fecha_h": 23, "sobe_h": 3, "dias_max": 15}',
   'Live: conversa com a Mari, vez do cliente. parado_min = minutos desde a última fala da Mari para entrar em Acompanhando · janela_fecha_h = horas da janela (23 = folga da Meta) · sobe_h = faltando isso para fechar, sobe para Sua vez · dias_max = depois disso não aparece.')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao, atualizado_em = now();

-- horário dos TOQUES (abre/fecha do dia, hora local); null = dia sem toque
create or replace function public.mari_janela_toque(p_dia date, p_cidade text default null, out abre timestamp, out fecha timestamp)
language sql stable set search_path = public as $$
  select case when coalesce((h.v ->> 'todos_os_dias')::boolean, false) then p_dia + coalesce((h.v ->> 'abre')::interval, interval '6 hours')
              else j.abre end,
         case when coalesce((h.v ->> 'todos_os_dias')::boolean, false) then p_dia + coalesce((h.v ->> 'fecha')::interval, interval '24 hours')
              else j.fecha end
    from (select (select valor from public.config_regras where chave = 'mari_horario_toques') as v) h,
         lateral public.mari_janela_dia(p_dia, p_cidade) j
$$;

create or replace function public.mari_dia_toque(p_dia date, p_cidade text default null)
returns boolean language sql stable set search_path = public as $$
  select (public.mari_janela_toque(p_dia, p_cidade)).abre is not null
$$;

-- horário do TIME (o de antes): o prazo que a Mari promete para o consultor
create or replace function public.mari_atendimento_no_horario(p_ts timestamptz, p_cidade text default null)
returns boolean language sql stable set search_path = public as $$
  select coalesce(l >= j.abre and l < j.fecha, false)
    from (select p_ts at time zone 'America/Sao_Paulo' as l) x,
         lateral public.mari_janela_dia((x.l)::date, p_cidade) j
$$;

create or replace function public.mari_no_horario(p_ts timestamptz, p_cidade text default null)
returns boolean language sql stable set search_path = public as $$
  select coalesce(l >= j.abre and l < j.fecha, false)
    from (select p_ts at time zone 'America/Sao_Paulo' as l) x,
         lateral public.mari_janela_toque((x.l)::date, p_cidade) j
$$;

create or replace function public.mari_proximo_horario(p_ts timestamptz, p_cidade text default null)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  l timestamp := p_ts at time zone 'America/Sao_Paulo';
  j record; i int;
begin
  for i in 0..20 loop
    select * into j from public.mari_janela_toque(l::date + i, p_cidade);
    if j.abre is not null then
      if i = 0 then
        if l < j.fecha then return greatest(l, j.abre) at time zone 'America/Sao_Paulo'; end if;
      else
        return j.abre at time zone 'America/Sao_Paulo';
      end if;
    end if;
  end loop;
  return null;
end;
$$;

create or replace function public.mari_ultimo_horario(p_ts timestamptz, p_cidade text default null, p_folga interval default '15 minutes')
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  l timestamp := p_ts at time zone 'America/Sao_Paulo';
  j record; i int; f timestamp;
begin
  for i in 0..20 loop
    select * into j from public.mari_janela_toque(l::date - i, p_cidade);
    if j.abre is not null then
      f := j.fecha - p_folga;
      if i = 0 then
        if l >= j.abre then return least(l, f) at time zone 'America/Sao_Paulo'; end if;
      else
        return f at time zone 'America/Sao_Paulo';
      end if;
    end if;
  end loop;
  return null;
end;
$$;

grant execute on function public.mari_janela_toque(date, text) to authenticated, service_role;
grant execute on function public.mari_dia_toque(date, text) to authenticated, service_role;
grant execute on function public.mari_atendimento_no_horario(timestamptz, text) to authenticated, service_role;

-- mari_contexto (0099) — única mudança: 'no_horario' = horário do time (prazo do consultor), não o dos toques
create or replace function public.mari_contexto(p_conversa uuid, p_cep text default null::text, p_numero text default null::text,
  p_complemento text default null::text, p_viacep jsonb default null::jsonb)
returns jsonb language plpgsql set search_path to 'public' as $function$
declare
  v_conv    public.mari_conversas;
  v_cluster text;
  v_planos  jsonb;
  v_dfv     record;
  v_dfvj    jsonb;
  v_cep     text := nullif(regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'), '');
begin
  select * into v_conv from public.mari_conversas where id = p_conversa;
  if not found then return jsonb_build_object('erro', 'conversa inexistente'); end if;

  -- CEP novo: troca o endereço (e zera o que dependia dele).
  if v_cep is not null and v_cep is distinct from v_conv.cep then
    update public.mari_conversas
       set cep = v_cep, numero = null, complemento = null, endereco_cep = null, cidade = null, uf = null,
           cluster = null, dentro_area = null, dfv_resultado = null, dfv_detalhe = null
     where id = p_conversa;
  end if;

  if p_viacep is not null and not coalesce((p_viacep ->> 'erro')::boolean, false) and v_cep is not null then
    update public.mari_conversas
       set endereco_cep = p_viacep,
           cidade = p_viacep ->> 'localidade',
           uf = p_viacep ->> 'uf'
     where id = p_conversa;
  end if;

  if nullif(btrim(coalesce(p_numero, '')), '') is not null then
    update public.mari_conversas set numero = btrim(p_numero) where id = p_conversa
       and numero is distinct from btrim(p_numero);
  end if;
  if p_complemento is not null then
    update public.mari_conversas set complemento = nullif(btrim(p_complemento), '') where id = p_conversa;
  end if;

  select * into v_conv from public.mari_conversas where id = p_conversa;

  if v_conv.cidade is not null then
    v_cluster := public.cluster_da_area(v_conv.cidade, v_conv.uf, v_conv.endereco_cep ->> 'bairro');
    update public.mari_conversas
       set cluster = v_cluster, dentro_area = v_cluster is not null
     where id = p_conversa;
  end if;

  -- DFV (base só de JF): uma vez por endereço.
  if v_conv.cep is not null and v_conv.numero is not null
     and lower(coalesce(v_conv.cidade, '')) = 'juiz de fora'
     and (v_conv.dfv_resultado is null or p_numero is not null or p_complemento is not null) then
    begin
      select * into v_dfv from public.dfv_consultar(v_conv.cep, v_conv.numero, v_conv.complemento);
      v_dfvj := jsonb_strip_nulls(jsonb_build_object(
        'resultado', v_dfv.resultado, 'hp_livre', v_dfv.hp_livre, 'hc_tot', v_dfv.hc_tot, 'hp_tot', v_dfv.hp_tot,
        'tipo_edificacao', v_dfv.tipo_edificacao, 'faixa_credito', v_dfv.faixa_credito,
        'classificacao', v_dfv.classificacao, 'bairro', v_dfv.bairro, 'particao', v_dfv.particao,
        'opcoes', v_dfv.opcoes));
    exception when others then
      v_dfvj := jsonb_build_object('resultado', 'erro', 'erro', sqlerrm);
      insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
      values (p_conversa, 'mari_contexto/dfv', sqlerrm, jsonb_build_object('cep', v_conv.cep, 'numero', v_conv.numero));
    end;
    update public.mari_conversas set dfv_resultado = v_dfvj ->> 'resultado', dfv_detalhe = v_dfvj where id = p_conversa;
  end if;

  select * into v_conv from public.mari_conversas where id = p_conversa;

  if v_conv.cluster is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'codigo', codigo, 'nome', nome, 'portfolio', portfolio, 'variante', variante,
             'velocidade_mb', velocidade_mb, 'wifi', wifi, 'internet_5g', internet_5g, 'inclusos', to_jsonb(inclusos),
             'preco', preco, 'preco_cartao', preco_cartao, 'taxa_habilitacao', taxa_habilitacao,
             'isencao_meses', isencao_meses) order by portfolio desc, variante, preco), '[]'::jsonb)
      into v_planos
      from public.config_planos
     where ativo and cluster = v_conv.cluster
       and (vigencia_fim is null or vigencia_fim >= current_date);
  end if;

  return jsonb_build_object(
    'conversa', to_jsonb(v_conv) - 'processando_ate' - 'ultima_entrada_ts',
    'planos', coalesce(v_planos, '[]'::jsonb),
    -- 0099: horário do contrato agora (seg–sex 9–21, sáb 10–16, sem domingo nem feriado da cidade) — prazo do consultor.
    'no_horario', public.mari_atendimento_no_horario(now(), v_conv.cidade));
end;
$function$;

-- mari_cadencia_avaliar (0209) — única mudança: véspera e lembrete do cartão no dia anterior pelo horário dos toques
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

-- v_jornada (0112) + camada "cliente parado" (item 2 do cabeçalho)
create or replace view public.v_jornada as  SELECT j.tipo,
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
    j.precisa_acao OR a.usa OR COALESCE(p.sobe, false) AS precisa_acao,
        CASE
            WHEN a.usa THEN a.nivel
            WHEN p.k IS NOT NULL THEN p.nivel
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN a.usa THEN a.texto
            WHEN p.k IS NOT NULL THEN p.texto
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN a.usa THEN a.botao
            ELSE j.botao
        END AS botao,
        CASE
            WHEN a.usa THEN a.em
            WHEN p.k IS NOT NULL THEN p.desde
            ELSE j.desde
        END AS desde,
    j.dono_tipo,
    j.dono_nome,
    j.pendencia,
    j.acao_id,
    j.status_venda,
    j.parceiro_id,
    j.sem_dono_min,
    j.pedido_provisorio,
    j.cliente_confirmou,
    j.confirmou_em,
    an.portal_status,
    an.portal_desde AS portal_status_desde,
    an.bio_resultado AS biometria_ged,
    an.bio_desde AS biometria_ged_desde,
    COALESCE(p.k = 'parado'::text, false) AS cliente_parado
   FROM v_jornada_base j
     LEFT JOIN v_venda_andamento an ON an.venda_id = j.venda_id
     LEFT JOIN v_instalacao_confirmacao ic ON ic.venda_id = j.venda_id AND ic.resposta = 'remarcar'::text
     LEFT JOIN LATERAL ( SELECT x.texto,
            x.nivel,
            x.em,
            x.botao
           FROM ( VALUES (an.portal_alerta,an.portal_alerta_nivel,an.portal_desde,'abrir'::text), (an.bio_alerta,an.bio_alerta_nivel,an.bio_desde,'abrir'::text), (
                        CASE
                            WHEN ic.venda_id IS NOT NULL THEN 'Cliente pediu para remarcar a instalação · reagendar no portal e gravar'::text
                            ELSE NULL::text
                        END,'agora'::text,ic.resposta_em,'reagendar'::text)) x(texto, nivel, em, botao)
          WHERE x.texto IS NOT NULL
          ORDER BY (
                CASE x.nivel
                    WHEN 'agora'::text THEN 0
                    ELSE 1
                END), x.em
         LIMIT 1) al ON true
     CROSS JOIN LATERAL ( SELECT al.texto,
            al.nivel,
            al.em,
            al.botao,
            COALESCE(al.texto IS NOT NULL AND j.etapa > 0 AND (j.nivel <> 'agora'::text OR al.botao = 'reagendar'::text AND j.botao = 'responder'::text) AND
                CASE al.nivel
                    WHEN 'agora'::text THEN 0
                    ELSE 1
                END <=
                CASE j.nivel
                    WHEN 'hoje'::text THEN 1
                    ELSE 2
                END, false) AS usa) a
     CROSS JOIN ( SELECT COALESCE((r.valor ->> 'parado_min')::integer, 60) AS parado_min,
            COALESCE((r.valor ->> 'janela_fecha_h')::integer, 23) AS janela_fecha_h,
            COALESCE((r.valor ->> 'sobe_h')::integer, 3) AS sobe_h,
            COALESCE((r.valor ->> 'dias_max')::integer, 15) AS dias_max
           FROM ( SELECT ( SELECT config_regras.valor
                           FROM config_regras
                          WHERE config_regras.chave = 'live_cliente_parado'::text) AS valor) r) cp
     LEFT JOIN mari_conversas mc ON j.tipo = 'conversa'::text AND mc.id = j.conversa_id
     LEFT JOIN LATERAL ( SELECT q.k,
                CASE q.k
                    WHEN 'parado'::text THEN 'espera'::text
                    ELSE 'hoje'::text
                END AS nivel,
            q.k = ANY (ARRAY['resolvida'::text, 'janela'::text]) AS sobe,
                CASE q.k
                    WHEN 'resolvida'::text THEN 'Resolvida no Chatwoot e sem saída no NIOGEN · a Mari parou de cutucar · dar saída ou retomar'::text
                    WHEN 'janela'::text THEN (('Cliente parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) || ' · a janela de 24 h fecha às '::text)
                        || to_char((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text, 'HH24:MI'::text) || ' · cutucar agora (texto livre)'::text
                    ELSE ('Vez do cliente · parado há '::text || _oport_dur(now() - mc.ultima_msg_mari_at)) ||
                        CASE
                            WHEN (mc.ultima_msg_lead_at + '24:00:00'::interval) > now() THEN ' · janela de 24 h até '::text
                                || to_char((mc.ultima_msg_lead_at + '24:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text, 'DD/MM HH24:MI'::text)
                            ELSE ' · janela fechada (só template)'::text
                        END
                END AS texto,
            mc.ultima_msg_mari_at AS desde
           FROM ( SELECT
                        CASE
                            WHEN mc.id IS NULL OR j.precisa_acao OR a.usa OR j.pendencia OR COALESCE(j.dono_tipo, 'mari'::text) <> 'mari'::text
                              OR mc.status <> 'ativo'::text OR COALESCE(mc.nao_contatar, false) OR mc.ultima_msg_lead_at IS NULL
                              OR mc.ultima_msg_mari_at IS NULL OR mc.ultima_msg_mari_at < mc.ultima_msg_lead_at
                              OR mc.ultima_msg_lead_at < (now() - make_interval(days => cp.dias_max)) THEN NULL::text
                            WHEN COALESCE(mc.chatwoot_resolvida, false) THEN 'resolvida'::text
                            WHEN mc.ultima_msg_mari_at > (now() - make_interval(mins => cp.parado_min)) THEN NULL::text
                            WHEN (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) > now()
                             AND (mc.ultima_msg_lead_at + make_interval(hours => cp.janela_fecha_h)) <= (now() + make_interval(hours => cp.sobe_h)) THEN 'janela'::text
                            ELSE 'parado'::text
                        END AS k) q
          WHERE q.k IS NOT NULL) p ON true;

commit;
