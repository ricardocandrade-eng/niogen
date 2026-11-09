-- NIOGEN | supabase/migrations/0089_jornada_5_etapas.sql | 09/11/2026 — Claude Code
-- Prompt docs/Prompt_ajustes_operacao_ficha_conversa_091126_1535.md · ponto 1 (jornada única de 5 etapas, ordem biometria → OS).
-- Ricardo, 09/11 14h42: a biometria vem ANTES da OS; abrir a OS e agendar é UM passo só e é ele que faz a venda contar.
--
--   Etapa (v_jornada / jornada_etapa, os status do banco NÃO mudam de id):
--     1 Conversa             — conversa da Mari sem venda
--     2 Lead qualificado     — 0_qualificado sem nº do pedido (dados completos; a venda nasce aqui como registro)
--     3 Pedido · biometria   — 0_qualificado com nº do pedido (a Nio manda o link da biometria)
--     4 Venda · OS agendada  — 1_vendido / 2_aguardando_instalacao (OS + dia + período, depois da biometria validada)
--     5 Instalada            — 3_instalado / 4 / 5 (baixa da Nio no OSAB)
--     0 Saída                — saida (com motivo; interesse futuro é um motivo)
--
--   1. jornada_etapa(status, pedido) + nomes (jornada_nome).
--   2. Trava (vendas_antes_status): VENDA = pedido + biometria validada + OS + agendamento + viabilidade do portal (crédito não
--      negado). Antes (0087): pedido + OS + viabilidade. Agendar continua exigindo a biometria validada.
--   3. backoffice_momento: 'pedido' grava SÓ o pedido (etapa 3) · 'os_agendar' (novo) grava OS + dia + período e leva direto a
--      2_aguardando_instalacao = a venda conta (etiqueta instalacao-agendada, nota, confirmação ao cliente, resolve) ·
--      'agendar' vira 'reagendar' (só depois da venda) · biometria exige o pedido gravado.
--   4. v_funil: prazo de 4 h e "agendar desde" contam da biometria validada na etapa 3; + coluna jornada_etapa (no fim).
--   5. resumo_diario: prazo de agendar = biometria validada na etapa 3. funil_mes na ordem nova (pedido → biometria → venda).

-- ───────────────────────── 1. etapa da jornada ─────────────────────────
create or replace function public.jornada_etapa(p_status text, p_pedido text)
returns int language sql immutable set search_path = public as $$
  select case
    when p_status = 'saida' then 0
    when p_status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then 5
    when p_status in ('1_vendido', '2_aguardando_instalacao') then 4
    when coalesce(btrim(p_pedido), '') <> '' then 3
    else 2 end
$$;
create or replace function public.jornada_nome(p_etapa int)
returns text language sql immutable set search_path = public as $$
  select case p_etapa when 1 then 'Conversa' when 2 then 'Lead qualificado' when 3 then 'Pedido · biometria'
                      when 4 then 'Venda · OS agendada' when 5 then 'Instalada' else 'Saída' end
$$;
grant execute on function public.jornada_etapa(text, text) to authenticated;
grant execute on function public.jornada_nome(int) to authenticated;

-- ───────────────────────── 2. a trava da venda ─────────────────────────
create or replace function public.vendas_antes_status()
returns trigger language plpgsql set search_path = public as $$
declare
  mudou   boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  entrou  boolean;
begin
  if not mudou then
    return new;
  end if;
  entrou := vendida and (tg_op = 'INSERT' or old.status in ('0_qualificado', 'saida'));

  -- 0089: VENDA = pedido gravado → biometria validada → OS aberta no portal com o dia e o período (um passo só).
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
    raise exception 'Ainda não é venda: falta o nº da OS (abra a OS no portal já com o dia e o período).' using errcode = 'P0001';
  end if;
  if entrou and new.instalacao_agendada_para is null then
    raise exception 'Ainda não é venda: falta o agendamento da instalação (dia e período).' using errcode = 'P0001';
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
    new.agendamento_registrado_em := now();
  elsif new.status = '3_instalado' then
    new.instalado_em := coalesce(new.instalado_em, now());
  elsif new.status = '4_ativo_provisorio' then
    new.ativado_em := coalesce(new.ativado_em, now());
  end if;
  return new;
end;
$$;

-- ───────────────────────── 3. os botões (momentos) ─────────────────────────
create or replace function public.backoffice_momento(p_venda uuid, p_momento text, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
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
  if p_momento not in ('assumir', 'viabilidade', 'pedido', 'biometria', 'os_agendar', 'reagendar', 'parar', 'devolver_mari') then
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
  if p_momento in ('viabilidade', 'pedido', 'biometria', 'os_agendar', 'reagendar') and v.id is null then
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
      o := o + 1;
      msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                 'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do pedido (biometria)');
      feito := feito || 'etiqueta'::text || 'nota'::text;
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
$$;

-- ───────────────────────── 4. v_funil (prazo de 4 h da biometria validada; jornada_etapa no fim) ─────────────────────────
create or replace view public.v_funil as
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
    p.nome AS plano_nome,
    p.familia AS plano_familia,
    p.velocidade AS plano_velocidade,
    p.preco AS plano_preco,
    p.codigo AS plano_codigo,
    p.portfolio AS plano_portfolio,
    p.variante AS plano_variante,
    p.cluster AS plano_cluster,
    p.preco_cartao AS plano_preco_cartao,
    p.taxa_a_vista AS plano_taxa_a_vista,
    p.isencao_meses AS plano_isencao_meses,
    u.nome AS vendedor_nome,
        CASE
            WHEN v.status = '0_qualificado'::text AND COALESCE(btrim(v.nio_pedido), ''::text) <> ''::text AND v.biometria_status = 'validada'::text THEN round(EXTRACT(epoch FROM now() - v.biometria_validada_em) / 3600::numeric, 2)
            WHEN v.status = '1_vendido'::text AND v.agendamento_registrado_em IS NULL THEN round(EXTRACT(epoch FROM now() - GREATEST(v.biometria_validada_em, v.vendido_em)) / 3600::numeric, 2)
            ELSE NULL::numeric
        END AS horas_sem_agendamento,
        CASE
            WHEN v.status = '0_qualificado'::text AND COALESCE(btrim(v.nio_pedido), ''::text) <> ''::text AND v.biometria_status IS DISTINCT FROM 'validada'::text THEN round(EXTRACT(epoch FROM now() - COALESCE(v.biometria_link_enviado_em, v.nio_pedido_em, v.criado_em)) / 86400::numeric, 2)
            ELSE NULL::numeric
        END AS dias_esperando_biometria,
    v.instalado_em + '15 days'::interval AS docs_prazo_em,
    COALESCE(v.ativado_em, v.instalado_em) + '30 days'::interval AS firme_em,
    (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) AS dfv_ok,
        CASE
            WHEN v.dfv_consultado_em IS NOT NULL THEN floor(EXTRACT(epoch FROM now() - v.dfv_consultado_em) / 86400::numeric)::integer
            ELSE NULL::integer
        END AS dfv_dias,
    COALESCE(v.ativado_em, v.instalado_em) + '180 days'::interval AS downgrade_ate,
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
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) AS nio_viab_ok,
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) OR (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) OR COALESCE(v.dfv_dispensado, false) AS viab_ok,
        CASE
            WHEN (v.status = ANY (ARRAY['0_qualificado'::text, '1_vendido'::text])) AND (v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text])) AND v.biometria_link_enviado_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.biometria_link_enviado_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_biometria_pendente,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.credito_resultado = 'pendente'::text AND v.credito_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.credito_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_credito_pendente,
    COALESCE(v.biometria_validada_em, v.vendido_em) AS agendar_desde,
    v.nio_viab_endereco_portal,
    v.parceiro_id,
    pa.nome AS parceiro_nome,
    v.conferencia_status,
    v.conferencia_motivo,
    v.conferencia_prazo_ate,
    pe.id AS pend_id,
    pe.motivo AS pend_motivo,
    pm.nome AS pend_motivo_nome,
    pe.descricao AS pend_descricao,
    pe.quem_destrava AS pend_quem,
    pe.aberta_em AS pend_desde,
    pe.revisar_em AS pend_revisar_em,
    pe.revisoes AS pend_revisoes,
    pm.saida_sugerida AS pend_saida_sugerida,
    v.nio_os,
    v.nio_os_em,
    jornada_etapa(v.status, v.nio_pedido) AS jornada_etapa
   FROM vendas v
     LEFT JOIN config_planos p ON p.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     LEFT JOIN parceiros pa ON pa.id = v.parceiro_id
     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo;


-- ───────────────────────── 5. resumo diário e funil do mês na ordem nova ─────────────────────────
CREATE OR REPLACE FUNCTION public.resumo_diario(p_dia date DEFAULT (((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date - 1))
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  tz constant text := 'America/Sao_Paulo';
  hoje date := p_dia + 1;               -- o dia em que o resumo é lido
  h_par numeric := coalesce((public.config_regra('resumo_parada_horas', '2'))::text::numeric, 2);
  h_ag numeric := coalesce((public.config_regra('prazo_agendar_horas', '4'))::text::numeric, 4);
  d_docs int := coalesce((public.config_regra('prazo_docs_dias', '15'))::text::int, 15);
  n_criadas int; n_qualif int; n_pedidos int; n_bio int; n_inst int;
  gasto numeric; conv_meta int;
  par_humano int; par_cliente int;
  ag_venc int; ag_hoje int; ag_amanha int; dc_venc int; dc_hoje int; dc_amanha int;
  esp int; esp_venc int;
  ritmo jsonb;
  dados jsonb; linhas text[] := '{}';
  dows text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];
  meses text[] := array['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
  nome_mes text;
  brl text;
begin
  if auth.role() is distinct from 'service_role' and auth.uid() is not null and public.meu_perfil() is distinct from 'admin' then
    raise exception 'resumo_diario: só admin' using errcode = '42501';
  end if;

  select count(*) into n_criadas from public.vendas where (criado_em at time zone tz)::date = p_dia;
  select count(*) into n_qualif from public.mari_conversas
   where handoff_motivo = 'dados_completos' and (handoff_em at time zone tz)::date = p_dia and coalesce(canal, '') <> 'teste';
  select count(*) into n_pedidos from public.vendas where (nio_pedido_em at time zone tz)::date = p_dia;
  select count(*) into n_bio from public.vendas where (biometria_validada_em at time zone tz)::date = p_dia;
  select count(*) into n_inst from public.vendas where (instalado_em at time zone tz)::date = p_dia and status <> 'saida';

  select coalesce(sum(m.gasto), 0), coalesce(sum(m.conversas_meta), 0) into gasto, conv_meta from public.v_meta_ads_dia m where m.dia = p_dia;

  -- Conversas paradas agora (no momento em que o resumo roda), conversas de teste fora.
  select count(*) filter (where q.vez = 'humano' and q.vez_desde <= now() - make_interval(secs => h_par * 3600)),
         count(*) filter (where q.vez = 'mari' and q.vez_desde <= now() - make_interval(secs => h_par * 3600))
    into par_humano, par_cliente
    from public.v_mari_quadro q where not coalesce(q.teste, false) and q.coluna <> 'encerrada';

  -- Prazos do contrato (no dia de leitura): agendar a instalação em h_ag horas; documentos em d_docs dias.
  select count(*) filter (where p < now()),
         count(*) filter (where p >= now() and (p at time zone tz)::date = hoje),
         count(*) filter (where (p at time zone tz)::date = hoje + 1)
    into ag_venc, ag_hoje, ag_amanha
    from (select biometria_validada_em + make_interval(secs => h_ag * 3600) as p from public.vendas where status = '0_qualificado' and coalesce(btrim(nio_pedido), '') <> '' and biometria_status = 'validada' and biometria_validada_em is not null) x;   -- 0089: etapa 3, biometria validada → OS + agendar em h_ag horas
  select count(*) filter (where p < now()),
         count(*) filter (where p >= now() and (p at time zone tz)::date = hoje),
         count(*) filter (where (p at time zone tz)::date = hoje + 1)
    into dc_venc, dc_hoje, dc_amanha
    from (select instalado_em + make_interval(days => d_docs) as p from public.vendas
           where status = '3_instalado' and instalado_em is not null and docs_entregues_em is null) x;

  select count(*), count(*) filter (where revisar_em <= hoje) into esp, esp_venc
    from public.venda_pendencias where encerrada_em is null;

  ritmo := public.painel_meta_ritmo(hoje);
  nome_mes := meses[extract(month from hoje)::int];
  brl := replace(to_char(gasto, 'FM999990.00'), '.', ',');

  dados := jsonb_build_object(
    'vendas', jsonb_build_object('criadas', n_criadas, 'qualificadas_mari', n_qualif, 'pedidos', n_pedidos, 'biometrias', n_bio, 'instaladas', n_inst),
    'meta_ads', jsonb_build_object('gasto', gasto, 'conversas', conv_meta, 'custo_por_conversa', case when conv_meta > 0 then round(gasto / conv_meta, 2) end),
    'paradas', jsonb_build_object('com_humano', par_humano, 'cliente_sem_resposta', par_cliente, 'horas', h_par),
    'prazos', jsonb_build_object('agendar', jsonb_build_object('vencidos', ag_venc, 'hoje', ag_hoje, 'amanha', ag_amanha),
                                 'docs', jsonb_build_object('vencidos', dc_venc, 'hoje', dc_hoje, 'amanha', dc_amanha)),
    'em_espera', jsonb_build_object('abertas', esp, 'revisar_hoje_ou_antes', esp_venc),
    'ritmo', ritmo);

  linhas := linhas || format('📊 NIOGEN · resumo de %s %s', dows[extract(dow from p_dia)::int + 1], to_char(p_dia, 'DD/MM'));
  linhas := linhas || format('Vendas: %s nova%s · %s qualificada%s pela Mari · %s pedido%s · %s biometria%s · %s instalada%s',
    n_criadas, case when n_criadas = 1 then '' else 's' end, n_qualif, case when n_qualif = 1 then '' else 's' end,
    n_pedidos, case when n_pedidos = 1 then '' else 's' end, n_bio, case when n_bio = 1 then '' else 's' end,
    n_inst, case when n_inst = 1 then '' else 's' end);
  linhas := linhas || case when conv_meta > 0
    then format('Meta Ads: R$ %s · %s conversa%s → R$ %s por conversa', brl, conv_meta, case when conv_meta = 1 then '' else 's' end,
                replace(to_char(round(gasto / conv_meta, 2), 'FM999990.00'), '.', ','))
    else format('Meta Ads: R$ %s · nenhuma conversa', brl) end;
  linhas := linhas || format('Paradas agora (+%s h): %s com humano sem resposta · %s cliente esperando a Mari',
    replace(h_par::text, '.', ','), par_humano, par_cliente);
  linhas := linhas || case when ag_venc + ag_hoje + ag_amanha + dc_venc + dc_hoje + dc_amanha = 0
    then 'Prazos do contrato: nada vencendo hoje nem amanhã ✓'
    else format('Prazos do contrato: agendar %s h — %s vencido(s), %s hoje, %s amanhã · docs %s d — %s vencido(s), %s hoje, %s amanhã',
                h_ag, ag_venc, ag_hoje, ag_amanha, d_docs, dc_venc, dc_hoje, dc_amanha) end;
  if esp > 0 then
    linhas := linhas || format('Em espera (terceiro): %s · %s para revisar hoje', esp, esp_venc);
  end if;
  if ritmo is not null and (ritmo->>'meta')::int > 0 then
    linhas := linhas || case when (ritmo->>'faltam')::int = 0
      then format('Meta de %s: %s/%s instaladas — batida ✓', nome_mes, ritmo->>'instaladas', ritmo->>'meta')
      else format('Meta de %s: %s/%s instaladas · faltam %s em %s dias → %s por dia', nome_mes, ritmo->>'instaladas', ritmo->>'meta',
                  ritmo->>'faltam', ritmo->>'dias_restantes', replace(ritmo->>'por_dia', '.', ',')) end;
  end if;

  return jsonb_build_object('dia', p_dia, 'gerado_em', now(), 'dados', dados, 'texto', array_to_string(linhas, E'\n'));
end $function$;


create or replace function public.funil_mes(p_mes date default ((now() at time zone 'America/Sao_Paulo')::date))
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
      jsonb_build_object('id', 'vendas', 'nome', 'Vendas (OS agendada)', 'dica', 'VENDA = OS aberta no portal com o dia e o período, depois da biometria (etapa 4)',
        'n', (select count(*) from vv where vv.vendido_em >= ini and vv.vendido_em < fim and coalesce(vv.nio_os, '') <> '')),
      jsonb_build_object('id', 'instaladas', 'nome', 'Instaladas', 'dica', 'Baixa da Nio no OSAB (etapa 5) — é o que paga comissão e conta na meta',
        'n', (select count(*) from vv where vv.instalado_em >= ini and vv.instalado_em < fim and vv.status <> 'saida')),
      jsonb_build_object('id', 'ativas', 'nome', 'Ativas', 'dica', 'Serviço ativado',
        'n', (select count(*) from vv where vv.ativado_em >= ini and vv.ativado_em < fim and vv.status <> 'saida'))
    )));
end;
$$;
