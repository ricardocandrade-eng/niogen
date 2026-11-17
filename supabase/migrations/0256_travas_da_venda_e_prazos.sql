-- NIOGEN | supabase/migrations/0256_travas_da_venda_e_prazos.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 17/11 ("Sim"): as regras novas que cabem no sistema de hoje, antes do passo 4 (porta única). Regras da seção 10 do
-- diagnóstico. A extensão grava pelo mesmo backoffice_momento (os_agendar), então as travas valem para a ficha e para ela (regra 8).
--   D11 vendas_transicao: OS (0_qualificado → 1_vendido/2_aguardando_instalacao) só com biometria validada ou dispensada.
--       Exceção só do admin: ⋯ › Mover para, com motivo (niogen.transicao_ok). O robô do portal (_portal_aplicar) também passa.
--   D4  vendas_transicao: crédito aprovado só no cartão → a OS tem de ser no cartão.
--       backoffice_momento: o GED360 passa a ser lido ANTES de gravar a OS (os e os_agendar), para a trava ver a aprovação que ele já viu.
--   D16 venda_trocar_titular: depois da OS, recusa (é Saída desta venda e venda nova).
--   C2  v_leads: handoff da Mari "pediu humano / objeção / urgência" sem venda → status "pediu_humano", vez do time, prazo 30 min.
--   E3  v_leads: cliente respondeu "Preciso remarcar" depois do último agendamento → status "remarcar", vez do time, 4 h
--       (some quando o time reagenda).
-- Funções e view recriadas a partir das que estão no ar (cópia conferida). Regra 20: nenhum estado novo (status calculado).
-- Cenários: D11, D4, D16, C2, E3 + o portão inteiro.
begin;

insert into public.config_lead (parceiro_id, tipo, codigo, nome, ordem, etapa, vez, prazo_horas, ajuda) values
  ('dharma', 'status', 'pediu_humano', 'Pediu uma pessoa', 2, 'atendimento', 'time', 0.5,
   'O cliente pediu para falar com uma pessoa (ou fez objeção, ou é urgente). Responda em até 30 min: assuma e fale com ele.'),
  ('dharma', 'status', 'remarcar', 'Pediu para remarcar', 11, 'instalacao', 'time', 4,
   'O cliente respondeu "Preciso remarcar" ao aviso da instalação. Combine o novo dia e grave em Reagendar (o NIOGEN avisa o cliente). A Mari não promete data.')
on conflict do nothing;

CREATE OR REPLACE FUNCTION public.vendas_transicao()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  de   text := old.status;
  para text := new.status;
  ok   boolean;
begin
  if de is not distinct from para then return new; end if;
  -- função do banco que assumiu a mudança (venda_mover_admin, _portal_aplicar): vale para esta transação só
  if coalesce(current_setting('niogen.transicao_ok', true), '') <> '' then return new; end if;
  ok := case de
    when '0_qualificado'           then para in ('1_vendido', '2_aguardando_instalacao', 'saida')
    when '1_vendido'               then para in ('2_aguardando_instalacao', '3_instalado', 'saida')
    when '2_aguardando_instalacao' then para in ('3_instalado', 'saida')
    when '3_instalado'             then para in ('4_ativo_provisorio')
    when '4_ativo_provisorio'      then para in ('5_comissao_firme')
    when 'saida'                   then para in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
    else false end;
  -- 0256 (D11, Ricardo 17/11): OS (venda contada) só com a biometria aprovada — vale para a ficha, a extensão e qualquer caminho.
  -- Só o admin libera, pelo menu ⋯ › Mover para, com o motivo (essa função marca niogen.transicao_ok e passa acima).
  if ok and de = '0_qualificado' and para in ('1_vendido', '2_aguardando_instalacao')
     and coalesce(new.biometria_status, '') not in ('validada', 'dispensada') then
    raise exception 'A OS só pode ser gravada com a biometria aprovada (hoje: %). Grave a biometria antes; exceção só pelo admin (⋯ › Mover para, com o motivo).',
      coalesce(new.biometria_status, 'não enviada') using errcode = 'P0001';
  end if;
  -- 0256 (D4/D15): crédito aprovado só no cartão → a OS tem de ser no cartão
  if ok and de = '0_qualificado' and para in ('1_vendido', '2_aguardando_instalacao')
     and new.credito_resultado = 'so_cartao' and coalesce(new.forma_pagamento, '') <> 'cartao' then
    raise exception 'O crédito foi aprovado só no cartão: a forma de pagamento da OS tem de ser cartão (hoje: %).',
      coalesce(new.forma_pagamento, 'não informada') using errcode = 'P0001';
  end if;
  if not ok then
    raise exception 'Essa mudança de etapa não pode ser feita direto (de % para %). Voltar ou pular degrau é só do admin, pelo menu ⋯ › Mover para, com o motivo.',
      public._status_nome(de), public._status_nome(para) using errcode = 'P0001';
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
  v_igual  boolean := false;   -- 0251 (D14): reagendar para o mesmo dia e turno não muda nada
  v_forma  text;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
  r        jsonb;
  v_bio    public.nio_biometria;   -- 0246: biometria que o GED360 já viu antes da OS
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
    v_tinha := coalesce(v.credito_resultado, '') in ('aprovado', 'so_cartao') or coalesce(btrim(v.nio_pedido), '') <> '';
    update public.vendas set credito_resultado = v_res where id = v.id;
    feito := feito || ('crédito ' || case v_res when 'aprovado' then 'aprovado' when 'so_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente' else 'negado' end)::text;
    -- 0247 (Ricardo, 16/11): ordem do portal = crédito → biometria (link da Nio, aprovada) → forma de pagamento → agenda → OS.
    if v_res in ('aprovado', 'so_cartao') and v.status = '0_qualificado' and not v_tinha then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'credito_aprovado_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'resultado', v_res), auth.uid());
      feito := feito || 'próximo: a biometria (link da Nio); aprovada, forma de pagamento, agenda e OS no portal'::text;
      if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
        aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
      end if;
    end if;
    if v_res = 'negado' then
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
    end if;
    -- 0246 (caso Queroly, 16/11): o mesmo resultado gravado de novo (ficha e depois extensão) não repete a nota.
    if tem_cw and v_res = coalesce(v.credito_resultado, '') and exists (
         select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.momento = 'credito' and pa.tipo = 'nota'
            and pa.status <> 'cancelada' and pa.criada_em > now() - interval '12 hours') then
      feito := feito || 'nota já estava no Chatwoot'::text;
    elsif tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '💳 Crédito no portal: ' || case v_res when 'aprovado' then 'aprovado — próximo: biometria (link da Nio); aprovada, forma de pagamento, agenda e OS' when 'so_cartao' then 'aprovado só no cartão — próximo: biometria; aprovada, agenda e OS (cartão)' when 'pendente' then 'pendente (24 h)' else 'negado — pedido outro CPF' end
        || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
      if v_res = 'negado' then
        o := o + 1;
        -- 0224 (Ricardo, caso Lucas Heleno 15/11): conversa com uma pessoa do time ou pedido já feito nas últimas 24 h → sem mensagem
        -- automática (saía na voz da Mari no meio da conversa do time e repetia depois do "não aprovou").
        if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or v.status = 'saida'
           or exists (select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.payload ->> 'rotulo' = 'pedido de outro CPF'
                       and pa.status <> 'cancelada' and pa.criada_em > now() - interval '24 hours') then
          aviso := concat_ws(' ', aviso, 'A conversa está com você (ou o pedido de outro CPF já saiu hoje): fale com o cliente pela conversa.');
        else
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        end if;
      end if;
    end if;
    if v_res = 'so_cartao' and coalesce(v.forma_pagamento, '') <> 'cartao' then
      aviso := 'Aprovado só no cartão: troque a forma de pagamento na ficha (Detalhes › Plano, valor e pagamento › Trocar).';
    end if;

  -- ── biometria (Validada · Risco · Negado) — etapa 3 ──
  elsif p_momento = 'biometria' then
    if coalesce(btrim(v.nio_pedido), '') = '' and coalesce(v.credito_resultado, '') not in ('aprovado', 'so_cartao') then
      raise exception 'Grave antes o crédito aprovado: a biometria vem do link que a Nio manda depois do crédito.';
    end if;
    v_res := d ->> 'resultado';
    if v_res = 'validada' then
      update public.vendas set biometria_status = 'validada' where id = v.id;
      -- 0191: a mensagem ao cliente sai pela cadência da Mari (cartão: aviso do cadastro do cartão; boleto: confirmação da instalação).
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria validada · a Nio manda o link do cartão e a Mari avisa o cliente'
                             else 'biometria validada · a Mari confirma a instalação ao cliente' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✅ Biometria validada — ' || quem || ', ' || agora_t || '. '
            || case when v.forma_pagamento = 'cartao' then 'Cartão: a Nio manda o link do cadastro do cartão; a visita depende dele.'
                    else 'A Mari confirma a instalação ao cliente.' end));
        feito := feito || 'etiqueta'::text || 'nota'::text;
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
        -- 0224 (Ricardo, caso Lucas Heleno 15/11): conversa com uma pessoa do time ou pedido já feito nas últimas 24 h → sem mensagem
        -- automática (saía na voz da Mari no meio da conversa do time e repetia depois do "não aprovou").
        if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or v.status = 'saida'
           or exists (select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.payload ->> 'rotulo' = 'pedido de outro CPF'
                       and pa.status <> 'cancelada' and pa.criada_em > now() - interval '24 hours') then
          aviso := concat_ws(' ', aviso, 'A conversa está com você (ou o pedido de outro CPF já saiu hoje): fale com o cliente pela conversa.');
        else
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        end if;
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'dispensada' then
      -- 0196 (Ricardo, 14/11): com o sistema de biometria fora do ar a Nio libera a venda sem biometria. Vale como aprovada
      -- (comissão normal; no cartão, o link do cadastro do cartão sai logo). O time marca por venda, com motivo e autor.
      if coalesce(btrim(v.nio_os), '') = '' and coalesce(v.credito_resultado, '') not in ('aprovado', 'so_cartao') then
        raise exception 'A dispensa da biometria é depois do crédito aprovado.';
      end if;
      if v.biometria_status = 'validada' then raise exception 'A biometria desta venda já está validada.'; end if;
      update public.vendas set biometria_status = 'validada', biometria_dispensada_em = now(), biometria_dispensada_por = auth.uid(),
             biometria_dispensa_motivo = coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar')
       where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'biometria_dispensada', jsonb_build_object('motivo', coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar'),
              'queda_id', (select q.id from public.biometria_quedas q where q.fim is null order by q.inicio desc limit 1)), auth.uid());
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria dispensada pela Nio · a Mari avisa do cadastro do cartão'
                             else 'biometria dispensada pela Nio · a Mari confirma a instalação' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🟢 Biometria dispensada pela Nio (sistema de biometria fora do ar) — ' || quem || ', ' || agora_t || '. Vale como aprovada.'));
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    else
      raise exception 'Biometria: use validada, dispensada, risco ou negado.';
    end if;

  -- ── 0096 (Ricardo, 09/11: "São etapas diferentes"): OS aberta no portal = VENDA (etapa 4). Agendar vem depois. ──
  elsif p_momento = 'os' then
    v_os := btrim(coalesce(d ->> 'os', ''));
    if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
      raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
    end if;
    if v.status <> '0_qualificado' then raise exception 'A OS já foi gravada nesta venda.'; end if;
    -- Uma atualização só: se a trava recusar (falta pedido, biometria, viabilidade…), nada fica gravado e a mensagem volta.
    -- 0247: "Gravar venda" = só o nº da OS (e a forma de pagamento do portal, se mudou). A agenda vem da Consulta OS (operador).
    v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
    if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
    -- 0256: o GED360 é lido ANTES de gravar a OS — a trava da biometria (vendas_transicao) já enxerga a aprovação que ele viu.
    v_bio := public._ged360_da_venda(v.id);
    if v_bio.protocolo is not null then
      update public.vendas set biometria_link_enviado_em = coalesce(least(v_bio.primeira_leitura, v_bio.data_envio), biometria_link_enviado_em)
       where id = v.id;
      perform public._ged360_aplicar(v_bio);
      select * into v from public.vendas where id = v.id;
    end if;
    update public.vendas set nio_os = v_os, nio_pedido = v_os, status = '1_vendido', forma_pagamento = coalesce(v_forma, forma_pagamento)
     where id = v.id returning * into v;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'forma', v.forma_pagamento, 'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha')), auth.uid());
    feito := feito || ('VENDA · pedido (OS) ' || v_os || ' · a agenda vem da Consulta OS')::text;
    -- 0246 (caso Queroly, 16/11): o portal pode mandar a biometria ANTES da OS. Se o GED360 já viu o link, a hora é a dele,
    -- a aprovação vale agora e o cliente não recebe "a Nio acabou de te mandar o link".
    if v_bio.protocolo is not null then
      feito := feito || ('o link da biometria saiu às ' || to_char(least(v_bio.primeira_leitura, v_bio.data_envio) at time zone 'America/Sao_Paulo', 'HH24:MI')
                         || case when v.biometria_status = 'validada' then ' · aprovada' else '' end)::text;
    end if;
    if tem_cw then
      if v.biometria_status is distinct from 'validada' then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
      end if;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 Pedido (OS) nº ' || v_os || ' aberto no portal — VENDA. '
          || case when v.biometria_status = 'validada' then 'Biometria já aprovada. '
                  when v_bio.protocolo is not null then 'O link da biometria já tinha saído. '
                  else 'A Nio manda o link da biometria. ' end
          || 'A agenda vem da Consulta OS (o robô lê em instantes) — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
      if coalesce((d ->> 'sem_aviso')::boolean, false) or v.biometria_status = 'validada' or v_bio.protocolo is not null then
        feito := feito || 'sem aviso da biometria ao cliente'::text;
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                   'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do link da biometria');
      end if;
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
        raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
      end if;
      if v.status <> '0_qualificado' then raise exception 'A OS já foi aberta: use Reagendar.'; end if;
      -- 0191 (Ricardo, 14/11): a forma de pagamento escolhida no portal vem junto (pode ter mudado da conversa).
      v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
      if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
      -- 0256: o GED360 é lido ANTES de gravar a OS — a trava da biometria (vendas_transicao) já enxerga a aprovação que ele viu.
      v_bio := public._ged360_da_venda(v.id);
      if v_bio.protocolo is not null then
        update public.vendas set biometria_link_enviado_em = coalesce(least(v_bio.primeira_leitura, v_bio.data_envio), biometria_link_enviado_em)
         where id = v.id;
        perform public._ged360_aplicar(v_bio);
        select * into v from public.vendas where id = v.id;
      end if;
      -- Uma atualização só: se a trava recusar (falta crédito, viabilidade…), nada fica gravado e a mensagem volta.
      update public.vendas set
        nio_os = v_os, nio_pedido = v_os, instalacao_agendada_para = v_ts, instalacao_turno = v_turno,
        forma_pagamento = coalesce(v_forma, forma_pagamento),
        nio_pendencia_cod = null, nio_pendencia_desc = null, status = '2_aguardando_instalacao'
      where id = v.id
      returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'dia', v_dia, 'turno', v_turno, 'forma', v.forma_pagamento,
              'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha')), auth.uid());
      feito := feito || ('VENDA · OS ' || v_os || ' · instalação ' || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end
                         || ' · a Nio manda o link da biometria')::text;
    else
      if v.status not in ('1_vendido', '2_aguardando_instalacao') then
        raise exception 'Agendar é depois da OS: grave antes o nº do pedido (OS) do portal.';
      end if;
      v_tinha := v.instalacao_agendada_para is not null;
      v_igual := v.instalacao_agendada_para = v_ts and coalesce(v.instalacao_turno, '') = v_turno and v.status = '2_aguardando_instalacao';
      update public.vendas set
        instalacao_agendada_para = v_ts, instalacao_turno = v_turno, nio_pendencia_cod = null, nio_pendencia_desc = null,
        status = case when status = '1_vendido' then '2_aguardando_instalacao' else status end
      where id = v.id
      returning * into v;
      feito := feito || (case when v_igual then 'nada mudou: a instalação já estava em ' else 'instalação ' || case when v_tinha then 'reagendada ' else 'agendada ' end end
                         || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end
                         || case when v_igual then ' — nada foi ao cliente' else '' end)::text;
    end if;
    if tem_cw and p_momento = 'os_agendar' then
      -- 0191: OS gravada = a Nio manda o link da biometria. O aviso ao cliente é o da biometria (com a data pré-agendada);
      -- a confirmação da instalação (C2) sai pela cadência depois da biometria aprovada (no cartão, depois do cadastro do cartão).
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        case when v.biometria_status = 'validada' then jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente'))
             else jsonb_build_object('add', jsonb_build_array('biometria-pendente', 'instalacao-agendada')) end);
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 OS nº ' || v_os || ' aberta — VENDA. Instalação pré-agendada: ' || v_diatxt || ', ' || v_pertxt
          || case when v.biometria_status = 'validada' then '. Biometria já aprovada' when v_bio.protocolo is not null then '. O link da biometria já tinha saído'
                  else '. A Nio manda o link da biometria' end
          || case when v.forma_pagamento = 'cartao' then '; depois dela, o link do cadastro do cartão' else '' end
          || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if coalesce((d ->> 'sem_aviso')::boolean, false) or v_bio.protocolo is not null then
        feito := feito || case when v_bio.protocolo is not null then 'sem aviso da biometria (o link já tinha saído; a confirmação da instalação sai pela cadência)'
                               else 'sem aviso ao cliente (o time já avisou)' end::text;
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_os_biometria',
                 jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
                 'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso da OS e da biometria');
        -- 0254 (D13): não resolve mais (ver o agendar abaixo).
      end if;
    elsif tem_cw and not v_igual then
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
        -- 0254 (D13): agendar NÃO resolve mais a conversa. A 0085 resolvia para a 24387 tirar o dono; desde a regra
        -- "resolvida sem Saída reabre" (venda viva) o Chatwoot reabria 1 min depois e a 24389/24390 devolviam o time — o fim era
        -- o mesmo, mas a pessoa que conduzia perdia a conversa e ficava a nota "o NIOGEN reabriu". Agora o dono fica.
      end if;
    end if;

  -- ── cliente pediu para parar ──
  elsif p_momento = 'parar' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    perform public.mari_cadencia_parar(c.id, p_resolvida => not (v.id is not null and v.status <> 'saida'), p_nao_contatar => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente pediu para parar — marcado no NIOGEN por ' || quem || ']', false);
    feito := feito || 'não contatar'::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('nao-contatar')));
      o := o + 1;
      -- 0252 (H1): com venda viva a venda segue — a conversa fica com o time, aberta, sem mensagem automática nenhuma.
      if v.id is not null and v.status <> 'saida' then
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. A venda SEGUE: nenhuma mensagem automática '
            || '(nem aviso da venda). Falar com o cliente só se ele escrever. Se ele quiser desistir da compra, use Saída ▾.'));
        feito := feito || 'etiqueta'::text || 'nota'::text || 'a venda segue, sem mensagens'::text;
      else
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. Nunca mais chamar.'));
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'));
        feito := feito || 'etiqueta'::text || 'nota'::text || 'conversa resolvida'::text;
      end if;
    end if;

  -- ── devolver para a Mari ──
  elsif p_momento = 'devolver_mari' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    -- 0155: em handoff a Mari fica calada; devolver fecha o ciclo (status ativo, etapa retomada) sem marcar "resolvida"
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'devolvida para a Mari no NIOGEN por ' || quem);
    end if;
    update public.mari_conversas set chatwoot_resolvida = false where id = c.id and coalesce(funil_destino, 'em_andamento') = 'em_andamento';
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
    if msg ->> 'status' = 'repetida' then
      feito := feito || 'mensagem ao cliente não repetida (a mesma já saiu nas últimas 12 h)'::text;
    elsif msg ->> 'status' = 'pendente' then
      quando := (msg ->> 'quando')::timestamptz;
      feito := feito || ('mensagem ao cliente' || case when quando > now() + interval '2 minutes'
                then ' — sai ' || case when (quando at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
                                       then 'às ' else to_char(quando at time zone 'America/Sao_Paulo', 'DD/MM') || ' às ' end
                     || to_char(quando at time zone 'America/Sao_Paulo', 'HH24:MI') else '' end
                || case when msg ->> 'template' is not null then ' (template ' || (msg ->> 'template') || ')' else '' end)::text;
    else
      aviso := concat_ws(' ', aviso, 'A mensagem ao cliente NÃO saiu (' || (msg ->> 'motivo') || '): mande à mão pelo Chatwoot — está no Live.');
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

CREATE OR REPLACE FUNCTION public.venda_trocar_titular(p_venda uuid, p_nome text, p_cpf text, p_relacao text, p_motivo text DEFAULT NULL::text, p_credito text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v    public.vendas;
  doc  text := public._so_digitos(p_cpf);
  nome text := upper(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g')));
  rel  text := btrim(coalesce(p_relacao, ''));
  soltas int := 0;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice troca o titular.' using errcode = '42501';
  end if;
  if not public._cpf_ok(doc) then raise exception 'CPF do novo titular inválido (confira os dígitos).' using errcode = 'P0001'; end if;
  if length(nome) < 5 or nome !~ ' ' then raise exception 'Nome completo do novo titular (como saiu na Receita).' using errcode = 'P0001'; end if;
  if length(rel) < 2 then raise exception 'Diga o parentesco do titular com quem conversa (pai, mãe, filho, cônjuge…).' using errcode = 'P0001'; end if;
  if p_credito is not null and p_credito not in ('aprovado', 'so_cartao', 'pendente', 'negado') then
    raise exception 'Resultado de crédito inválido.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  -- 0256 (D16, Ricardo 17/11): depois da OS, trocar o titular é Saída desta venda e venda nova (a OS é do CPF antigo)
  if v.status <> '0_qualificado' or nullif(btrim(coalesce(v.nio_os, '')), '') is not null then
    raise exception 'Depois da OS não se troca o titular: dê Saída nesta venda (cancelando a OS no portal) e abra uma venda nova com o novo titular.' using errcode = 'P0001';
  end if;
  if public._so_digitos(v.cliente_cpf_cnpj) = doc then raise exception 'Esse já é o CPF do titular desta venda.' using errcode = 'P0001'; end if;

  update public.vendas set
    titular_anterior = jsonb_build_object('nome', v.cliente_nome, 'cpf_cnpj', v.cliente_cpf_cnpj, 'credito', v.credito_resultado,
                                          'credito_em', v.credito_em, 'ate', now()),
    contato_nome = coalesce(contato_nome, v.cliente_nome),
    contato_relacao = rel,
    cliente_nome = nome,
    cliente_cpf_cnpj = doc,
    credito_resultado = p_credito,
    credito_em = case when p_credito is null then null else now() end,
    titular_trocado_em = now(),
    titular_trocado_por = auth.uid()
  where id = v.id;

  -- As biometrias do CPF antigo deixam de valer para esta venda (o próximo GED360 casa as do titular novo pelo CPF).
  update public.nio_biometria set venda_id = null where venda_id = v.id and cpf_cnpj is distinct from doc;
  get diagnostics soltas = row_count;

  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'titular_trocado', jsonb_build_object('de', v.cliente_nome, 'para', nome, 'relacao', rel,
          'motivo', nullif(btrim(coalesce(p_motivo, '')), ''), 'credito', p_credito, 'biometrias_soltas', soltas), auth.uid());

  -- Casa já as biometrias do titular novo que o GED360 leu antes da troca (o mapa aplica na próxima leitura).
  update public.nio_biometria set venda_id = v.id, ultima_leitura = now()
   where venda_id is null and cpf_cnpj = doc and data_envio > now() - interval '15 days';

  -- 0255 (B10): titular novo com crédito aprovado → a pendência "outro CPF" destravou (antes ficava aberta: cadência pausada e cobrança na Live)
  if p_credito in ('aprovado', 'so_cartao') then
    with f as (
      update public.venda_pendencias
         set encerrada_em = now(), encerrada_por = auth.uid(), resultado = 'destravou',
             nota_encerramento = 'titular trocado para ' || nome || ' com crédito ' || p_credito
       where venda_id = v.id and motivo = 'credito_outro_cpf' and encerrada_em is null
      returning id, aberta_em)
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    select v.id, 'pendencia', jsonb_build_object('acao', 'encerrada', 'pendencia_id', f.id, 'motivo', 'credito_outro_cpf',
           'resultado', 'destravou', 'nota', 'titular novo com crédito ' || p_credito,
           'dias', ((now() at time zone 'America/Sao_Paulo')::date - (f.aberta_em at time zone 'America/Sao_Paulo')::date)), auth.uid()
      from f;
  end if;

  return jsonb_build_object('ok', true, 'titular', nome, 'contato', coalesce(v.contato_nome, v.cliente_nome), 'relacao', rel);
end;
$function$;

create or replace view public.v_leads with (security_invoker = true) as
 WITH par AS (
         SELECT c_1.id AS conversa_id,
            v_1.id AS venda_id,
            row_number() OVER (PARTITION BY (COALESCE(v_1.id::text, c_1.id::text)) ORDER BY c_1.ultima_msg_lead_at DESC NULLS LAST, c_1.created_at DESC) AS rn
           FROM ( SELECT mari_conversas.id,
                    mari_conversas.telefone,
                    mari_conversas.nome_contato,
                    mari_conversas.nome_confiavel,
                    mari_conversas.canal,
                    mari_conversas.chatwoot_conversation_id,
                    mari_conversas.status,
                    mari_conversas.etapa,
                    mari_conversas.cep,
                    mari_conversas.numero,
                    mari_conversas.complemento,
                    mari_conversas.endereco_cep,
                    mari_conversas.cidade,
                    mari_conversas.uf,
                    mari_conversas.cluster,
                    mari_conversas.dentro_area,
                    mari_conversas.segmento,
                    mari_conversas.mei,
                    mari_conversas.elegibilidade,
                    mari_conversas.dfv_resultado,
                    mari_conversas.dfv_detalhe,
                    mari_conversas.plano_escolhido,
                    mari_conversas.forma_pagamento,
                    mari_conversas.visita_preferencia,
                    mari_conversas.dados,
                    mari_conversas.lgpd_enviada,
                    mari_conversas.upsell_oferecido,
                    mari_conversas.nao_contatar,
                    mari_conversas.ultima_msg_lead_at,
                    mari_conversas.followup_next_at,
                    mari_conversas.followup_count,
                    mari_conversas.agendamento_retorno,
                    mari_conversas.origem,
                    mari_conversas.handoff_motivo,
                    mari_conversas.handoff_em,
                    mari_conversas.venda_id,
                    mari_conversas.ultima_entrada_ts,
                    mari_conversas.processando_ate,
                    mari_conversas.created_at,
                    mari_conversas.updated_at,
                    mari_conversas.ultima_msg_mari_at,
                    mari_conversas.cadencia_passo,
                    mari_conversas.cadencia_passo_em,
                    mari_conversas.cadencia_proximo_em,
                    mari_conversas.cadencia_retorno_em,
                    mari_conversas.visita_confirmada_para,
                    mari_conversas.humano_atribuido,
                    mari_conversas.time_atribuido,
                    mari_conversas.chatwoot_resolvida,
                    mari_conversas.handoff_briefing,
                    mari_conversas.nio_viab_resultado,
                    mari_conversas.nio_viab_velocidade,
                    mari_conversas.nio_viab_interesse_id,
                    mari_conversas.nio_viab_em,
                    mari_conversas.instalacao_preferencia,
                    mari_conversas.nio_viab_endereco_portal,
                    mari_conversas.bio_lembrete_em,
                    mari_conversas.instalacao_avisada_para,
                    mari_conversas.instalacao_avisada_em,
                    mari_conversas.instalacao_lembrada_para,
                    mari_conversas.ciclos_encerrados,
                    mari_conversas.ciclo_anterior,
                    mari_conversas.chatwoot_status,
                    mari_conversas.chatwoot_agente,
                    mari_conversas.chatwoot_time,
                    mari_conversas.chatwoot_etiquetas,
                    mari_conversas.chatwoot_sync_em,
                    mari_conversas.etiqueta_futuro_em,
                    mari_conversas.etiqueta_futuro_para,
                    mari_conversas.quadro_encerrada_motivo,
                    mari_conversas.quadro_encerrada_em,
                    mari_conversas.quadro_encerrada_por,
                    mari_conversas.espera_ate,
                    mari_conversas.espera_motivo,
                    mari_conversas.espera_em,
                    mari_conversas.espera_por,
                    mari_conversas.cobertura_decisao,
                    mari_conversas.cobertura_detalhe,
                    mari_conversas.cobertura_em,
                    mari_conversas.viab_consultas,
                    mari_conversas.nio_pedido_aberto,
                    mari_conversas.nio_pedido_aberto_em,
                    mari_conversas.dup_consultas,
                    mari_conversas.credito_autorizado_em,
                    mari_conversas.credito_autorizacao_frase,
                    mari_conversas.credito_recusado_em,
                    mari_conversas.credito_resultado,
                    mari_conversas.credito_formas,
                    mari_conversas.credito_em,
                    mari_conversas.credito_consultas,
                    mari_conversas.dispensada_em,
                    mari_conversas.dispensada_por,
                    mari_conversas.funil_etapa,
                    mari_conversas.funil_destino,
                    mari_conversas.funil_detalhe,
                    mari_conversas.funil_destino_em,
                    mari_conversas.funil_evento,
                    mari_conversas.funil_alerta,
                    mari_conversas.funil_alerta_em,
                    mari_conversas.saida_motivo,
                    mari_conversas.saida_sub,
                    mari_conversas.saida_volta_em,
                    mari_conversas.saida_em
                   FROM mari_conversas
                  WHERE mari_conversas.canal = 'whatsapp'::text) c_1
             FULL JOIN vendas v_1 ON v_1.id = c_1.venda_id
        )
 SELECT COALESCE(p.venda_id::text, 'c:'::text || p.conversa_id::text) AS lead_id,
    p.conversa_id,
    p.venda_id,
    'dharma'::text AS parceiro_id,
    COALESCE(NULLIF(btrim(v.cliente_nome), ''::text), NULLIF(btrim(c.dados ->> 'nome'::text), ''::text), NULLIF(btrim(c.nome_contato), ''::text), 'Contato'::text) AS nome,
    COALESCE(c.telefone, v.cliente_whatsapp) AS telefone,
    COALESCE(NULLIF(btrim(v.cidade), ''::text), NULLIF(btrim(c.cidade), ''::text)) AS cidade,
    COALESCE(NULLIF(c.origem, ''::text), NULLIF(v.origem, ''::text)) AS origem,
    COALESCE(pl.nome_curto, pl.nome, NULLIF(c.plano_escolhido, ''::text)) AS plano,
    v.valor_mensal,
    v.comissao_prevista,
    e.etapa,
    ce.ordem AS etapa_ordem,
    ce.nome AS etapa_nome,
    s.status,
    cs.nome AS status_nome,
    cs.ajuda AS status_ajuda,
    d.destino,
        CASE
            WHEN d.destino <> 'em_andamento'::text THEN NULL::text
            WHEN s.vez = 'mari'::text AND (COALESCE(c.humano_atribuido, false) OR COALESCE(c.time_atribuido, false) OR c.status = 'handoff_realizado'::text OR c.chatwoot_agente IS NOT NULL) THEN 'time'::text
            ELSE s.vez
        END AS vez,
        CASE
            WHEN d.destino <> 'em_andamento'::text THEN NULL::timestamp with time zone
            WHEN s.status = 'aguardando_instalacao'::text THEN v.instalacao_agendada_para
            WHEN s.base_em IS NOT NULL AND cs.prazo_horas IS NOT NULL THEN s.base_em + make_interval(mins => (cs.prazo_horas * 60::numeric)::integer)
            ELSE NULL::timestamp with time zone
        END AS prazo_em,
    d.destino = 'em_andamento'::text AND s.status <> 'aguardando_instalacao'::text AND s.base_em IS NOT NULL AND cs.prazo_horas IS NOT NULL AND (s.base_em + make_interval(mins => (cs.prazo_horas * 60::numeric)::integer)) < now() AND esp.motivo IS NULL AS atrasado,
    d.destino = 'em_andamento'::text AND esp.motivo IS NOT NULL AS em_espera,
    esp.motivo AS espera_motivo,
    esp.quem AS espera_quem,
    esp.revisar_em AS espera_revisar_em,
        CASE
            WHEN d.destino = 'saida'::text THEN e.etapa
            ELSE NULL::text
        END AS etapa_parou,
    sm.saida_motivo,
    cm.nome AS saida_nome,
    cm.ajuda AS saida_ajuda,
        CASE
            WHEN d.destino = 'saida'::text THEN COALESCE(
            CASE
                WHEN v.status = 'saida'::text THEN COALESCE(v.saida_sub, NULLIF(btrim(v.motivo_saida), ''::text))
                ELSE NULL::text
            END, c.saida_sub, c.funil_detalhe)
            ELSE NULL::text
        END AS saida_sub,
        CASE
            WHEN d.destino = 'saida'::text THEN COALESCE(v.interesse_futuro_em, c.saida_volta_em)
            ELSE NULL::date
        END AS volta_em,
    COALESCE(c.chatwoot_agente, u.nome,
        CASE
            WHEN COALESCE(c.time_atribuido, false) OR COALESCE(c.humano_atribuido, false) THEN 'time'::text
            ELSE NULL::text
        END,
        CASE
            WHEN d.destino = 'em_andamento'::text AND c.id IS NOT NULL THEN 'Mari'::text
            ELSE NULL::text
        END) AS dono,
    v.vendedor_id,
    COALESCE(c.created_at, v.criado_em) AS criado_em,
    GREATEST(c.ultima_msg_lead_at, c.ultima_msg_mari_at, c.funil_destino_em, v.criado_em) AS ultima_em,
    c.funil_etapa AS funil_etapa_antiga,
    c.funil_destino AS funil_destino_antigo,
    v.status AS venda_status,
    v.cancelada_apos_instalar_em,
    v.cancelada_apos_instalar_motivo,
    NULLIF(btrim(v.nio_pedido), ''::text) IS NOT NULL OR NULLIF(btrim(v.nio_os), ''::text) IS NOT NULL AS tem_pedido_nio,
    c.ultima_msg_lead_at,
        CASE
            WHEN c.chatwoot_agente IS NOT NULL THEN c.chatwoot_agente = (( SELECT COALESCE(NULLIF(btrim(eu.chatwoot_agente_nome), ''::text), eu.nome) AS "coalesce"
               FROM usuarios eu
              WHERE eu.id = auth.uid()))
            ELSE COALESCE(v.vendedor_id = auth.uid(), false)
        END AS meu
   FROM par p
     LEFT JOIN mari_conversas c ON c.id = p.conversa_id
     LEFT JOIN vendas v ON v.id = p.venda_id
     LEFT JOIN config_planos pl ON pl.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     CROSS JOIN LATERAL ( SELECT COALESCE(v.instalado_em IS NOT NULL OR (v.status = ANY (ARRAY['3_instalado'::text, '4_ativo_provisorio'::text, '5_comissao_firme'::text])), false) AS instalada,
            COALESCE(NULLIF(btrim(v.nio_os), ''::text) IS NOT NULL OR (v.status = ANY (ARRAY['1_vendido'::text, '2_aguardando_instalacao'::text])), false) AS tem_os,
            COALESCE(v.credito_resultado = ANY (ARRAY['aprovado'::text, 'so_cartao'::text]), false) OR COALESCE(c.credito_resultado ~ '^(aprovado|cartao)'::text, false) AS credito_ok,
            COALESCE(c.cobertura_decisao = 'elegivel_200m'::text, false) AND COALESCE(c.nio_viab_resultado, ''::text) <> 'viavel'::text AND COALESCE(v.nio_viab_resultado, ''::text) <> 'viavel'::text AS so_200m,
            (c.id IS NULL OR COALESCE(c.funil_destino, 'em_andamento'::text) <> 'em_andamento'::text) AND (COALESCE(c.funil_destino = ANY (ARRAY['sem_cobertura'::text, 'fora_area'::text]), false) OR COALESCE(c.saida_motivo = ANY (ARRAY['fachada_nao_atendida'::text, 'cidade_nao_atendida'::text]), false) OR v.status = 'saida'::text AND COALESCE(v.saida_motivo = ANY (ARRAY['fachada_nao_atendida'::text, 'cidade_nao_atendida'::text]), false)) AS fora_cob) f
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN (e0.etapa = ANY (ARRAY['pre_qualificado'::text, 'qualificado'::text])) AND NOT f.tem_os AND NOT f.instalada AND (f.fora_cob OR e0.etapa = 'qualificado'::text AND f.so_200m) THEN 'viabilidade'::text
                    ELSE e0.etapa
                END AS etapa,
            e0.etapa = 'qualificado'::text AND f.so_200m AND NOT f.tem_os AND NOT f.instalada AND NOT f.fora_cob AS conferir_200m
           FROM ( SELECT
                        CASE GREATEST(
                            CASE
                                WHEN f.instalada THEN 6
                                WHEN f.tem_os THEN 5
                                WHEN f.credito_ok THEN 4
                                WHEN v.id IS NOT NULL AND c.id IS NULL THEN 4
                                ELSE 0
                            END,
                            CASE COALESCE(c.funil_etapa, 'nova'::text)
                                WHEN 'instalada'::text THEN 6
                                WHEN 'agendada'::text THEN 5
                                WHEN 'qualificada'::text THEN 4
                                WHEN 'pedido'::text THEN 4
                                WHEN 'biometria'::text THEN 4
                                WHEN 'viu_planos'::text THEN 3
                                WHEN 'cep'::text THEN 2
                                WHEN 'area_ok'::text THEN 2
                                WHEN 'viavel'::text THEN 2
                                ELSE 1
                            END)
                            WHEN 6 THEN 'instalada'::text
                            WHEN 5 THEN 'instalacao'::text
                            WHEN 4 THEN 'qualificado'::text
                            WHEN 3 THEN 'pre_qualificado'::text
                            WHEN 2 THEN 'viabilidade'::text
                            ELSE 'atendimento'::text
                        END AS etapa) e0) e
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN c.funil_destino = 'teste_duplicada'::text THEN 'teste_duplicada'::text
                    WHEN v.status = 'saida'::text AND v.saida_motivo = 'teste_duplicada'::text THEN 'teste_duplicada'::text
                    WHEN f.instalada THEN 'instalada'::text
                    WHEN c.id IS NOT NULL THEN
                    CASE COALESCE(c.funil_destino, 'em_andamento'::text)
                        WHEN 'em_andamento'::text THEN 'em_andamento'::text
                        WHEN 'instalada'::text THEN 'instalada'::text
                        ELSE 'saida'::text
                    END
                    WHEN v.status = 'saida'::text THEN 'saida'::text
                    ELSE 'em_andamento'::text
                END AS destino) d
     CROSS JOIN LATERAL ( SELECT x.status,
            x.base_em,
            k.vez
           FROM ( SELECT
                        CASE
                            WHEN c.antifraude_situacao = 'conferir'::text AND (e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text])) THEN 'antifraude_conferir'::text
                            WHEN c.antifraude_situacao = 'defesa'::text AND (e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text])) THEN 'defesa_nio'::text
                            WHEN e.conferir_200m THEN 'conferir_200m'::text
                            WHEN v.id IS NULL AND c.status = 'handoff_realizado'::text AND (c.handoff_motivo = ANY (ARRAY['pedido_humano'::text, 'objecao'::text, 'urgencia_alta'::text])) THEN 'pediu_humano'::text
                            ELSE
                            CASE e.etapa
                                WHEN 'instalada'::text THEN 'instalada'::text
                                WHEN 'instalacao'::text THEN
                                CASE
                                    WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN 'pendencia_nio'::text
                                    WHEN (( SELECT max(er.criado_em) FROM eventos_venda er WHERE er.venda_id = v.id AND er.tipo = 'instalacao_remarcar'::text)) > COALESCE(( SELECT max(ea.criado_em) FROM eventos_venda ea WHERE ea.venda_id = v.id AND ea.tipo = 'backoffice'::text AND (ea.detalhe ->> 'momento'::text) = ANY (ARRAY['agendar'::text, 'os_agendar'::text])), '-infinity'::timestamp with time zone) THEN 'remarcar'::text
                                    WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN 'aguarda_biometria'::text
                                    WHEN v.instalacao_agendada_para IS NULL THEN 'agendar'::text
                                    WHEN v.forma_pagamento = 'cartao'::text AND v.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                                       FROM os_andamento oa
                                      WHERE oa.venda_id = v.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > v.biometria_validada_em)) THEN 'aguarda_cartao'::text
                                    ELSE 'aguardando_instalacao'::text
                                END
                                WHEN 'qualificado'::text THEN
                                CASE
                                    WHEN v.biometria_status = 'validada'::text THEN 'abrir_os'::text
                                    WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN 'aguarda_biometria'::text
                                    WHEN f.credito_ok THEN 'fazer_pedido'::text
                                    ELSE 'rodar_credito'::text
                                END
                                WHEN 'pre_qualificado'::text THEN 'viu_planos'::text
                                WHEN 'viabilidade'::text THEN 'consultando_cep'::text
                                ELSE
                                CASE
                                    WHEN COALESCE(c.funil_etapa, 'nova'::text) = 'nova'::text THEN 'nova'::text
                                    ELSE 'respondeu'::text
                                END
                            END
                        END AS status,
                        CASE
                            WHEN c.antifraude_situacao IS NOT NULL AND (e.etapa <> ALL (ARRAY['instalacao'::text, 'instalada'::text])) THEN c.antifraude_em
                            WHEN e.conferir_200m THEN COALESCE(c.handoff_em, v.criado_em)
                            WHEN v.id IS NULL AND c.status = 'handoff_realizado'::text AND (c.handoff_motivo = ANY (ARRAY['pedido_humano'::text, 'objecao'::text, 'urgencia_alta'::text])) THEN c.handoff_em
                            ELSE
                            CASE e.etapa
                                WHEN 'instalacao'::text THEN
                                CASE
                                    WHEN NULLIF(btrim(v.nio_pendencia_cod), ''::text) IS NOT NULL THEN v.nio_osab_em
                                    WHEN (( SELECT max(er.criado_em) FROM eventos_venda er WHERE er.venda_id = v.id AND er.tipo = 'instalacao_remarcar'::text)) > COALESCE(( SELECT max(ea.criado_em) FROM eventos_venda ea WHERE ea.venda_id = v.id AND ea.tipo = 'backoffice'::text AND (ea.detalhe ->> 'momento'::text) = ANY (ARRAY['agendar'::text, 'os_agendar'::text])), '-infinity'::timestamp with time zone) THEN ( SELECT max(er.criado_em) FROM eventos_venda er WHERE er.venda_id = v.id AND er.tipo = 'instalacao_remarcar'::text)
                                    WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN COALESCE(v.biometria_link_enviado_em, v.nio_os_em, v.vendido_em)
                                    WHEN v.instalacao_agendada_para IS NULL THEN GREATEST(v.biometria_validada_em, v.vendido_em, v.nio_os_em)
                                    WHEN v.forma_pagamento = 'cartao'::text AND v.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                                       FROM os_andamento oa
                                      WHERE oa.venda_id = v.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > v.biometria_validada_em)) THEN v.biometria_validada_em
                                    ELSE NULL::timestamp with time zone
                                END
                                WHEN 'qualificado'::text THEN
                                CASE
                                    WHEN v.biometria_status = 'validada'::text THEN v.biometria_validada_em
                                    WHEN v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text]) THEN COALESCE(v.biometria_link_enviado_em, v.credito_em)
                                    WHEN f.credito_ok THEN COALESCE(v.credito_em, c.credito_em, c.handoff_em)
                                    ELSE COALESCE(c.handoff_em, v.criado_em)
                                END
                                ELSE
                                CASE
                                    WHEN c.status = 'handoff_realizado'::text THEN c.handoff_em
                                    ELSE NULL::timestamp with time zone
                                END
                            END
                        END AS base_em) x
             LEFT JOIN config_lead k ON k.parceiro_id = 'dharma'::text AND k.tipo = 'status'::text AND k.codigo = x.status) s
     LEFT JOIN LATERAL ( SELECT pe.motivo,
            pe.quem_destrava AS quem,
            pe.revisar_em::timestamp with time zone AS revisar_em
           FROM venda_pendencias pe
          WHERE pe.venda_id = v.id AND pe.encerrada_em IS NULL
        UNION ALL
         SELECT COALESCE(c.espera_motivo, 'aguardando'::text) AS "coalesce",
            'cliente'::text AS text,
            c.espera_ate
          WHERE c.espera_ate IS NOT NULL AND c.espera_ate > now()
 LIMIT 1) esp ON true
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN d.destino = 'teste_duplicada'::text THEN 'teste_duplicada'::text
                    WHEN d.destino <> 'saida'::text THEN NULL::text
                    WHEN v.status = 'saida'::text AND v.saida_motivo IS NOT NULL THEN v.saida_motivo
                    WHEN c.saida_motivo IS NOT NULL THEN c.saida_motivo
                    WHEN v.status = 'saida'::text AND v.motivo_saida ~~* 'Nio:%'::text THEN
                    CASE
                        WHEN v.motivo_saida ~* '(indevida|errada|duplicad|j[aá] possui)'::text THEN 'venda_indevida_fraude'::text
                        WHEN v.motivo_saida ~* '(desist|concorr)'::text THEN 'recusou'::text
                        ELSE 'nio_nao_instalou'::text
                    END
                    WHEN v.status = 'saida'::text AND v.motivo_saida ~* 'fraude'::text THEN 'venda_indevida_fraude'::text
                    ELSE
                    CASE COALESCE(c.funil_destino, funil_destino_de_motivo(v.motivo_saida))
                        WHEN 'fora_area'::text THEN 'cidade_nao_atendida'::text
                        WHEN 'sem_cobertura'::text THEN 'fachada_nao_atendida'::text
                        WHEN 'recusou'::text THEN
                        CASE
                            WHEN COALESCE(c.nao_contatar, false) AND c.funil_detalhe = 'não contatar'::text THEN 'nao_contatar'::text
                            ELSE 'recusou'::text
                        END
                        WHEN 'teste_duplicada'::text THEN 'teste_duplicada'::text
                        ELSE COALESCE(c.funil_destino, funil_destino_de_motivo(v.motivo_saida))
                    END
                END AS saida_motivo) sm
     LEFT JOIN config_lead ce ON ce.parceiro_id = 'dharma'::text AND ce.tipo = 'etapa'::text AND ce.codigo = e.etapa
     LEFT JOIN config_lead cs ON cs.parceiro_id = 'dharma'::text AND cs.tipo = 'status'::text AND cs.codigo = s.status
     LEFT JOIN config_lead cm ON cm.parceiro_id = 'dharma'::text AND cm.tipo = 'saida'::text AND cm.codigo = sm.saida_motivo
  WHERE p.rn = 1;

commit;
