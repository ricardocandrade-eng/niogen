-- NIOGEN | supabase/migrations/0092_extensao_credito_dfv.sql | 09/11/2026 — Claude Code
-- Avaliação das 2 primeiras vendas (Valdo, Mirian), decisões do Ricardo no chat (09/11 ~18h):
--   (3) "se estou seguindo o Portal com a extensão, isso já poderia ser gravado no Niogen (Viabilidade e Crédito)":
--       backoffice_momento ganha o momento 'credito' (aprovado · so_cartao · pendente · negado). Negado = o mesmo do botão da
--       biometria: pendência "aguardando outro CPF" + pedido de outro CPF ao cliente. Viabilidade já era momento.
--   (4) aviso da biometria repetido (o time mandou à mão e o sistema também): 'pedido' aceita {"sem_aviso": true} — grava,
--       etiqueta e nota, sem a mensagem ao cliente.
--   (8) DFV (Rogério): portal sem viabilidade → conferir no DFV; endereço viável a até 200 m → formulário de análise da Nio
--       + pendência "Confirmar viabilidade com a Nio". v_jornada diz isso no "o que fazer". O link do formulário fica em
--       config_links.nio_form_analise_viabilidade (gravado pelo CLI, fora do repo — regra 15).

CREATE OR REPLACE FUNCTION public.backoffice_momento(p_venda uuid, p_momento text, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d        jsonb := coalesce(p_dados, '{}'::jsonb);
  v        public.vendas;
  c        public.mari_conversas;
  tem_cw   boolean := false;
  g        uuid := gen_random_uuid();
  o        int := 0;
  quem     text;
  agente   int;
  v_time   int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  agora_t  text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  feito    text[] := '{}';
  aviso    text;
  msg      jsonb;
  quando   timestamptz;
  v_res    text;
  v_dia    date;
  v_per    text;
  v_ts     timestamptz;
  v_turno  text;
  v_diatxt text;
  v_pertxt text;
  v_ped    text;
  v_os     text;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
  r        jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice usa os botões da venda.' using errcode = '42501';
  end if;
  if p_momento = 'agendar' then p_momento := 'reagendar'; end if;   -- 0089: agendar de verdade é "OS + agendar"
  if p_momento not in ('assumir', 'viabilidade', 'credito', 'pedido', 'biometria', 'os_agendar', 'reagendar', 'parar', 'devolver_mari') then
    raise exception 'Momento desconhecido: %', p_momento;
  end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  if p_venda is not null then
    select * into v from public.vendas where id = p_venda for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    select * into c from public.mari_conversas
     where venda_id = p_venda and canal = 'whatsapp' and coalesce(chatwoot_conversation_id, '') <> ''
     order by created_at desc limit 1;
  elsif d ? 'conversa_id' then
    select * into c from public.mari_conversas where id = (d ->> 'conversa_id')::uuid;
    if not found then raise exception 'Conversa não encontrada.'; end if;
    if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;
  else
    raise exception 'Informe a venda ou a conversa.';
  end if;
  if p_momento in ('viabilidade', 'credito', 'pedido', 'biometria', 'os_agendar', 'reagendar') and v.id is null then
    raise exception 'Este botão precisa de uma venda.';
  end if;
  tem_cw := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
            and c.telefone not like '5500000000%';

  -- ── assumir ──
  if p_momento = 'assumir' then
    if c.id is null then raise exception 'Esta venda não tem conversa no Chatwoot para assumir.'; end if;
    if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir'
                and a.status in ('pendente', 'executando', 'feita') and a.criada_em > now() - interval '10 minutes') then
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('já assumida há instantes'),
                                'resumo', '✓ esta conversa já foi assumida há instantes — nada repetido', 'venda_id', v.id, 'conversa_id', c.id);
    end if;
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' — cadência parada]', false);
    if v.id is not null and v.vendedor_id is null then
      update public.vendas set vendedor_id = auth.uid() where id = v.id;
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'atribuir',
        case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '👤 Assumida no NIOGEN por ' || quem || ' às ' || agora_t || '.'));
      feito := feito || array[case when agente is not null then 'conversa atribuída a você' else 'conversa no time backoffice' end, 'nota']::text[];
    end if;
    feito := feito || 'Mari calada · cadência parada'::text;

  -- ── viabilidade (portal) ──
  elsif p_momento = 'viabilidade' then
    v_res := nullif(d ->> 'resultado', '');
    if v_res is not null and v_res not in ('viavel', 'sem_viabilidade', 'nao_encontrado') then
      raise exception 'Resultado do portal inválido.';
    end if;
    update public.vendas set
      nio_viab_resultado = v_res, nio_viab_origem = case when v_res is null then null else 'manual' end,
      nio_viab_em = case when v_res is null then null else now() end,
      nio_viab_velocidade = nullif(btrim(coalesce(d ->> 'velocidade', '')), ''),
      nio_viab_interesse_id = nullif(btrim(coalesce(d ->> 'interesse', '')), ''),
      nio_viab_endereco_portal = nullif(btrim(coalesce(d ->> 'endereco_portal', '')), '')
    where id = v.id;
    feito := feito || 'viabilidade gravada'::text;
    if tem_cw and v_res is not null then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '📍 Viabilidade no portal: ' || case v_res when 'viavel' then 'Viável' when 'sem_viabilidade' then 'Sem viabilidade' else 'Endereço não encontrado' end
        || coalesce(' (' || nullif(btrim(coalesce(d ->> 'velocidade', '')), '') || ')', '') || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
    end if;
    if v_res in ('sem_viabilidade', 'nao_encontrado') then
      aviso := 'Tente variações de CEP, rua e número. Se só a Nio pode confirmar, abra a pendência "Nio confirmar viabilidade".';
    end if;

  -- ── pedido gravado no portal (etapa 3): SÓ o pedido; a Nio manda o link da biometria (0089) ──
  elsif p_momento = 'pedido' then
    v_ped := btrim(coalesce(d ->> 'pedido', ''));
    if v_ped !~ '^[A-Za-z0-9._/-]{4,40}$' then
      raise exception 'Número do pedido inválido: use só letras, números, ponto, barra ou hífen (4 a 40 caracteres).' using errcode = '22023';
    end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída; reabra pela ficha antes de registrar o pedido.'; end if;
    if v.status <> '0_qualificado' then raise exception 'O pedido já foi gravado e a venda já andou.'; end if;
    if d ? 'link' and coalesce(d ->> 'link', '') <> '' and (d ->> 'link') !~* '^https?://' then
      raise exception 'O link da biometria tem que começar com https://';
    end if;
    if v.nio_pedido is not distinct from v_ped then
      update public.vendas set credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
             biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link) where id = v.id;
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('pedido já estava gravado'),
                                'resumo', '✓ pedido nº ' || v_ped || ' já estava gravado — nada foi reenviado ao cliente', 'venda_id', v.id);
    end if;
    -- O trigger 0032 carimba nio_pedido_em e a biometria pendente (as 24 h / 72 h contam dali).
    update public.vendas set
      nio_pedido = v_ped,
      credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
      biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link)
    where id = v.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'pedido_aberto_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'pedido', v_ped), auth.uid());
    feito := feito || 'pedido gravado · etapa Pedido · biometria'::text;
    if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
      aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 Pedido nº ' || v_ped || ' aberto às ' || agora_t || ' — ' || quem || '. A Nio manda o link da biometria ao cliente.'));
      if coalesce((d ->> 'sem_aviso')::boolean, false) then
        feito := feito || 'etiqueta'::text || 'nota'::text || 'sem aviso ao cliente (o time já avisou)'::text;   -- 0092
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                   'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do pedido (biometria)');
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    end if;

  -- ── crédito no portal (0092: registrado da extensão, na etapa do cadastro) ──
  elsif p_momento = 'credito' then
    v_res := d ->> 'resultado';
    if v_res not in ('aprovado', 'so_cartao', 'pendente', 'negado') then raise exception 'Crédito: use aprovado, só cartão, pendente ou negado.'; end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída.'; end if;
    update public.vendas set credito_resultado = v_res where id = v.id;
    feito := feito || ('crédito ' || case v_res when 'aprovado' then 'aprovado' when 'so_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente' else 'negado' end)::text;
    if v_res = 'negado' then
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '💳 Crédito no portal: ' || case v_res when 'aprovado' then 'aprovado' when 'so_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente (24 h)' else 'negado — pedido outro CPF' end
        || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
      if v_res = 'negado' then
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
      end if;
    end if;
    if v_res = 'so_cartao' and coalesce(v.forma_pagamento, '') <> 'cartao' then
      aviso := 'Aprovado só no cartão: troque a forma de pagamento na ficha (Detalhes › Plano, valor e pagamento › Trocar).';
    end if;

  -- ── biometria (Validada · Risco · Negado) — etapa 3 ──
  elsif p_momento = 'biometria' then
    if coalesce(btrim(v.nio_pedido), '') = '' then
      raise exception 'Grave o nº do pedido antes: a biometria vem do link que a Nio manda depois do pedido.';
    end if;
    v_res := d ->> 'resultado';
    if v_res = 'validada' then
      update public.vendas set biometria_status = 'validada' where id = v.id;
      feito := feito || 'biometria validada · agora: abrir a OS e agendar (até 4 h)'::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✅ Biometria validada — ' || quem || ', ' || agora_t || '. Próximo: abrir a OS e agendar a instalação (contrato: até 4 h).'));
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'risco' then
      update public.vendas set biometria_status = 'com_risco' where id = v.id;
      feito := feito || 'biometria com risco'::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '⚠️ Biometria com risco — ' || quem || ', ' || agora_t || '. Conferir no portal (só cartão?).'));
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'negado' then
      update public.vendas set credito_resultado = 'negado' where id = v.id;
      feito := feito || 'crédito negado'::text;
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✕ Crédito negado no CPF do cliente — ' || quem || ', ' || agora_t || '. Pedido outro CPF (pendência aberta).'));
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        feito := feito || 'nota'::text;
      end if;
    else
      raise exception 'Biometria: use validada, risco ou negado.';
    end if;

  -- ── OS + agendamento = VENDA (0089, um passo só) · reagendar (exceção, depois da venda) ──
  elsif p_momento in ('os_agendar', 'reagendar') then
    v_dia := nullif(d ->> 'dia', '')::date;
    v_per := coalesce(nullif(d ->> 'periodo', ''), '08:00');
    if v_dia is null then raise exception 'Informe o dia da instalação.'; end if;
    if v_per not in ('08:00', '13:00') then raise exception 'Período inválido.'; end if;
    if v_dia < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'O dia da instalação já passou.'; end if;
    v_ts := (v_dia::text || ' ' || v_per || ':00')::timestamp at time zone 'America/Sao_Paulo';
    v_turno := case when v_per = '13:00' then 'tarde' else 'manha' end;
    if p_momento = 'os_agendar' then
      v_os := btrim(coalesce(d ->> 'os', ''));
      if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
        raise exception 'Número da OS inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
      end if;
      if v.status <> '0_qualificado' then raise exception 'A OS já foi aberta: use Reagendar.'; end if;
      -- Uma atualização só: se a trava recusar (falta pedido, biometria, viabilidade…), nada fica gravado e a mensagem volta.
      update public.vendas set
        nio_os = v_os, instalacao_agendada_para = v_ts, instalacao_turno = v_turno,
        nio_pendencia_cod = null, nio_pendencia_desc = null, status = '2_aguardando_instalacao'
      where id = v.id
      returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'dia', v_dia, 'turno', v_turno), auth.uid());
      feito := feito || ('VENDA · OS ' || v_os || ' · instalação ' || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end)::text;
    else
      if v.status not in ('1_vendido', '2_aguardando_instalacao') then
        raise exception 'Reagendar é depois da venda. Antes, use "Gravar OS e agendamento".';
      end if;
      update public.vendas set
        instalacao_agendada_para = v_ts, instalacao_turno = v_turno, nio_pendencia_cod = null, nio_pendencia_desc = null,
        status = case when status = '1_vendido' then '2_aguardando_instalacao' else status end
      where id = v.id
      returning * into v;
      feito := feito || ('instalação reagendada ' || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end)::text;
    end if;
    if tem_cw then
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', case when p_momento = 'os_agendar' then '📅 OS nº ' || v_os || ' aberta e instalação agendada: ' else '📅 Instalação reagendada: ' end
          || v_diatxt || ', ' || v_pertxt || ' — ' || quem || ', ' || agora_t || '.'));
      o := o + 1;
      msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_instalacao_confirmada',
               jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
               'nio_instalacao_agendada',
               jsonb_build_array(public.mari_cadencia_nome(c), v_diatxt, v_pertxt,
                 concat_ws(', ', nullif(btrim(v.logradouro), ''), nullif(btrim(v.numero), ''), nullif(btrim(v.complemento), ''), nullif(btrim(v.bairro), ''))),
               'confirmação da instalação');
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if msg ->> 'status' = 'pendente' then
        update public.mari_conversas set instalacao_avisada_para = v_ts, instalacao_avisada_em = (msg ->> 'quando')::timestamptz
         where id = c.id;
        -- 0085: SÓ resolve — a automação 24387 "resolvida → liberar" tira agente e time (a Mari volta se o cliente escrever).
        quando := (msg ->> 'quando')::timestamptz;
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'), quando);
        feito := feito || 'conversa resolvida (sem dono)'::text;
      end if;
    end if;

  -- ── cliente pediu para parar ──
  elsif p_momento = 'parar' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    perform public.mari_cadencia_parar(c.id, p_resolvida => true, p_nao_contatar => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente pediu para parar — marcado no NIOGEN por ' || quem || ']', false);
    feito := feito || 'não contatar'::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('nao-contatar')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. Nunca mais chamar.'));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'));
      feito := feito || 'etiqueta'::text || 'nota'::text || 'conversa resolvida'::text;
    end if;

  -- ── devolver para a Mari ──
  elsif p_momento = 'devolver_mari' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[devolvida para a Mari no NIOGEN por ' || quem || ']', false);
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '↩ Devolvida para a Mari por ' || quem || ' às ' || agora_t || ' — a Mari continua.'));
      feito := feito || 'atribuição removida'::text || 'nota'::text;
    end if;
  end if;

  if msg is not null then
    if msg ->> 'status' = 'pendente' then
      quando := (msg ->> 'quando')::timestamptz;
      feito := feito || ('mensagem ao cliente' || case when quando > now() + interval '2 minutes'
                then ' — sai ' || case when (quando at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
                                       then 'às ' else to_char(quando at time zone 'America/Sao_Paulo', 'DD/MM') || ' às ' end
                     || to_char(quando at time zone 'America/Sao_Paulo', 'HH24:MI') else '' end
                || case when msg ->> 'template' is not null then ' (template ' || (msg ->> 'template') || ')' else '' end)::text;
    else
      aviso := concat_ws(' ', aviso, 'A mensagem ao cliente NÃO saiu (' || (msg ->> 'motivo') || '): mande à mão pelo Chatwoot — está na Minha vez.');
    end if;
  end if;
  if c.id is not null and not tem_cw and c.telefone like '5500000000%' then
    aviso := concat_ws(' ', aviso, 'Telefone de teste: nada foi ao Chatwoot.');
  elsif c.id is null and p_momento in ('pedido', 'os_agendar', 'reagendar', 'biometria') then
    aviso := concat_ws(' ', aviso, 'Venda sem conversa no Chatwoot: avise o cliente por ligação.');
  end if;

  r := jsonb_strip_nulls(jsonb_build_object('ok', true, 'momento', p_momento, 'grupo', g, 'acoes', o,
         'feito', to_jsonb(feito), 'resumo', '✓ ' || array_to_string(feito, ', '), 'aviso', aviso,
         'mensagem', msg - 'texto', 'venda_id', v.id, 'conversa_id', c.id));
  if v.id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'backoffice', jsonb_strip_nulls(jsonb_build_object('momento', p_momento, 'resumo', r ->> 'resumo', 'aviso', aviso,
            'mensagem', msg ->> 'status', 'resultado', d ->> 'resultado')), auth.uid());
  end if;
  return r;
end;
$function$;

create or replace view public.v_jornada with (security_invoker = true) as
with cfg as (
  select coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15) as d_docs,
         (now() at time zone 'America/Sao_Paulo')::date as hoje
), conv as (
  select q.id, q.venda_id, q.nome, q.cidade, q.origem, q.plano_nome, q.coluna, q.itens_total, q.itens_validados,
         q.chatwoot_conversation_id, q.ultima_em, q.janela_24h_fecha_em, q.contatos_hoje, q.contatos_mes,
         c.chatwoot_agente, c.chatwoot_time, c.chatwoot_status, coalesce(c.humano_atribuido, false) as humano_atribuido,
         coalesce(c.nao_contatar, false) as nao_contatar, c.status as conv_status, c.handoff_motivo, c.handoff_em,
         l.ult_lead, l.ult_resp, l.ult_humano,
         s.minutos as sem_resp_min, s.desde as sem_resp_desde,
         al.tipo as alerta, al.em as alerta_em,
         bl.id as bloq_id, bl.motivo as bloq_motivo, bl.criada_em as bloq_em
    from public.v_mari_quadro q
    join public.mari_conversas c on c.id = q.id
    cross join lateral (
      select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
             max(t.created_at) filter (where t.papel in ('mari', 'humano')) as ult_resp,
             max(t.created_at) filter (where t.papel = 'humano') as ult_humano
        from public.mari_turnos t where t.conversa_id = q.id) l
    left join public.v_mari_sem_resposta s on s.id = q.id
    left join lateral (
      select case when t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)' then 'reclamacao'
                  when t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)' then 'desconto'
                  else 'nao_pedi' end as tipo,
             t.created_at as em
        from public.mari_turnos t
       where t.conversa_id = q.id and t.papel = 'lead' and t.created_at > now() - interval '7 days'
         and t.created_at > coalesce(l.ult_humano, '-infinity'::timestamptz)
         and t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente|descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos|n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))'
       order by t.created_at desc limit 1) al on true
    left join lateral (
      select a.id, coalesce(a.payload ->> 'rotulo', a.momento) || coalesce(' — ' || a.erro, '') as motivo, a.criada_em
        from public.chatwoot_acoes a
       where a.conversa_id = q.id and a.status = 'bloqueada' and a.criada_em > now() - interval '7 days'
       order by a.criada_em limit 1) bl on true
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
), sinal as (
  -- O que a conversa pede ao time (a mesma regra com ou sem venda). null = nada.
  select cv.*,
    case
      when cv.nao_contatar or cv.coluna = 'encerrada' then null
      when cv.bloq_id is not null then 'Mensagem não saiu (' || cv.bloq_motivo || ') · mandar à mão'
      when cv.sem_resp_min is not null then 'Cliente sem resposta há ' || cv.sem_resp_min || ' min (a Mari não respondeu)'
      when cv.alerta = 'reclamacao' then 'Reclamação ou já cliente Nio · humano agora'
      when cv.alerta = 'desconto' then 'Pediu desconto · humano responde (só a tabela da Nio)'
      when cv.alerta = 'nao_pedi' then '"Não pedi contato" · humano responde e encerra'
      when cv.conv_status = 'handoff_realizado' and coalesce(cv.handoff_motivo, '') not in ('dados_completos', 'recusa_compra', 'sem_cobertura', 'fora_de_area', 'sem_contato')
           and coalesce(cv.ult_humano, '-infinity'::timestamptz) < coalesce(cv.handoff_em, '-infinity'::timestamptz)
        then 'Pediu um consultor · ninguém do time falou ainda'
      when (cv.conv_status = 'handoff_realizado' or cv.humano_atribuido or cv.chatwoot_agente is not null)
           and cv.ult_lead > coalesce(cv.ult_resp, '-infinity'::timestamptz) and cv.ult_lead > now() - interval '7 days'
        then case when cv.coluna = 'retomada' then 'Voltou a falar depois do time · responder' else 'Cliente escreveu · responder' end
    end as alerta_txt,
    case
      when cv.bloq_id is not null then cv.bloq_em
      when cv.sem_resp_min is not null then cv.sem_resp_desde
      when cv.alerta is not null then cv.alerta_em
      when cv.conv_status = 'handoff_realizado' and coalesce(cv.ult_humano, '-infinity'::timestamptz) < coalesce(cv.handoff_em, '-infinity'::timestamptz) then cv.handoff_em
      else cv.ult_lead
    end as alerta_desde,
    -- dono: resolvida = sem dono (a Mari volta se o cliente escrever)
    case when cv.nao_contatar then null
         when cv.chatwoot_agente is not null then 'pessoa'
         when cv.humano_atribuido then 'pessoa'
         when cv.chatwoot_status = 'resolved' then null
         when cv.chatwoot_time is not null then 'time'
         else 'mari' end as dono_tipo,
    case when cv.nao_contatar then null
         when cv.chatwoot_agente is not null then cv.chatwoot_agente
         when cv.humano_atribuido then 'time (assumida)'
         when cv.chatwoot_status = 'resolved' then null
         when cv.chatwoot_time is not null then 'time ' || cv.chatwoot_time
         else 'Mari' end as dono_nome
  from conv cv
), vend as (
  select v.*, public.jornada_etapa(v.status, v.nio_pedido) as etapa,
         p.nome_curto as plano_curto, u.nome as vendedor_nome,
         pe.id as pend_id, pe.revisar_em as pend_revisar, pe.aberta_em as pend_desde, pm.nome as pend_nome,
         case pe.quem_destrava when 'nio' then 'Nio' when 'rogerio' then 'Rogério' when 'cliente' then 'cliente' else 'nosso time' end as pend_quem,
         s.id as conv_id, s.chatwoot_conversation_id as cw_id, s.alerta_txt, s.alerta_desde, s.bloq_id, s.dono_tipo as conv_dono_tipo, s.dono_nome as conv_dono_nome,
         (s.id is not null and coalesce(s.chatwoot_conversation_id, '') <> '' and coalesce(s.dono_tipo, 'mari') = 'mari' and not s.nao_contatar) as sem_dono,
         coalesce(v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days', false) as viab_ok
    from public.vendas v
    left join public.config_planos p on p.id = v.plano_id
    left join public.usuarios u on u.id = v.vendedor_id
    left join public.venda_pendencias pe on pe.venda_id = v.id and pe.encerrada_em is null
    left join public.config_motivos_pendencia pm on pm.codigo = pe.motivo
    left join lateral (select x.* from sinal x where x.venda_id = v.id order by x.ultima_em desc nulls last limit 1) s on true
), vr as (
  select vd.*, cfg.d_docs,
    case
      when vd.status = 'saida' then jsonb_build_array('fora', coalesce(vd.motivo_saida, 'Saída')
             || coalesce(' · volta ' || to_char(vd.interesse_futuro_em, 'DD/MM'), ''), null, null)
      when vd.alerta_txt is not null then jsonb_build_array('agora', vd.alerta_txt,
             case when vd.bloq_id is not null then 'manual' when vd.sem_dono then 'assumir' else 'responder' end, vd.alerta_desde)
      when vd.pend_id is not null and vd.pend_revisar <= cfg.hoje then jsonb_build_array('agora',
             '⏰ Revisar hoje: ' || coalesce(vd.pend_nome, 'pendência') || ' · ' || vd.pend_quem, 'pendencia', vd.pend_desde)
      when vd.pend_id is not null then jsonb_build_array('espera',
             '⏸ Aguardando ' || vd.pend_quem || ' · ' || coalesce(vd.pend_nome, 'pendência') || ' · revisar ' || to_char(vd.pend_revisar, 'DD/MM'), 'pendencia', vd.pend_desde)
      when vd.nio_venda_valida = false then jsonb_build_array('agora', 'A Nio marcou a venda como inválida · avisar o Ricardo', 'abrir', vd.nio_osab_em)
      -- etapa 2 · Lead qualificado (sempre precisa de ação)
      when vd.etapa = 2 and vd.origem = 'parceiro_pap' and vd.conferencia_status = 'pendente' then jsonb_build_array(
             case when vd.conferencia_prazo_ate < now() then 'agora' else 'hoje' end, 'Conferir a venda do parceiro', 'conferencia', vd.criado_em)
      when vd.etapa = 2 and vd.origem = 'parceiro_pap' and vd.conferencia_status in ('devolvida', 'reprovada') then jsonb_build_array('espera',
             case vd.conferencia_status when 'devolvida' then 'Devolvida ao parceiro · esperando correção' else 'Reprovada na conferência' end, 'abrir', vd.criado_em)
      when vd.etapa = 2 and vd.credito_resultado = 'negado' then jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'abrir', vd.credito_em)
      when vd.etapa = 2 and not vd.viab_ok then jsonb_build_array('hoje',
             case when vd.nio_viab_resultado in ('sem_viabilidade', 'nao_encontrado', 'posse') then 'Portal: ' ||
                    case vd.nio_viab_resultado when 'sem_viabilidade' then 'sem viabilidade' when 'nao_encontrado' then 'endereço não encontrado' else 'endereço já tem Nio' end
                    || ' · conferir no DFV: endereço viável a até 200 m → formulário da Nio + pendência'
                  when vd.nio_viab_resultado = 'viavel' then 'Viabilidade vencida (> 7 dias) · consultar de novo no portal'
                  else 'Consultar a viabilidade no portal' end,
             case when vd.sem_dono then 'assumir' else 'viabilidade' end, vd.criado_em)
      when vd.etapa = 2 then jsonb_build_array('hoje', 'Viável · abrir o pedido no portal e gravar o nº',
             case when vd.sem_dono then 'assumir' else 'pedido' end, coalesce(vd.nio_viab_em, vd.criado_em))
      -- etapa 3 · Pedido · biometria
      when vd.etapa = 3 and vd.biometria_status = 'validada' then jsonb_build_array('agora',
             'Biometria validada · abrir a OS e agendar (prazo 4 h) · há ' || public._h_txt(vd.biometria_validada_em), 'os_agendar', vd.biometria_validada_em)
      when vd.etapa = 3 and vd.credito_resultado = 'negado' then jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'biometria', vd.credito_em)
      when vd.etapa = 3 and vd.biometria_status = 'com_risco' then jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', vd.biometria_em)
      when vd.etapa = 3 and coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em) < now() - interval '72 hours' then jsonb_build_array('agora',
             'Link da biometria há ' || public._h_txt(coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em)) || ' · ligar para o cliente', 'biometria', coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em))
      when vd.etapa = 3 and coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em) < now() - interval '24 hours' then jsonb_build_array('hoje',
             'Link da biometria há ' || public._h_txt(coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em)) || ' · lembrar o cliente pela conversa', 'biometria', coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em))
      when vd.etapa = 3 then jsonb_build_array('espera', 'Esperando a biometria do cliente · link da Nio há ' || public._h_txt(coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em)),
             'biometria', coalesce(vd.biometria_link_enviado_em, vd.nio_pedido_em))
      -- etapa 4 · Venda · OS agendada
      when vd.etapa = 4 and vd.instalacao_agendada_para is null then jsonb_build_array('agora', 'Venda sem data de instalação · agendar', 'reagendar', vd.vendido_em)
      when vd.etapa = 4 and (vd.nio_pendencia_cod is not null or vd.nio_pendencia_desc is not null) then jsonb_build_array('hoje',
             left('Pendência Nio · ' || concat_ws(' · ', vd.nio_pendencia_cod, vd.nio_pendencia_desc), 90) || ' · reagendar', 'reagendar', coalesce(vd.nio_osab_em, vd.agendamento_registrado_em))
      when vd.etapa = 4 and (vd.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date < cfg.hoje then jsonb_build_array('hoje',
             'Instalação era ' || to_char(vd.instalacao_agendada_para at time zone 'America/Sao_Paulo', 'DD/MM') || ' e a Nio não deu baixa · conferir no portal', 'reagendar', vd.instalacao_agendada_para)
      when vd.etapa = 4 then jsonb_build_array('espera', 'Instalação ' || to_char(vd.instalacao_agendada_para at time zone 'America/Sao_Paulo', 'DD/MM')
             || case when coalesce(vd.instalacao_turno, '') = 'tarde' or extract(hour from vd.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12 then ' à tarde' else ' de manhã' end
             || ' · com a Nio', 'reagendar', vd.agendamento_registrado_em)
      -- etapa 5 · Instalada
      when vd.etapa = 5 and vd.status = '3_instalado' and vd.docs_entregues_em is null and vd.instalado_em is not null then jsonb_build_array(
             case when vd.instalado_em + make_interval(days => cfg.d_docs) < now() then 'agora' else 'hoje' end,
             'Documentos à Nio · prazo ' || to_char((vd.instalado_em + make_interval(days => cfg.d_docs)) at time zone 'America/Sao_Paulo', 'DD/MM') || ' (' || cfg.d_docs || ' dias)', 'docs', vd.instalado_em)
      else jsonb_build_array('ok', 'Instalada · conta na meta', 'abrir', coalesce(vd.ativado_em, vd.instalado_em))
    end as r
  from vend vd cross join cfg
)
select 'venda'::text as tipo, vr.id::text as chave, vr.id as venda_id, vr.conv_id as conversa_id, vr.cw_id as chatwoot_conversation_id,
       vr.cliente_nome as nome, vr.cidade, coalesce(vr.plano_curto, '') as plano, vr.origem,
       vr.etapa, public.jornada_nome(vr.etapa) as etapa_nome,
       (vr.r ->> 0) in ('agora', 'hoje') as precisa_acao, vr.r ->> 0 as nivel, vr.r ->> 1 as o_que_fazer, vr.r ->> 2 as botao,
       nullif(vr.r ->> 3, '')::timestamptz as desde,
       coalesce(vr.conv_dono_tipo, case when vr.vendedor_id is not null then 'pessoa' end) as dono_tipo,
       coalesce(vr.conv_dono_nome, vr.vendedor_nome) as dono_nome,
       vr.pend_id is not null as pendencia, vr.bloq_id as acao_id, vr.status as status_venda, 'dharma'::text as parceiro_id
  from vr
union all
select 'conversa', 'c:' || s.id::text, null::uuid, s.id, s.chatwoot_conversation_id,
       coalesce(nullif(initcap(split_part(btrim(coalesce(s.nome, '')), ' ', 1)), ''), 'Contato'), s.cidade, coalesce(s.plano_nome, ''), s.origem,
       1, public.jornada_nome(1),
       (s.alerta_txt is not null or s.coluna = 'completo'),
       case when s.alerta_txt is not null or s.coluna = 'completo' then 'agora' else 'espera' end,
       case when s.alerta_txt is not null then s.alerta_txt
            when s.coluna = 'completo' then 'Dados completos e a venda não nasceu · ver o erro na tela Mari'
            when s.dono_tipo in ('pessoa', 'time') then 'Com ' || s.dono_nome || ' · esperando o cliente'
            else 'Mari atendendo · ' || coalesce(s.itens_validados, 0) || '/' || coalesce(s.itens_total, 0) || ' dados' end,
       case when s.bloq_id is not null then 'manual' when s.dono_tipo = 'mari' or s.dono_tipo is null then 'assumir' else 'responder' end,
       case when s.alerta_txt is not null then s.alerta_desde when s.coluna = 'completo' then s.handoff_em else s.ultima_em end,
       s.dono_tipo, s.dono_nome, false, s.bloq_id, null::text, 'dharma'::text
  from sinal s
 where s.venda_id is null and s.coluna <> 'encerrada';

grant select on public.v_jornada to authenticated;
