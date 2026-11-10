-- NIOGEN | supabase/migrations/0096_os_e_agendar_separados.sql | 09/11/2026 — Claude Code
-- Ricardo (09/11 ~23h50, print da Minha vez): "Botão OS+Agendar está errado. São etapas diferentes."
--   · 'os' (novo): grava o nº da OS aberta no portal → status 1_vendido = VENDA (etapa 4 "Ativação/Agenda"). Exige pedido,
--     biometria validada e viabilidade do portal (trava). Chatwoot: tira "biometria-pendente" e deixa nota; mensagem ao cliente não.
--   · 'agendar': dia + período DEPOIS da OS → 2_aguardando_instalacao (etiqueta instalacao-agendada, nota, confirmação ao cliente,
--     resolve). 'reagendar' é o mesmo passo (alias). O prazo de 4 h continua contando da biometria validada.
--   · 'os_agendar' (os dois juntos, 0089) continua aceito para quem já usa.
--   · trava: 1_vendido não exige mais o agendamento; 2_aguardando exige o dia.
--   · v_jornada: botão 'os' na etapa 3 com biometria validada; 'agendar' na etapa 4 (sem data / pendência / reagendar).
--   · jornada_nome (Ricardo, 09/11 ~23h55): 1 Conversa · 2 Lead qualificado · 3 Biometria · 4 Ativação/Agenda · 5 Instalada.
--     funil_mes: "Vendas (OS aberta)".

CREATE OR REPLACE FUNCTION public.jornada_nome(p_etapa integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case p_etapa when 1 then 'Conversa' when 2 then 'Lead qualificado' when 3 then 'Biometria'
                      when 4 then 'Ativação/Agenda' when 5 then 'Instalada' else 'Saída' end
$function$;

CREATE OR REPLACE FUNCTION public.vendas_antes_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  mudou   boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  entrou  boolean;
begin
  if not mudou then
    return new;
  end if;
  entrou := vendida and (tg_op = 'INSERT' or old.status in ('0_qualificado', 'saida'));

  -- 0096: VENDA = pedido gravado → biometria validada → OS aberta no portal. O agendamento é o passo seguinte (2_aguardando).
  if entrou and coalesce(btrim(new.nio_pedido), '') = '' then
    raise exception 'Ainda não é venda: grave o nº do pedido do portal PAP.' using errcode = 'P0001';
  end if;
  if entrou and new.credito_resultado = 'negado' then
    raise exception 'Ainda não é venda: o crédito foi negado. Tente outro CPF (pendência) ou encerre.' using errcode = 'P0001';
  end if;
  if entrou and new.biometria_status is distinct from 'validada' then
    raise exception 'Ainda não é venda: a biometria do cliente ainda não foi validada pela Nio. Marque "Biometria validada" quando o portal mostrar.'
      using errcode = 'P0001';
  end if;
  if entrou and coalesce(btrim(new.nio_os), '') = '' then
    raise exception 'Ainda não é venda: falta o nº da OS (abra a OS no portal e grave o número).' using errcode = 'P0001';
  end if;
  if new.status = '2_aguardando_instalacao' and new.instalacao_agendada_para is null then
    raise exception 'Falta o dia e o período da instalação.' using errcode = 'P0001';
  end if;
  -- Viabilidade (0048): só a do PORTAL PAP, Viável e com menos de 7 dias. O DFV é pista e não libera.
  if entrou and not (new.nio_viab_resultado = 'viavel' and new.nio_viab_em >= now() - interval '7 days') then
    raise exception 'Ainda não é venda: falta a viabilidade do portal PAP (Viável, menos de 7 dias). Registre na ficha. O DFV é só pista.'
      using errcode = 'P0001';
  end if;
  if new.status = '2_aguardando_instalacao' and (tg_op = 'INSERT' or old.status in ('0_qualificado', '1_vendido', 'saida'))
     and new.biometria_status is distinct from 'validada' then
    raise exception 'Agendar só depois da biometria validada.' using errcode = 'P0001';
  end if;

  if new.status = 'saida' and coalesce(btrim(new.motivo_saida), '') = '' then
    raise exception 'Saída exige motivo.' using errcode = 'P0001';
  end if;

  if new.status = '1_vendido' then
    new.vendido_em := coalesce(new.vendido_em, now());
  elsif new.status = '2_aguardando_instalacao' then
    new.vendido_em := coalesce(new.vendido_em, now());
    new.agendamento_registrado_em := coalesce(new.agendamento_registrado_em, now());
  elsif new.status = '3_instalado' then
    new.instalado_em := coalesce(new.instalado_em, now());
  elsif new.status = '4_ativo_provisorio' then
    new.ativado_em := coalesce(new.ativado_em, now());
  end if;
  return new;
end;
$function$;

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
  v_tinha  boolean;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
  r        jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice usa os botões da venda.' using errcode = '42501';
  end if;
  if p_momento = 'reagendar' then p_momento := 'agendar'; end if;   -- 0096: agendar e reagendar são o mesmo passo
  if p_momento not in ('assumir', 'viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar', 'parar', 'devolver_mari') then
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
  if p_momento in ('viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar') and v.id is null then
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

  -- ── 0096 (Ricardo, 09/11: "São etapas diferentes"): OS aberta no portal = VENDA (etapa 4). Agendar vem depois. ──
  elsif p_momento = 'os' then
    v_os := btrim(coalesce(d ->> 'os', ''));
    if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
      raise exception 'Número da OS inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
    end if;
    if v.status <> '0_qualificado' then raise exception 'A OS já foi gravada nesta venda.'; end if;
    -- Uma atualização só: se a trava recusar (falta pedido, biometria, viabilidade…), nada fica gravado e a mensagem volta.
    update public.vendas set nio_os = v_os, status = '1_vendido' where id = v.id returning * into v;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os), auth.uid());
    feito := feito || ('VENDA · OS ' || v_os || ' · falta agendar')::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 OS nº ' || v_os || ' aberta no portal — VENDA. Falta agendar a instalação (prazo de 4 h da biometria) — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
    end if;

  -- ── OS + agendamento juntos (0089, mantido para quem já usa) · agendar / reagendar (depois da OS) ──
  elsif p_momento in ('os_agendar', 'agendar') then
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
        raise exception 'Agendar é depois da OS: grave antes o nº da OS aberta no portal.';
      end if;
      v_tinha := v.instalacao_agendada_para is not null;
      update public.vendas set
        instalacao_agendada_para = v_ts, instalacao_turno = v_turno, nio_pendencia_cod = null, nio_pendencia_desc = null,
        status = case when status = '1_vendido' then '2_aguardando_instalacao' else status end
      where id = v.id
      returning * into v;
      feito := feito || ('instalação ' || case when v_tinha then 'reagendada ' else 'agendada ' end || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end)::text;
    end if;
    if tem_cw then
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', case when p_momento = 'os_agendar' then '📅 OS nº ' || v_os || ' aberta e instalação agendada: ' when v_tinha then '📅 Instalação reagendada: ' else '📅 Instalação agendada: ' end
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
  elsif c.id is null and p_momento in ('pedido', 'os', 'os_agendar', 'agendar', 'biometria') then
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
 WITH cfg AS (
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
                    max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])) AS ult_resp,
                    max(t.created_at) FILTER (WHERE t.papel = 'humano'::text) AS ult_humano
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
    s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text AS precisa_acao,
        CASE
            WHEN s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text THEN 'agora'::text
            ELSE 'espera'::text
        END AS nivel,
        CASE
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
            WHEN s.alerta_txt IS NOT NULL THEN s.alerta_desde
            WHEN s.coluna = 'completo'::text THEN s.handoff_em
            ELSE s.ultima_em
        END AS desde,
    s.dono_tipo,
    s.dono_nome,
    false AS pendencia,
    s.bloq_id AS acao_id,
    NULL::text AS status_venda,
    'dharma'::text AS parceiro_id
   FROM sinal s
  WHERE s.venda_id IS NULL AND s.coluna <> 'encerrada'::text;

grant select on public.v_jornada to authenticated;

CREATE OR REPLACE FUNCTION public.funil_mes(p_mes date DEFAULT ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ini timestamptz := (date_trunc('month', p_mes)::timestamp) at time zone 'America/Sao_Paulo';
  fim timestamptz := ((date_trunc('month', p_mes) + interval '1 month')::timestamp) at time zone 'America/Sao_Paulo';
  teste text[];
begin
  if public.meu_perfil() is null then raise exception 'Sem acesso.' using errcode = '42501'; end if;
  select coalesce(array_agg(public.tel_norm(x)), '{}') into teste
    from unnest(regexp_split_to_array((select coalesce(texto, '') from public.config_mari_textos where chave = 'telefones_teste'), '[^0-9]+')) x
   where x <> '';
  return (
    with vv as (
      select v.* from public.vendas v
       where not (coalesce(public.tel_norm(v.cliente_whatsapp), '') = any (teste))
         and not exists (select 1 from public.mari_conversas mt where mt.venda_id = v.id and public.tel_norm(mt.telefone) = any (teste))
    )
    select jsonb_build_object('mes', to_char(p_mes, 'YYYY-MM'), 'etapas', jsonb_build_array(
      jsonb_build_object('id', 'leads', 'nome', 'Conversas', 'dica', 'Conversas novas com a Mari no WhatsApp (sem testes) — etapa 1',
        'n', (select count(*) from public.mari_conversas c where c.canal = 'whatsapp' and c.telefone not like '5500000000%'
               and not (public.tel_norm(c.telefone) = any (teste)) and c.created_at >= ini and c.created_at < fim)),
      jsonb_build_object('id', 'qualificados', 'nome', 'Leads qualificados', 'dica', 'Dados completos (etapa 2) — ainda NÃO é venda',
        'n', (select count(*) from vv where vv.criado_em >= ini and vv.criado_em < fim)),
      jsonb_build_object('id', 'viabilidade', 'nome', 'Viabilidade ok', 'dica', 'Portal PAP respondeu Viável',
        'n', (select count(*) from vv where vv.nio_viab_resultado = 'viavel' and vv.nio_viab_em >= ini and vv.nio_viab_em < fim)),
      jsonb_build_object('id', 'pedidos', 'nome', 'Pedidos', 'dica', 'Pedido gravado no portal (etapa 3) — a Nio manda o link da biometria',
        'n', (select count(*) from vv where vv.nio_pedido_em >= ini and vv.nio_pedido_em < fim)),
      jsonb_build_object('id', 'biometria', 'nome', 'Biometria ok', 'dica', 'Biometria validada pela Nio',
        'n', (select count(*) from vv where vv.biometria_validada_em >= ini and vv.biometria_validada_em < fim)),
      jsonb_build_object('id', 'vendas', 'nome', 'Vendas (OS aberta)', 'dica', 'VENDA = OS aberta no portal depois da biometria (etapa 4); o agendamento vem em seguida',
        'n', (select count(*) from vv where vv.vendido_em >= ini and vv.vendido_em < fim and coalesce(vv.nio_os, '') <> '')),
      jsonb_build_object('id', 'instaladas', 'nome', 'Instaladas', 'dica', 'Baixa da Nio no OSAB (etapa 5) — é o que paga comissão e conta na meta',
        'n', (select count(*) from vv where vv.instalado_em >= ini and vv.instalado_em < fim and vv.status <> 'saida')),
      jsonb_build_object('id', 'ativas', 'nome', 'Ativas', 'dica', 'Serviço ativado',
        'n', (select count(*) from vv where vv.ativado_em >= ini and vv.ativado_em < fim and vv.status <> 'saida'))
    )));
end;
$function$;
