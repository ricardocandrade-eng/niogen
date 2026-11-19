-- NIOGEN | supabase/migrations/0318_conferir_com_saida.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 19/11: "Sim, todos assim" — todo tipo do Live › Conferir que só tinha "Abrir" ganha a saída na própria linha (continuação da
-- 0315: "nem sempre vejo uma forma de limpar a tela"). As saídas que já existiam no banco só ganham botão na Live (sem SQL):
-- Parada com dono / Ninguém pegou → Devolver à Mari (backoffice_momento devolver_mari) · Pós-venda → Nada a responder
-- (backoffice_conversa_dispensar) · Sem resposta com pedido → Saída · Sem resposta (lead_sair; o "Cancelar na Nio" entra em seguida) ·
-- Hora de voltar → Reabrir (lead_reabrir). O que é novo, aqui:
--  (1) Hora de voltar → "Mais 7 dias": evento "volta_adiar" pela porta (casca lead_volta_adiar + _porta_volta_adiar). Vale em Saída;
--      empurra a data de volta (vendas.interesse_futuro_em e/ou mari_conversas.saida_volta_em) para hoje + N dias, com nota no histórico.
--      Situação, dono e vez não mudam ("=").
--  (2) OS na Nio → "Visto": os_andamento.excecao_vista_chave (retrato estado|status|ação na hora do Visto) + _em/_por. A linha some
--      enquanto a OS continuar igual; mudou na Nio (nova leitura), volta. os_excecao_visto(p_pedido).
--  (3) Conta não fecha → "Visto hoje": conferencias_diarias.vistos (código → quem/quando). A linha some hoje; amanhã a conferência
--      roda de novo e, se ainda falhar, volta. conferencia_visto(p_codigo).
--  (4) Documentos à Nio → "Entregues": venda_docs_entregues(p_venda) grava docs_entregues_em = agora e o evento na venda (autor).
--  (5) live_conferir: os filtros de (2) e (3). Recriada da versão no ar (= 0315).
--  (6) porta(): o ramo volta_adiar. Recriada da versão no ar (= 0315).
-- Regra 20: (1) nenhum estado novo — (1) é "=" e (2)–(4) são registros com autor; (2) a mudança no lead (data de volta) passa pela porta,
-- com evento declarado; (3) autor gravado em todas; (4) fonte: a exceção da OS segue vindo da Nio (o Visto só esconde até mudar);
-- (5) conferência: a do dia roda de novo amanhã e o Visto da OS caduca quando a Nio muda. Cenário X47. Tela: Live (botões no Conferir).
begin;

alter table public.os_andamento
  add column if not exists excecao_vista_chave text,
  add column if not exists excecao_vista_em    timestamptz,
  add column if not exists excecao_vista_por   uuid;
comment on column public.os_andamento.excecao_vista_chave is
  '0318: retrato (estado|status_ordem|acao) no "Visto" da Live › Conferir › OS na Nio. Enquanto a OS for igual a este retrato, a linha fica escondida.';
alter table public.conferencias_diarias add column if not exists vistos jsonb not null default '{}'::jsonb;
comment on column public.conferencias_diarias.vistos is
  '0318: falhas do dia marcadas "Visto hoje" na Live (código → {por, em}). Saem do Conferir só neste dia.';

-- ── (1) Hora de voltar → Mais N dias, pela porta ──
insert into public.config_evento (codigo, funcao, nome, nota, quem) values
  ('volta_adiar', 'lead_volta_adiar', 'Adiar a data de volta', 'Hora de voltar → mais N dias; situação, dono e vez não mudam (0318)', 'time')
on conflict (codigo) do update set nome = excluded.nome, funcao = excluded.funcao, quem = excluded.quem, nota = excluded.nota;
delete from public.config_transicao where evento = 'volta_adiar';
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('volta_adiar', 'saida', array['='], true, null, 'Ricardo 19/11: "Hora de voltar" ganha "Mais 7 dias"; o lead segue na Saída', null),
  ('volta_adiar', 'andamento', null, false, 'Este lead não está em Saída: não há data de volta para adiar.', '0318', null);

create or replace function public._porta_volta_adiar(c public.mari_conversas, v public.vendas, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  dias  int := least(greatest(coalesce((p_dados ->> 'dias')::int, 7), 1), 60);
  nova  date := (now() at time zone 'America/Sao_Paulo')::date + least(greatest(coalesce((p_dados ->> 'dias')::int, 7), 1), 60);
  quem  text;
  mexeu int := 0;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice adia a volta.' using errcode = '42501';
  end if;
  quem := coalesce(nullif(split_part(btrim(coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), '')), ' ', 1), ''), 'time');
  if v.id is not null and v.interesse_futuro_em is not null then
    update public.vendas set interesse_futuro_em = nova where id = v.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'volta_adiada', jsonb_build_object('de', v.interesse_futuro_em, 'para', nova, 'dias', dias), auth.uid());
    mexeu := mexeu + 1;
  end if;
  if c.id is not null and c.saida_volta_em is not null then
    update public.mari_conversas set saida_volta_em = nova where id = c.id;
    mexeu := mexeu + 1;
  end if;
  if mexeu = 0 then raise exception 'Este lead não tem data de volta para adiar.' using errcode = 'P0001'; end if;
  if c.id is not null then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[📅 volta adiada para ' || to_char(nova, 'DD/MM') || ' — ' || quem || ']', false);
  end if;
  return jsonb_build_object('ok', true, 'volta_em', nova, 'resumo', '📅 Volta adiada para ' || to_char(nova, 'DD/MM'));
end $$;
revoke all on function public._porta_volta_adiar(public.mari_conversas, public.vendas, jsonb) from public, anon, authenticated;

create or replace function public.lead_volta_adiar(p_conversa uuid, p_venda uuid, p_dias int default 7)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_a text;
begin
  -- casca da porta (como retomada_ligacao): anota o evento; quem decide e executa é a porta
  perform set_config('porta.dentro', 'lead_volta_adiar', true);
  v_a := public._porta_situacao(p_conversa, p_venda);
  r := public.porta('volta_adiar', p_conversa, p_venda, jsonb_build_object('dias', p_dias));
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('volta_adiar', 'lead_volta_adiar', p_conversa, p_venda, v_a, r);
  return r;
end $$;
revoke all on function public.lead_volta_adiar(uuid, uuid, int) from public, anon;
grant execute on function public.lead_volta_adiar(uuid, uuid, int) to authenticated;

-- ── (2) OS na Nio → Visto (até a OS mudar) ──
create or replace function public.os_excecao_visto(p_pedido text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.os_andamento;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into a from public.os_andamento where pedido = p_pedido;
  if not found then raise exception 'OS % não encontrada.', p_pedido; end if;
  if not coalesce(a.excecao, false) then raise exception 'Esta OS não está mais em exceção. Atualize a tela.' using errcode = 'P0001'; end if;
  update public.os_andamento
     set excecao_vista_chave = concat_ws('|', a.estado, a.status_ordem, a.acao), excecao_vista_em = now(), excecao_vista_por = auth.uid()
   where pedido = p_pedido;
  if a.venda_id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (a.venda_id, 'os_excecao_vista', jsonb_build_object('pedido', p_pedido, 'status_ordem', a.status_ordem, 'acao', a.acao), auth.uid());
  end if;
  return jsonb_build_object('ok', true, 'resumo', 'Visto · a linha volta se a OS mudar na Nio');
end $$;
revoke all on function public.os_excecao_visto(text) from public, anon;
grant execute on function public.os_excecao_visto(text) to authenticated;

-- ── (3) Conta não fecha → Visto hoje ──
create or replace function public.conferencia_visto(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if coalesce(btrim(p_codigo), '') = '' then raise exception 'Informe o código da conferência.'; end if;
  update public.conferencias_diarias
     set vistos = coalesce(vistos, '{}'::jsonb) || jsonb_build_object(p_codigo, jsonb_build_object('por', auth.uid(), 'em', now()))
   where dia = hoje;
  if not found then raise exception 'Não há conferência de hoje.' using errcode = 'P0001'; end if;
  return jsonb_build_object('ok', true, 'resumo', 'Visto hoje · se ainda falhar, volta amanhã');
end $$;
revoke all on function public.conferencia_visto(text) from public, anon;
grant execute on function public.conferencia_visto(text) to authenticated;

-- ── (4) Documentos à Nio → Entregues ──
create or replace function public.venda_docs_entregues(p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.vendas;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.'; end if;
  if v.docs_entregues_em is not null then
    return jsonb_build_object('ok', true, 'resumo', 'Os documentos já estavam marcados como entregues');
  end if;
  update public.vendas set docs_entregues_em = now() where id = p_venda;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'docs_entregues', jsonb_build_object('via', 'live'), auth.uid());
  return jsonb_build_object('ok', true, 'resumo', '📄 Documentos à Nio marcados como entregues');
end $$;
revoke all on function public.venda_docs_entregues(uuid) from public, anon;
grant execute on function public.venda_docs_entregues(uuid) to authenticated;

-- porta (= versão no ar, 0315) + o ramo volta_adiar
CREATE OR REPLACE FUNCTION public.porta(p_evento text, p_conversa uuid, p_venda uuid, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  v       public.vendas;
  r       record;
  antes   text;
  fam     text := split_part(coalesce(p_evento, ''), ':', 1);
  arg     text := nullif(split_part(coalesce(p_evento, ''), ':', 2), '');
  cliente boolean := p_evento = 'cliente_escreveu';
  quem    text;
  v_opt   timestamptz;
  res     jsonb;
  ged     text;
  saidas  jsonb := '{"perdida": "recusou", "recusou": "recusou", "fora_area": "cidade_nao_atendida", "sem_cobertura": "fachada_nao_atendida",
                     "ja_cliente": "ja_cliente_nio", "ja_cliente_nio": "ja_cliente_nio", "credito_negado": "credito_negado",
                     "sem_resposta": "sem_resposta", "teste_duplicada": "teste_duplicada"}'::jsonb;   -- silenciar:<motivo antigo> → motivo de Saída
begin
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa for update;
    if not found then raise exception 'Conversa não encontrada.'; end if;
  end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    if c.id is null then
      select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1;
    end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()),
                   case when cliente then 'o cliente' when auth.role() = 'service_role' then 'o sistema' else 'alguém do time' end);

  -- a tabela manda: recusa com a frase, ou segue
  antes := public._porta_situacao(c.id, v.id);
  select * into r from public.porta_prever(antes, p_evento);
  -- 0287: botão da ficha (momento) e Mover do admin sem regra na tabela passam (como o _porta_conferir fazia) — a casca anota o buraco
  if r.aceito is false or (r.aceito is null and fam not in ('momento', 'mover_admin')) then
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes, 'frase', r.frase); end if;
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação (' || antes || ').');
  end if;
  if r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  -- 0298 (fase 2, passo 6 — D11, D15, E7: "só admin, com motivo"): ação que só o admin faz exige o motivo. Vale o que veio nos dados
  -- (Mover do admin) ou o que a tela preparou há pouco (porta_motivo_preparar). Sem motivo, a tela pede e repete (MOTIVO_ADMIN).
  if r.exige = 'admin' then
    declare v_mot text := btrim(coalesce(p_dados ->> 'motivo', ''));
            v_mid bigint;
    begin
      if length(v_mot) < 5 then
        select pm.id, pm.motivo into v_mid, v_mot from public.porta_motivos pm
         where pm.por = auth.uid() and pm.usado_em is null and pm.criado_em > now() - interval '5 minutes'
         order by pm.id desc limit 1;
        if v_mid is not null then
          update public.porta_motivos set usado_em = now(), evento = p_evento where id = v_mid;
        end if;
      end if;
      if length(btrim(coalesce(v_mot, ''))) < 5 then
        raise exception 'MOTIVO_ADMIN: %', coalesce(r.frase, 'Esta ação é só do admin') || ' — escreva o motivo (pelo menos 5 letras).'
          using errcode = 'P0001';
      end if;
      perform set_config('porta.motivo', left(btrim(v_mot), 500), true);
    end;
  end if;
  if r.exige = 'ged_sem_leitura' and coalesce(public.meu_perfil(), '') <> 'admin' then   -- 0272, trazido do _porta_conferir (0287)
    ged := public._ged_fresco(v.id);
    if ged is not null then raise exception '%', r.frase || ' (GED360: ' || ged || ')'; end if;
  end if;
  if r.exige = 'cliente_escreveu_depois' and c.id is not null then
    select max(t.created_at) into v_opt from public.mari_turnos t
     where t.conversa_id = c.id and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%';
    if v_opt is not null and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > v_opt) then
      raise exception '%', r.frase;
    end if;
  end if;

  -- 0282 (reta final 5): Assumir, Devolver para a Mari e o "assumir antes" do Responder são executados aqui. Não mudam o
  -- destino do lead, então rodam SEM porta.aplicando: os gatilhos antigos do funil seguem calculando etapa e handoff como antes.
  -- 0287: os botões da venda (momento:*) também — viabilidade, crédito, pedido, biometria, OS, agendar, parar. Eles mudam a venda e
  -- o destino sai dos gatilhos de sempre (_funil_venda_mudou → _funil_antes), por isso também rodam SEM porta.aplicando.
  if p_evento = 'time_respondeu' then
    return public._porta_assumir(c, v, coalesce(p_dados, '{}'::jsonb) || jsonb_build_object('via', 'responder'));
  elsif p_evento = 'soprar' then   -- 0299: o time fala na voz da Mari; situação, dono e vez não mudam
    return public._porta_soprar(c, coalesce(p_dados, '{}'::jsonb));
  elsif fam = 'retomada_ligacao' then   -- 0315: o time registra a ligação da Retomada; situação, dono e vez não mudam
    return public._porta_retomada_ligacao(c, arg, coalesce(p_dados, '{}'::jsonb));
  elsif p_evento = 'volta_adiar' then   -- 0318: Hora de voltar → mais N dias; situação, dono e vez não mudam
    return public._porta_volta_adiar(c, v, coalesce(p_dados, '{}'::jsonb));
  elsif fam = 'momento' then
    -- mesmos argumentos que o núcleo recebeu (venda e/ou conversa), para a peça achar a mesma conversa de antes
    return public._porta_momento(p_venda, arg, coalesce(p_dados, '{}'::jsonb)
             || case when p_conversa is not null then jsonb_build_object('conversa_id', p_conversa) else '{}'::jsonb end);
  elsif fam = 'mover_admin' then   -- 0288: o Mover do admin (a venda muda; o destino sai do gatilho vendas_porta)
    return public._porta_mover(v, arg, coalesce(p_dados, '{}'::jsonb));
  end if;

  perform set_config('porta.aplicando', '1', true);   -- os gatilhos antigos do funil não decidem por cima da porta
  if fam = 'saida' then
    res := public._porta_sair(c, v, arg, p_dados, quem, true);
  elsif fam = 'silenciar' and arg = 'suporte_nio' then
    res := public._porta_silenciar(c, quem, false);
  elsif fam = 'silenciar' and arg = 'reativar' then
    res := public._porta_reativar(c, quem);
  elsif fam = 'silenciar' and saidas ? arg then
    res := public._porta_sair(c, v, saidas ->> arg, p_dados, quem, false);
  elsif fam = 'reabrir' then
    res := public._porta_reabrir(c, v, quem, false, coalesce(c.nao_contatar, false));
  elsif fam = 'nao_contatar' then
    res := public._porta_nao_contatar(c, v, p_dados ->> 'origem');
  elsif fam = 'prazo' and arg = 'esperando_fechar' then          -- 0266 (C10)
    res := public._porta_esperando_fechar(c);
  elsif fam = 'prazo' and arg = 'handoff_sem_resposta' then      -- 0266 (C4)
    res := public._porta_handoff_devolver(c);
  elsif cliente and p_dados ->> 'acao' = 'fim_espera' and antes = 'em_espera' then   -- 0266 (C11)
    res := public._porta_fim_espera(c);
  elsif fam = 'cliente_escreveu' and arg = 'sem_cobertura' then   -- 0279 (caso Felix): Saída por cobertura não reabre
    res := public._porta_volta_sem_cobertura(c, p_dados ->> 'texto');
  elsif cliente and p_dados ->> 'acao' = 'reabrir' and antes = 'saida_pode_voltar' then
    res := public._porta_reabrir(c, v, quem, true, false);
  elsif cliente and p_dados ->> 'acao' = 'silenciar' and antes = 'cliente_nio' then
    res := public._porta_silenciar(c, quem, true);
  else
    perform set_config('porta.aplicando', '', true);
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes); end if;
    raise exception 'Evento ainda não passa pela porta: %', p_evento;
  end if;
  perform set_config('porta.aplicando', '', true);
  return res;
end $function$;

-- live_conferir (= versão no ar, 0315) + os filtros do Visto
CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           -- 0271 (passo 6, Live): prazo de 24 h úteis a contar da Saída e dono = quem deu a Saída. Vencido = "VENCIDO" no texto (a Live acende).
           case when public._horas_uteis(ev.em, now()) >= 24 then 'VENCIDO · ' else 'prazo: faltam ' || greatest(1, ceil(24 - public._horas_uteis(ev.em, now())))::int || ' h úteis · ' end
             || 'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || coalesce(' · Saída dada por ' || ev.quem, '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select e.criado_em as em, (select split_part(btrim(u.nome), ' ', 1) from public.usuarios u where u.id = e.criado_por) as quem
                            from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status' order by e.criado_em desc limit 1) ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
       and a.excecao_vista_chave is distinct from concat_ws('|', a.estado, a.status_ordem, a.acao)   -- 0318: Visto até a OS mudar
    union all
    -- (i2) 0196: biometria da Nio fora do ar (suspeita automática pelo GED360 ou marcada pelo time)
    select 'biometria_fora', q.id::text, null::uuid, null::uuid, 'Biometria da Nio', q.inicio, 1,
           format('%s desde %s%s · %s venda(s) esperando a biometria — peça à Nio a dispensa e marque "Nio dispensou" em cada ficha; quando voltar, marque "Voltou" (Operações › Biometria)',
                  case when q.confirmada_em is null then 'Biometria da Nio parece fora do ar (GED360 sem biometria nova há ' || q.horas_sem_envio || ' h no horário comercial · confirme no grupo)'
                       else 'Biometria da Nio FORA DO AR' end,
                  to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                  case when q.origem = 'manual' then ' (marcada por ' || coalesce((select u.nome from public.usuarios u where u.id = q.aberta_por), 'time') || ')' else '' end,
                  (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')))
      from public.biometria_quedas q
     where q.fim is null
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
       and not (coalesce(c.vistos, '{}'::jsonb) ? (x ->> 'codigo'))   -- 0318: Visto hoje
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
    union all
    -- (l) 0202: o portal consultou outra rua (ou disse "sem viabilidade" com a fachada viável no DFV) — o time confere a rua
    select 'conferir_rua', c.id::text, c.id, c.venda_id, n.nome, c.rua_conferir_em,
           case when c.rua_conferir_em < now() - interval '4 hours' then 1 else 2 end,
           format('%s — cliente: %s, nº %s · portal: %s%s. Refaça na Cobertura escolhendo a rua do cliente e marque "Conferi"%s',
                  case c.rua_conferir ->> 'motivo' when 'rua_divergente' then 'O portal consultou OUTRA RUA'
                       else 'O portal disse sem viabilidade, mas a fachada está viável no DFV' end,
                  coalesce(nullif(c.rua_conferir ->> 'esperada', ''), c.endereco_cep ->> 'logradouro', '?'), coalesce(c.numero, '?'),
                  coalesce(nullif(split_part(c.rua_conferir ->> 'portal', ',', 1), ''), '?'),
                  coalesce(' · DFV: ' || nullif(c.rua_conferir ->> 'dfv', ''), ''),
                  case when c.rua_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.rua_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274: Saída sai do Conferir
    union all
    -- (n) 0233: unidade a confirmar — o portal tem lista fechada de unidades e a do cliente não bate (ou ele disse "nenhuma
    -- dessas", ou o endereço não tem nenhuma cadastrada). Dono: backoffice. Prazo: 4 h.
    select 'conferir_unidade', c.id::text, c.id, c.venda_id, n.nome, c.unidade_conferir_em,
           case when c.unidade_conferir_em < now() - interval '4 hours' or c.unidade_conferir ->> 'motivo' <> 'escolher' then 1 else 2 end,
           format('%s · %s, nº %s%s',
                  case c.unidade_conferir ->> 'motivo'
                       when 'escolher' then format('Unidade a confirmar — viável no endereço; o cliente disse "%s" e o portal tem: %s. A Mari está perguntando qual é; se ele não escolher, confirme com ele. No pedido, escolha a unidade DELE (nunca outra)',
                                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), 'nada'), coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       when 'nenhuma' then format('Unidade fora do cadastro da Nio — o cliente disse que a unidade dele não é nenhuma de: %s. Peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                                  coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       else format('Endereço sem unidade cadastrada na Nio (complemento "%s") — peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), c.complemento, '?')) end,
                  coalesce(c.endereco_cep ->> 'logradouro', 'CEP ' || c.cep, '?'), coalesce(c.numero, '?'),
                  case when c.unidade_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.unidade_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274
    union all
    -- (o) 0274: Retomada — o D3 saiu há 1 dia e o cliente não respondeu: o time liga (nunca automático). Some quando o D7 sai.
    select 'retomada_ligar', c.id::text, c.id, c.venda_id, n.nome, c.retomada_passo_em + interval '1 day', 2,
           format('Retomada: a Mari mandou o D3 em %s e o cliente não respondeu — ligue para %s. Se não atender, o D7 sai em %s',
                  to_char(c.retomada_passo_em at time zone 'America/Sao_Paulo', 'DD/MM'), c.telefone,
                  to_char(public._retomada_quando(c, 'D7') at time zone 'America/Sao_Paulo', 'DD/MM'))
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.retomada_desde is not null and c.retomada_fim_em is null and c.retomada_passo = 'D3'
       and c.retomada_passo_em < now() - interval '1 day' and not coalesce(c.nao_contatar, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano' and t.created_at > c.retomada_passo_em)
       and (c.retomada_ligacao_em is null or c.retomada_ligacao_em < c.retomada_passo_em)   -- 0315: ligação registrada tira a linha
    union all
    -- (m) 0210: o robô do GED360 está barrado (2+ leituras seguidas com erro) — sem ele ninguém fica sabendo da biometria
    select 'ged360_barrado', 'ged360', null::uuid, null::uuid, 'Robô do GED360', g.desde, 1,
           case when g.erro ilike '%simult%'
                then format('O robô do GED360 não lê desde %s: alguém entrou no GED360 com o login do robô ("logins simultâneos"). Saia do GED360 e use "⟳ Consultar no GED360" na ficha — sem o robô, biometria aprovada não avisa ninguém',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'HH24:MI'))
                else format('O robô do GED360 não lê desde %s (%s leituras com erro: %s) — biometria aprovada não avisa ninguém até voltar',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), g.n, left(g.erro, 120)) end
      from (select (select min(l.lida_em) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as desde,
                   (select count(*) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as n,
                   (select l.erro from public.ged360_leituras l order by l.lida_em desc limit 1) as erro,
                   (select l.ok from public.ged360_leituras l order by l.lida_em desc limit 1) as ultima_ok) g
     where g.ultima_ok = false and g.n >= 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;

commit;
