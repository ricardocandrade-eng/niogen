-- NIOGEN | tests/fluxos/sim.sql | 17/11/2026 — Claude Code
-- Resumo: o simulador do portão dos fluxos. Instalado SÓ na cópia local do banco (tests/fluxos/copia_local.sh), nunca na
-- produção. Cria o esquema "sim" com um Chatwoot de mentira (conversa, status, dono, time, etiquetas e as 3 automações da
-- conta) e funções que fazem o papel do n8n (webhook do Chatwoot → espelho, guard da Mari, fila do backoffice, cadência).
-- As funções do NIOGEN chamadas aqui são as DE VERDADE (as mesmas da produção): o que se testa é o comportamento delas.
--
-- O que é suposição (não dá para ler do código, só dos documentos — conferir no Chatwoot real antes de confiar):
--   S1. Qualquer mudança na conversa (status, dono, time, etiqueta) e toda mensagem do cliente disparam as automações
--       24389/24390 ("conversa atualizada" + etiqueta handoff-venda/handoff-humano → time backoffice).
--   S2. Ao resolver, a 24387 (tira dono e time) roda DEPOIS das 24389/24390.
--   S3. Ação feita por automação não dispara automação de novo.
--   S4. Mensagem do cliente em conversa resolvida ou adiada reabre a conversa (lock_to_single_conversation).
--   S5. A resposta da Mari é uma fala fixa ("[resposta simulada da Mari]"): o simulador não chama o Claude.

drop schema if exists sim cascade;
create schema sim;
drop table if exists sim.cw, sim.trilha, sim.checagens, sim.envios cascade;

create table sim.cw (
  conv text primary key, status text not null default 'open', agente text, time_nome text,
  etiquetas text[] not null default '{}', telefone text, nome text);
create table sim.trilha (n bigserial primary key, em timestamptz default clock_timestamp(), quem text, o_que text);
create table sim.checagens (n bigserial primary key, tipo text, nome text, ok boolean, detalhe text);
create table sim.envios (n bigserial primary key, em timestamptz default clock_timestamp(), conversa uuid, por text, texto text);

create or replace function sim.diz(p_quem text, p_o_que text) returns void language sql as
$$ insert into sim.trilha (quem, o_que) values (p_quem, p_o_que) $$;

-- quem está "logado" (o mesmo request.jwt.claims da Supabase). perfil: admin | backoffice | vendedor | servico
create or replace function sim.como(p_perfil text) returns text language plpgsql as $$
declare u uuid;
begin
  if p_perfil = 'servico' then
    perform set_config('request.jwt.claims', '{"role":"service_role"}', false);
  else
    select id into u from public.usuarios where perfil = p_perfil order by id limit 1;
    if u is null then raise exception 'sim.como: não há usuário com perfil %', p_perfil; end if;
    perform set_config('request.jwt.claims', jsonb_build_object('role', 'authenticated', 'sub', u)::text, false);
  end if;
  return p_perfil;
end $$;

create or replace function sim._servico() returns void language sql as
$$ select set_config('request.jwt.claims', '{"role":"service_role"}', true) $$;

-- ───────────────────────── Chatwoot de mentira ─────────────────────────

-- n8n mari_principal: todo evento do Chatwoot passa pelo 2t (espelho); "resolvida" passa também pelo 2v.
create or replace function sim._webhook(p_conv text, p_evento text) returns void language plpgsql as $$
declare w sim.cw;
begin
  perform sim._servico();
  select * into w from sim.cw where conv = p_conv;
  perform public.mari_chatwoot_sync(p_conv, w.status, w.agente, w.time_nome, w.etiquetas);
  if p_evento = 'resolvida' then perform public.mari_encerrar_ciclo(p_conv); end if;
end $$;

-- as 3 automações da conta 195428 (INFRA §Chatwoot). Suposições S1–S3 no cabeçalho.
create or replace function sim._automacoes(p_conv text, p_evento text) returns void language plpgsql as $$
declare w sim.cw;
begin
  -- G-3 (0266): desligadas na conta quando config_regras.chatwoot_automacoes = 'desligadas'
  if exists (select 1 from public.config_regras where chave = 'chatwoot_automacoes' and valor #>> '{}' = 'desligadas') then return; end if;
  select * into w from sim.cw where conv = p_conv;
  if w.time_nome is null and w.etiquetas && array['handoff-venda', 'handoff-humano'] then
    update sim.cw set time_nome = 'backoffice' where conv = p_conv;
    perform sim.diz('automação 24389/24390', 'etiqueta handoff-* numa conversa atualizada → atribuiu o time backoffice');
    perform sim._webhook(p_conv, 'atualizada');
  end if;
  if p_evento = 'resolvida' then
    select * into w from sim.cw where conv = p_conv;
    if w.agente is not null or w.time_nome is not null then
      update sim.cw set agente = null, time_nome = null where conv = p_conv;
      perform sim.diz('automação 24387', 'conversa resolvida → tirou dono e time');
      perform sim._webhook(p_conv, 'atualizada');
    end if;
  end if;
end $$;

-- muda a conversa no Chatwoot. p: {status, agente, time, add[], remove[], labels[]}. p_por: api | humano | cliente | automacao
create or replace function sim.cw_mudar(p_conv text, p jsonb, p_por text default 'api') returns boolean language plpgsql as $$
declare a sim.cw; d sim.cw; ev text;
begin
  select * into a from sim.cw where conv = p_conv for update;
  if not found then raise exception 'sim.cw_mudar: conversa % não existe no Chatwoot de mentira', p_conv; end if;
  d := a;
  if p ? 'status' then d.status := p ->> 'status'; end if;
  if p ? 'agente' then d.agente := nullif(p ->> 'agente', ''); end if;
  if p ? 'time'   then d.time_nome := nullif(p ->> 'time', ''); end if;
  if p ? 'labels' then d.etiquetas := array(select jsonb_array_elements_text(p -> 'labels')); end if;
  if p ? 'add' then
    d.etiquetas := array(select distinct x from unnest(d.etiquetas || array(select jsonb_array_elements_text(p -> 'add'))) x order by 1);
  end if;
  if p ? 'remove' then
    d.etiquetas := array(select x from unnest(d.etiquetas) x where x <> all (array(select jsonb_array_elements_text(p -> 'remove'))) order by 1);
  end if;
  d.etiquetas := array(select distinct x from unnest(d.etiquetas) x order by 1);
  if d is not distinct from a then return false; end if;
  update sim.cw set status = d.status, agente = d.agente, time_nome = d.time_nome, etiquetas = d.etiquetas where conv = p_conv;
  ev := case when d.status = 'resolved' and a.status <> 'resolved' then 'resolvida' else 'atualizada' end;
  perform sim.diz('Chatwoot (' || p_por || ')', 'conversa ' || p_conv || ': ' ||
    concat_ws(' · ',
      case when d.status is distinct from a.status then 'status ' || a.status || ' → ' || d.status end,
      case when d.agente is distinct from a.agente then 'dono ' || coalesce(a.agente, '—') || ' → ' || coalesce(d.agente, '—') end,
      case when d.time_nome is distinct from a.time_nome then 'time ' || coalesce(a.time_nome, '—') || ' → ' || coalesce(d.time_nome, '—') end,
      case when d.etiquetas is distinct from a.etiquetas then 'etiquetas [' || array_to_string(d.etiquetas, ', ') || ']' end));
  perform sim._webhook(p_conv, ev);
  if p_por <> 'automacao' then perform sim._automacoes(p_conv, ev); end if;
  return true;
end $$;

create or replace function sim._conv(p_conversa uuid) returns text language sql stable as
$$ select chatwoot_conversation_id from public.mari_conversas where id = p_conversa $$;

-- ───────────────────────── n8n backoffice_chatwoot: a fila ─────────────────────────
-- Roda rodadas até a fila esvaziar (cada rodada = 1 execução do workflow). Devolve quantas ações executou.
create or replace function sim.fila_rodar(p_max_rodadas int default 12) returns int language plpgsql as $$
declare a jsonb; n int; total int := 0; r int := 0; v_conv text; v_tipo text; corpo jsonb; c public.mari_conversas; lote jsonb[];
begin
  loop
    r := r + 1;
    perform sim._servico();
    select coalesce(array_agg(x), '{}') into lote from public.backoffice_acoes_proximas(50) x;
    n := coalesce(array_length(lote, 1), 0);
    exit when n = 0;
    if r > p_max_rodadas then
      perform sim.diz('SIMULADOR', 'a fila não esvaziou em ' || p_max_rodadas || ' rodadas — laço');
      exit;
    end if;
    -- o n8n executa as etiquetas primeiro e o resto na ordem do id (0083)
    for a in select x from unnest(lote) x order by (x ->> 'tipo' <> 'etiquetas'), (x ->> 'id')::bigint loop
      v_tipo := a ->> 'tipo'; corpo := coalesce(a -> 'corpo', '{}'::jsonb);
      v_conv := regexp_replace(a ->> 'url_base', '^.*/conversations/', '');
      select m.* into c from public.chatwoot_acoes q join public.mari_conversas m on m.id = q.conversa_id where q.id = (a ->> 'id')::bigint;
      if exists (select 1 from sim.cw where conv = v_conv) then perform sim.diz('fila → Chatwoot', v_tipo || ' (' || coalesce(a ->> 'momento', '-') || ') ' ||
        case v_tipo when 'etiquetas' then 'add ' || (a ->> 'add') || ' remove ' || (a ->> 'remove')
                    when 'mensagem' then '"' || left(coalesce(corpo ->> 'content', ''), 70) || '"'
                    when 'nota' then '' else corpo::text end); end if;
      if not exists (select 1 from sim.cw where conv = v_conv) then
        perform public.backoffice_acao_resultado((a ->> 'id')::bigint, true);   -- conversa real, fora do cenário: só baixa
        continue;
      end if;
      if v_tipo = 'etiquetas' then
        perform sim.cw_mudar(v_conv, jsonb_build_object('add', a -> 'add', 'remove', a -> 'remove'));
      elsif v_tipo in ('atribuir', 'desatribuir') then
        perform sim.cw_mudar(v_conv,
          (case when corpo ? 'assignee_id' then jsonb_build_object('agente', case when corpo ->> 'assignee_id' is null then null else 'Pessoa do time' end) else '{}'::jsonb end)
          || (case when corpo ? 'team_id' then jsonb_build_object('time', case when corpo ->> 'team_id' is null then null else 'backoffice' end) else '{}'::jsonb end));
      elsif v_tipo = 'resolver' then
        perform sim.cw_mudar(v_conv, jsonb_build_object('status', coalesce(corpo ->> 'status', 'resolved')));
      elsif v_tipo = 'mensagem' then
        insert into sim.envios (conversa, por, texto)
        values (c.id, case when (a ->> 'usuario')::boolean then 'time' else 'fila' end, corpo ->> 'content');
        if (a ->> 'usuario')::boolean then   -- fala de usuário: o n8n grava o turno "humano" (2y)
          perform public.mari_registrar_turno(c.telefone, c.nome_contato, corpo ->> 'content', 'humano', 'whatsapp', v_conv);
        end if;
        perform sim._webhook(v_conv, 'atualizada');
      else
        perform sim._webhook(v_conv, 'atualizada');   -- nota privada: só o espelho
      end if;
      perform sim._servico();
      perform public.backoffice_acao_resultado((a ->> 'id')::bigint, true);
      total := total + 1;
    end loop;
  end loop;
  return total;
end $$;

-- As rotinas de relógio: a fila (1 min) e a varredura de 10 min (n8n indicacao_rotina → indicacao_tick, que também fecha
-- conversa de Saída e de instalado). Devolve quantas ordens ao Chatwoot foram executadas.
-- 21/11 (F1, F2 e X37 vermelhos à noite): as rotinas da pós-instalação e da indicação só mandam no horário dos toques
-- (config_regras.mari_horario_toques, 9h–21h desde a 0304). O relógio do simulador é o de verdade, então depois das 21h nada saía
-- e o resto do cenário quebrava. Fora do horário, o tique roda a rotina com o relógio de agora e a janela aberta o dia todo só
-- durante a chamada (adiantar o relógio fazia vencer outras esperas, como o "insistir" da indicação). Quem testa o próprio
-- horário (H6, X38, X53, B8) chama as rotinas com hora fixa (sim.hora), não passa por aqui.
create or replace function sim._indicacao_tick_no_horario() returns void language plpgsql as $$
declare v jsonb;
begin
  if public.mari_no_horario(now(), null) then perform public.indicacao_tick(now()); return; end if;
  select valor into v from public.config_regras where chave = 'mari_horario_toques';
  update public.config_regras set valor = coalesce(v, '{}'::jsonb) || '{"abre": "00:00", "fecha": "24:00", "todos_os_dias": true}'::jsonb
   where chave = 'mari_horario_toques';
  perform public.indicacao_tick(now());
  update public.config_regras set valor = v where chave = 'mari_horario_toques';
end $$;

create or replace function sim.tique() returns int language plpgsql as $$
declare n int;
begin
  perform sim._servico();
  n := sim.fila_rodar();
  perform sim._indicacao_tick_no_horario();   -- 21/11: era indicacao_tick(now()) — à noite a pós-instalação ficava agendada (F1, F2, X37)
  return n + sim.fila_rodar();
end $$;

-- "Passou X e nada aconteceu": empurra o relógio da conversa e roda as rotinas (de 10 em 10 min quando X é curto)
create or replace function sim.espera(p_conversa uuid, p_intervalo interval) returns void language plpgsql as $$
declare falta interval := p_intervalo; passo interval;
begin
  while falta > interval '0' loop
    passo := least(falta, case when p_intervalo <= interval '1 hour' then interval '10 minutes' else p_intervalo end);
    perform sim.passa(p_conversa, passo); perform sim.tique();
    falta := falta - passo;
  end loop;
end $$;

-- ───────────────────────── cliente e Mari ─────────────────────────

-- cliente manda mensagem. Devolve o que a Mari fez: 'respondeu' | 'calada: <motivo>'
-- p_depois: quanto tempo depois do último acontecimento o cliente escreve (padrão 3 min; '0' = na mesma hora, para testar corrida)
-- p_midia: anexo (áudio, imagem, figurinha) no formato que o n8n manda: [{"tipo":"image",...}]
create or replace function sim.cliente_escreve(p_conversa uuid, p_texto text, p_mari_responde boolean default true, p_depois interval default '3 minutes',
                                              p_midia jsonb default null)
returns text language plpgsql as $$
declare v_conv text := sim._conv(p_conversa); w sim.cw; motivo text; r jsonb;
begin
  if p_depois > interval '0' then perform sim.espera(p_conversa, p_depois); end if;
  select * into w from sim.cw where conv = v_conv;
  if not found then raise exception 'sim.cliente_escreve: conversa fora do simulador'; end if;
  perform sim.diz('cliente', '"' || p_texto || '"' || case when p_midia is not null then ' + anexo' else '' end);
  if w.status in ('resolved', 'snoozed') then
    perform sim.cw_mudar(v_conv, '{"status":"open"}', 'cliente');          -- S4
  else
    perform sim._automacoes(v_conv, 'atualizada');                           -- S1
  end if;
  perform sim._webhook(v_conv, 'atualizada');                                -- 2t na mensagem
  select * into w from sim.cw where conv = v_conv;
  -- 2h · Guard humano (lê o Chatwoot ao vivo)
  motivo := case when 'nao-contatar' = any (w.etiquetas) then 'etiqueta nao-contatar'
                 when w.agente is not null then 'humano atribuído'
                 when w.time_nome is not null and not ('handoff-venda' = any (w.etiquetas)) then 'time atribuído'
                 when w.status = 'resolved' then 'conversa resolvida' end;
  perform sim._servico();
  if motivo is not null then
    perform public.mari_registrar_turno(w.telefone, w.nome, p_texto, 'lead', 'whatsapp', v_conv, p_midia);   -- 2r
    perform sim.diz('Mari', 'calada pelo guard do n8n: ' || motivo);
    return 'calada: ' || motivo;
  end if;
  r := public.mari_entrada(w.telefone, w.nome, p_texto, 'whatsapp', null, v_conv, p_midia);        -- 3a
  if (r ->> 'silencio')::boolean then
    perform sim.diz('Mari', 'calada pelo banco (status ' || (r ->> 'status') ||
      case when (r ->> 'optout')::boolean then ', cliente pediu para parar' when (r ->> 'pos_venda')::boolean then ', pós-venda' else '' end || ')');
    return 'calada: banco (' || (r ->> 'status') || ')';
  end if;
  if not p_mari_responde then return 'vez da Mari'; end if;
  if not sim.mari_fala((r ->> 'conversa_id')::uuid, '[resposta simulada da Mari]', '{}'::jsonb, (r ->> 'ts')::timestamptz) then
    return 'calada: banco (consolidar)';
  end if;
  return 'respondeu';
end $$;

-- fala da Mari (10b · mari_salvar_turno); p_upd é o que o motor extrairia da conversa (etapa, plano, dados…)
create or replace function sim.mari_fala(p_conversa uuid, p_texto text default '[resposta simulada da Mari]',
                                         p_upd jsonb default '{}'::jsonb, p_ts timestamptz default null)
returns boolean language plpgsql as $$
declare k jsonb;
begin
  perform sim._servico();
  if p_ts is not null then
    k := public.mari_consolidar(p_conversa, p_ts);   -- 3c; o 3d só segue com resultado = ok
    if k ->> 'resultado' <> 'ok' then perform sim.diz('Mari', 'não respondeu: o banco devolveu "' || (k ->> 'resultado') || '"'); return false; end if;
  end if;
  perform public.mari_salvar_turno(p_conversa, p_texto, null, 'simulador', null, null, null, p_upd);
  insert into sim.envios (conversa, por, texto) values (p_conversa, 'mari', p_texto);
  perform sim.diz('Mari', 'respondeu');
  perform sim._webhook(sim._conv(p_conversa), 'atualizada');   -- eco da mensagem do bot: só espelho
  return true;
end $$;

-- lead novo: cria a conversa no Chatwoot de mentira e manda a 1ª mensagem. Devolve o id da conversa no NIOGEN.
-- p_tel: telefone de uma conversa anterior (o mesmo cliente abrindo conversa NOVA no Chatwoot)
create or replace function sim.lead_novo(p_nome text default 'Cliente Simulado', p_texto text default 'Oi, vi o anúncio e quero saber da internet',
                                         p_tel text default null)
returns uuid language plpgsql as $$
declare v_conv text; v_tel text; w sim.cw; r jsonb;
begin
  v_conv := (990000 + (select count(*) from sim.cw) + 1)::text;
  v_tel := coalesce(p_tel, '55319' || lpad((80000000 + floor(random() * 9999999))::bigint::text, 8, '0'));
  insert into sim.cw (conv, telefone, nome) values (v_conv, v_tel, p_nome);
  perform sim.diz('cliente', 'lead novo "' || p_nome || '": "' || p_texto || '"');
  perform sim._webhook(v_conv, 'atualizada');
  perform sim._servico();
  r := public.mari_entrada(v_tel, p_nome, p_texto, 'whatsapp', null, v_conv);
  if not (r ->> 'silencio')::boolean then
    perform sim.mari_fala((r ->> 'conversa_id')::uuid, '[abertura simulada da Mari]', '{}'::jsonb, (r ->> 'ts')::timestamptz);
  end if;
  return (r ->> 'conversa_id')::uuid;
end $$;

-- handoff da Mari: banco (9 · mari_handoff) + Chatwoot (9e etiquetas, 9h time). Devolve a resposta do banco.
create or replace function sim.mari_handoff(p_conversa uuid, p_motivo text, p_lead jsonb default '{}'::jsonb)
returns jsonb language plpgsql as $$
declare v_conv text := sim._conv(p_conversa); r jsonb; tipo text; atuais text[];
begin
  select etiquetas into atuais from sim.cw where conv = v_conv;   -- lidas no início da execução (2g)
  perform sim._servico();
  r := public.mari_handoff(p_conversa, p_motivo, p_lead);
  perform sim.diz('Mari', 'handoff "' || p_motivo || '" → ' || r::text);
  tipo := case when p_motivo = 'dados_completos' then 'venda'
               when p_motivo in ('pedido_humano', 'objecao', 'urgencia_alta') then 'humano'
               when p_motivo in ('recusa_compra', 'fora_de_area', 'sem_cobertura', 'interesse_caindo', 'multiplos_decisores', 'sem_contato', 'ja_cliente_nio') then 'saida'
               else 'humano' end;
  perform sim.cw_mudar(v_conv, jsonb_build_object('labels', to_jsonb(atuais || case tipo when 'venda' then array['handoff', 'handoff-venda']
                                                                              when 'humano' then array['handoff', 'handoff-humano']
                                                                              else array['handoff'] end)));
  if tipo in ('venda', 'humano') then perform sim.cw_mudar(v_conv, '{"time":"backoffice"}'); end if;
  return r;
end $$;

-- alguém do time mexe DIRETO no Chatwoot (fora do NIOGEN). p: {status, agente, time, add[], remove[]}
create or replace function sim.time_no_chatwoot(p_conversa uuid, p jsonb) returns boolean language sql as
$$ select sim.cw_mudar(sim._conv(p_conversa), p, 'humano') $$;

-- alguém do time responde DIRETO no Chatwoot
create or replace function sim.time_fala_no_chatwoot(p_conversa uuid, p_texto text) returns void language plpgsql as $$
declare v_conv text := sim._conv(p_conversa); w sim.cw;
begin
  select * into w from sim.cw where conv = v_conv;
  perform sim.diz('time (no Chatwoot)', '"' || p_texto || '"');
  insert into sim.envios (conversa, por, texto) values (p_conversa, 'time', p_texto);
  perform sim._webhook(v_conv, 'atualizada');
  perform sim._servico();
  perform public.mari_registrar_turno(w.telefone, w.nome, p_texto, 'humano', 'whatsapp', v_conv);
end $$;

-- ───────────────────────── n8n mari_cadencia ─────────────────────────
-- Uma rodada da cadência no instante p_agora, só para as conversas do simulador. Devolve "passo=resultado" por linha.
create or replace function sim.cadencia(p_agora timestamptz default now()) returns setof text language plpgsql as $$
declare e jsonb; w sim.cw; passo text; da_venda boolean; humano boolean; tem_time boolean; resolvida boolean; nc boolean; cid uuid;
begin
  perform sim._servico();
  for e in select x from public.mari_cadencia_candidatos(p_agora, 'whatsapp', 30) x
            where exists (select 1 from sim.cw s where s.conv = x ->> 'chatwoot_conversation_id') loop
    passo := e ->> 'proximo_passo'; cid := (e ->> 'conversa_id')::uuid;
    select * into w from sim.cw where conv = e ->> 'chatwoot_conversation_id';
    if passo = 'ENCERRAR' then   -- sem envio: vai direto ao registro, sem passar pelo guard (c05)
      perform public.mari_cadencia_registrar(cid, passo, true, null, p_agora, null, e ->> 'excecao');
      perform sim.diz('cadência', 'ENCERRAR (sem envio)'); return next passo || '=encerrou'; continue;
    end if;
    humano := w.agente is not null; tem_time := w.time_nome is not null; resolvida := w.status = 'resolved';
    nc := 'nao-contatar' = any (w.etiquetas);
    da_venda := passo in ('INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIO1', 'BIOVOLTA');
    if da_venda and nc then
      perform public.mari_cadencia_registrar(cid, passo, false, 'aviso da venda não enviado: etiqueta nao-contatar', p_agora);
      perform sim.diz('cadência', passo || ' barrado pelo guard: nao-contatar'); return next passo || '=barrado nao-contatar';
    elsif not da_venda and (humano or tem_time or resolvida or nc) then
      perform public.mari_cadencia_parar(cid, humano, tem_time, resolvida, nc);
      perform sim.diz('cadência', passo || ' parado pelo guard do n8n (dono=' || humano || ' time=' || tem_time || ' resolvida=' || resolvida || ' nc=' || nc || ')');
      return next passo || '=parado pelo guard';
    else
      insert into sim.envios (conversa, por, texto) values (cid, 'cadencia:' || passo, coalesce(e ->> 'texto', '[template ' || coalesce(e ->> 'template', '?') || ']'));
      perform public.mari_cadencia_registrar(cid, passo, true, null, p_agora, coalesce(e ->> 'texto', '[template]'), e ->> 'excecao');
      perform sim.diz('cadência', passo || ' enviado'); return next passo || '=enviado';
      perform sim._webhook(w.conv, 'atualizada');
    end if;
  end loop;
end $$;

-- o que a cadência FARIA agora com esta conversa, segundo o banco (sem enviar)
create or replace function sim.cadencia_ver(p_conversa uuid, p_agora timestamptz default now()) returns jsonb language sql as $$
  select jsonb_build_object('proximo', a.proximo_passo, 'em', a.proximo_em, 'pode', a.pode_enviar, 'bloqueio', a.bloqueio)
    from public.mari_cadencia_avaliar(p_agora, p_conversa) a limit 1 $$;

-- ───────────────────────── tempo ─────────────────────────
-- "Passaram-se X": empurra para trás todas as datas das linhas desta conversa (e da venda dela). O relógio do banco não muda.
create or replace function sim.passa(p_conversa uuid, p_intervalo interval) returns void language plpgsql as $$
declare t record; v_venda uuid; sets text; chave text;
begin
  select venda_id into v_venda from public.mari_conversas where id = p_conversa;
  perform set_config('session_replication_role', 'replica', true);
  for t in
    select c.table_name, max(case when c.column_name = 'conversa_id' then 1 else 0 end) tem_conv,
           max(case when c.column_name = 'venda_id' then 1 else 0 end) tem_venda
      from information_schema.columns c join information_schema.tables tb
        on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type = 'BASE TABLE'
     where c.table_schema = 'public' group by c.table_name
  loop
    select string_agg(format('%I = %I - %L::interval', column_name, column_name, p_intervalo), ', ') into sets
      from information_schema.columns
     where table_schema = 'public' and table_name = t.table_name and data_type in ('timestamp with time zone', 'timestamp without time zone')
       and is_generated = 'NEVER';
    if sets is null then continue; end if;
    if t.table_name = 'mari_conversas' then
      execute format('update public.mari_conversas set %s where id = %L', sets, p_conversa);
    elsif t.table_name = 'vendas' then
      if v_venda is not null then execute format('update public.vendas set %s where id = %L', sets, v_venda); end if;
    elsif t.tem_conv = 1 then
      execute format('update public.%I set %s where conversa_id = %L', t.table_name, sets, p_conversa);
    elsif t.tem_venda = 1 and v_venda is not null then
      execute format('update public.%I set %s where venda_id = %L', t.table_name, sets, v_venda);
    end if;
  end loop;
  perform set_config('session_replication_role', 'origin', true);
  perform sim.diz('relógio', 'passaram-se ' || p_intervalo::text);
end $$;

-- ───────────────────────── retrato e conferências ─────────────────────────
create or replace function sim.foto(p_conversa uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'status', c.status, 'etapa_mari', c.etapa, 'destino', coalesce(c.funil_destino, 'em_andamento'), 'saida_motivo', c.saida_motivo,
    'humano', coalesce(c.humano_atribuido, false), 'time', coalesce(c.time_atribuido, false),
    'trava_resolvida', coalesce(c.chatwoot_resolvida, false), 'nao_contatar', coalesce(c.nao_contatar, false),
    'espelho', jsonb_build_object('status', c.chatwoot_status, 'agente', c.chatwoot_agente, 'time', c.chatwoot_time, 'etiquetas', to_jsonb(coalesce(c.chatwoot_etiquetas, '{}'))),
    'cw', (select jsonb_build_object('status', w.status, 'agente', w.agente, 'time', w.time_nome, 'etiquetas', to_jsonb(w.etiquetas)) from sim.cw w where w.conv = c.chatwoot_conversation_id),
    'venda', (select jsonb_build_object('id', v.id, 'status', v.status) from public.vendas v where v.id = c.venda_id),
    'lead', (select jsonb_agg(jsonb_build_object('etapa', l.etapa, 'status', l.status, 'vez', l.vez, 'destino', l.destino, 'prazo', l.prazo_em, 'saida', l.saida_motivo))
               from public.v_leads l where l.conversa_id = c.id),
    'fila_pendente', (select count(*) from public.chatwoot_acoes a where a.conversa_id = c.id and a.status in ('pendente', 'executando')),
    'fila_erro', (select count(*) from public.chatwoot_acoes a where a.conversa_id = c.id and a.status = 'erro'))
  from public.mari_conversas c where c.id = p_conversa $$;

create or replace function sim.confere(p_nome text, p_ok boolean, p_detalhe text default null) returns boolean language plpgsql as $$
begin
  insert into sim.checagens (tipo, nome, ok, detalhe) values ('cenario', p_nome, coalesce(p_ok, false), p_detalhe);
  return coalesce(p_ok, false);
end $$;

-- Os eventos em que a porta já manda (passo 5): grupo 1 = Saída e Reabrir (0265) · grupo 2 = dono e Chatwoot (0266) ·
-- grupo 3 = botões da ficha (0268). Os robôs da Nio (nio:*, funil:*) só são anotados: ficam na R10 (aviso).
-- Grupo novo que virar a chave entra aqui.
create or replace function sim.porta_manda(p_evento text, p_antes text) returns boolean language sql immutable as $$
  select p_evento ~ '^(saida:|silenciar:|reabrir$|nao_contatar$|prazo:|time_respondeu$|soprar$|mari_passou:(interesse_caindo|multiplos_decisores)$|momento:|virar_venda$|trocar_titular$|mover_admin:|antifraude:)'
      or (p_evento = 'cliente_escreveu' and p_antes in ('saida_pode_voltar', 'saida_definitiva', 'nao_contatar', 'cliente_nio',
                                                       'em_espera', 'time_esperando')) $$;

-- As regras que valem em QUALQUER cenário, conferidas no estado final. Cada uma tem um código fixo (R1…): o relatório
-- soma por código, para mostrar qual regra mais quebra.
create or replace function sim.invariantes(p_conversa uuid) returns void language plpgsql as $$
declare f jsonb := sim.foto(p_conversa); cw jsonb; esp jsonb; l jsonb; saida boolean; n_lead int; n_sit int; v_sit text;
begin
  cw := f -> 'cw'; esp := f -> 'espelho'; l := f -> 'lead' -> 0; n_lead := coalesce(jsonb_array_length(f -> 'lead'), 0);
  saida := coalesce(l ->> 'destino', f ->> 'destino') not in ('em_andamento', 'instalada') or coalesce(f -> 'venda' ->> 'status', '') = 'saida';

  insert into sim.checagens (tipo, nome, ok, detalhe) values
  ('R1', 'O NIOGEN enxerga o Chatwoot como ele está (status, dono, time, etiquetas)',
     coalesce(esp ->> 'status', 'open') = cw ->> 'status' and (esp ->> 'agente' is null) = (cw ->> 'agente' is null)
     and (esp ->> 'time' is null) = (cw ->> 'time' is null) and (esp -> 'etiquetas') @> (cw -> 'etiquetas') and (cw -> 'etiquetas') @> (esp -> 'etiquetas'),
     'NIOGEN: ' || esp::text || ' · Chatwoot: ' || cw::text),
  ('R2', 'O dono gravado no NIOGEN é o dono do Chatwoot',
     (f ->> 'humano')::boolean = (cw ->> 'agente' is not null) and (f ->> 'time')::boolean = (cw ->> 'time' is not null),
     'NIOGEN: pessoa=' || (f ->> 'humano') || ' time=' || (f ->> 'time') || ' · Chatwoot: dono=' || coalesce(cw ->> 'agente', '—') || ' time=' || coalesce(cw ->> 'time', '—')),
  ('R3', 'Não sobra ordem ao Chatwoot pendente nem em erro',
     (f ->> 'fila_pendente')::int = 0 and (f ->> 'fila_erro')::int = 0,
     'pendentes=' || (f ->> 'fila_pendente') || ' em erro=' || (f ->> 'fila_erro')),
  ('R4', 'Cada lead aparece uma vez só na escada', n_lead = 1, 'linhas na escada: ' || n_lead),
  ('R5', 'Lead em andamento tem de quem é a vez',
     saida or coalesce(l ->> 'destino', '') = 'instalada' or l ->> 'vez' is not null,
     'escada: ' || coalesce(l::text, 'sem linha')),
  ('R6', 'Não contatar: coluna e etiqueta dizem a mesma coisa',
     (f ->> 'nao_contatar')::boolean = ((cw -> 'etiquetas') ? 'nao-contatar'),
     'coluna=' || (f ->> 'nao_contatar') || ' · etiquetas=' || (cw -> 'etiquetas')::text),
  ('R7', 'Nenhuma mensagem saiu duas vezes',
     not exists (select 1 from sim.envios e where e.conversa = p_conversa and e.texto not like '[%simulada%' group by e.texto having count(*) > 1),
     (select string_agg(x, ' | ') from (select count(*) || '× "' || left(e.texto, 50) || '"' x from sim.envios e where e.conversa = p_conversa and e.texto not like '[%simulada%' group by e.texto having count(*) > 1) q));
  -- R8 (passo 4, porta única em sombra — 0257): todo lead cai em exatamente uma das 15 situações
  if to_regclass('public.v_lead_situacao') is not null then
    execute 'select count(*), max(situacao) from public.v_lead_situacao where conversa_id = $1' into n_sit, v_sit using p_conversa;
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('R8', 'Todo lead tem exatamente uma situação da lista (porta única em sombra)', n_sit = 1 and v_sit is not null,
       'linhas: ' || n_sit || ' · situação: ' || coalesce(v_sit, 'nenhuma') || ' · escada: ' || coalesce(l::text, 'sem linha'));
  end if;
  -- R9 (aviso, 0258): a situação em sombra concorda com o Chatwoot? (vira bloqueio no passo 5, quando a situação mandar)
  if to_regclass('public.v_lead_situacao_divergencias') is not null then
    execute 'select count(*), string_agg(item || '': esperado '' || esperado || '', está '' || de_fato, '' · '') from public.v_lead_situacao_divergencias where conversa_id = $1'
      into n_sit, v_sit using p_conversa;
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('R9', 'A situação (porta única em sombra) concorda com o Chatwoot', n_sit = 0, v_sit);
  end if;
  -- R10 (aviso, 0263): cada evento deste lead, a tabela situação × evento previu o que o sistema fez?
  -- R11 (bloqueio, 0263): as cascas da porta estão no lugar (uma migration que reescrever a função pelo nome antigo apaga a sombra)
  if to_regclass('public.porta_sombra') is not null then
    execute 'select count(*), string_agg(evento || '' ('' || coalesce(antes, ''?'') || '' → '' || coalesce(depois, ''?'') || ''): ''
                 || case when aceito is null then ''sem regra'' when aceito then ''previa '' || array_to_string(para, ''/'') else ''recusaria'' end, '' · '' order by id)
               from public.porta_sombra where conversa_id = $1 and concorda is distinct from true and not sim.porta_manda(evento, antes)'
      into n_sit, v_sit using p_conversa;
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('R10', 'A porta em sombra concorda com o sistema (cada evento foi para onde a tabela manda)', n_sit = 0, v_sit);
    -- R12 (BLOQUEIO, 0265 — passo 5): nos eventos em que a porta já manda (Saída e Reabrir), tabela e sistema concordam sempre
    execute 'select count(*), string_agg(evento || '' ('' || coalesce(antes, ''?'') || '' → '' || coalesce(depois, ''?'') || ''): ''
                 || case when aceito is null then ''sem regra'' when aceito then ''previa '' || array_to_string(para, ''/'') else ''recusaria'' end, '' · '' order by id)
               from public.porta_sombra where conversa_id = $1 and concorda is distinct from true and sim.porta_manda(evento, antes)'
      into n_sit, v_sit using p_conversa;
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('R12', 'Onde a porta já manda (Saída e Reabrir · dono e Chatwoot · botões da ficha), o sistema fez o que a tabela diz', n_sit = 0, v_sit);
    execute 'select string_agg(distinct e.funcao, '', '') from public.config_evento e
               where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                  where n.nspname = ''public'' and p.proname = e.funcao and p.prosrc like ''%_porta_anotar%'')'
      into v_sit;
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('R11', 'A porta em sombra está ligada em todas as funções que mudam um lead', v_sit is null, 'sem a casca: ' || v_sit);
  end if;
  -- R13 (BLOQUEIO, 0272 — passo 6, caso Geraldo): o botão que a Live sugere (v_jornada.botao) é uma ação que a porta aceita
  -- na situação do lead. Ex.: "OS e agenda" com a biometria pendente era sugerido e a porta recusava (OS só com biometria aprovada).
  -- Só os botões que viram evento entram; "abrir", "biometria" (consultar o GED360), "pendencia"… só abrem a ficha.
  if to_regclass('public.v_jornada') is not null and to_regprocedure('public.porta_prever(text,text)') is not null then
    execute $q$
      select string_agg(j.botao || ' → ' || ev || ' em ' || coalesce(ls.situacao, '?') || ': ' || coalesce(p.frase, 'recusado'), ' · ')
        from public.v_jornada j
        join public.v_lead_situacao ls on (ls.conversa_id = j.conversa_id) or (j.venda_id is not null and ls.venda_id = j.venda_id)
        cross join lateral (select case j.botao when 'os' then 'momento:os_agendar' when 'os_agendar' then 'momento:os_agendar'
                                   when 'agendar' then 'momento:agendar' when 'reagendar' then 'momento:reagendar' when 'pedido' then 'momento:pedido'
                                   when 'assumir' then 'momento:assumir' when 'responder' then 'time_respondeu'
                                   when 'viabilidade' then 'momento:viabilidade:viavel' when 'credito' then 'momento:credito:aprovado' end as ev) e
        cross join lateral public.porta_prever(ls.situacao, e.ev) p
       where (j.conversa_id = $1 or j.venda_id = (select c.venda_id from public.mari_conversas c where c.id = $1))
         and e.ev is not null and p.aceito is false $q$
      into v_sit using p_conversa;
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('R13', 'O botão que a Live sugere é uma ação que a porta aceita nesta situação', v_sit is null, v_sit);
  end if;
  -- R14 (AVISO, 0293 — fase 2, passo 2): a situação GRAVADA pela porta (lead_estado, gravada no fim de cada transação com evento
  -- da porta) é a situação calculada agora (v_lead_situacao). Diferença = algo mudou o lead sem passar pela porta.
  if to_regclass('public.lead_estado') is not null then
    execute $q$
      select string_agg(coalesce(e.situacao, '(nada gravado)') || ' gravada × ' || ls.situacao || ' calculada', ' · ')
        from public.v_lead_situacao ls
        left join public.lead_estado e on e.lead_id = ls.lead_id
       where (ls.conversa_id = $1 or ls.venda_id = (select c.venda_id from public.mari_conversas c where c.id = $1))
         and e.situacao is distinct from ls.situacao $q$
      into v_sit using p_conversa;
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('R14', 'A situação gravada pela porta é a situação de agora (nada mudou por fora da porta)', v_sit is null, v_sit);
  end if;
  if saida then
    insert into sim.checagens (tipo, nome, ok, detalhe) values
    ('S1', 'Saída: conversa resolvida no Chatwoot', cw ->> 'status' in ('resolved', 'snoozed'), 'Chatwoot: ' || (cw ->> 'status')),
    ('S2', 'Saída: sem dono e sem time', cw ->> 'agente' is null and cw ->> 'time' is null,
       'dono=' || coalesce(cw ->> 'agente', '—') || ' time=' || coalesce(cw ->> 'time', '—')),
    ('S3', 'Saída: sem etiqueta de handoff', not ((cw -> 'etiquetas') ?| array['handoff-venda', 'handoff-humano']), (cw -> 'etiquetas')::text),
    ('S4', 'Saída: a conversa não continua "ativa" no NIOGEN', f ->> 'status' <> 'ativo', 'status da conversa: ' || (f ->> 'status') || ' · destino: ' || coalesce(l ->> 'destino', f ->> 'destino')),
    ('S5', 'Saída: conversa e venda dizem a mesma coisa',
       f -> 'venda' is null or f -> 'venda' = 'null'::jsonb or ((f -> 'venda' ->> 'status') = 'saida') = (coalesce(f ->> 'destino', 'em_andamento') not in ('em_andamento', 'instalada')),
       'venda: ' || coalesce(f -> 'venda' ->> 'status', 'sem venda') || ' · destino da conversa: ' || (f ->> 'destino'));
  end if;
end $$;

grant usage on schema sim to public;
grant all on all tables in schema sim to public;
grant all on all sequences in schema sim to public;
grant execute on all functions in schema sim to public;

-- ───────────────────────── atalhos para montar cenários ─────────────────────────
-- CPF sintético válido (dígitos verificadores calculados) a partir de um número
create or replace function sim.cpf(p_n int) returns text language plpgsql immutable as $$
declare b text := lpad((100000000 + p_n)::text, 9, '0'); s int := 0; d1 int; d2 int; i int;
begin
  for i in 1..9 loop s := s + substr(b, i, 1)::int * (11 - i); end loop;
  d1 := (s * 10) % 11; if d1 = 10 then d1 := 0; end if;
  s := 0; for i in 1..9 loop s := s + substr(b, i, 1)::int * (12 - i); end loop; s := s + d1 * 2;
  d2 := (s * 10) % 11; if d2 = 10 then d2 := 0; end if;
  return b || d1 || d2;
end $$;

-- lead que já passou pela Mari: endereço na área, viável no portal, plano escolhido e dados do titular
create or replace function sim.lead_pronto(p_nome text default 'Cliente Simulado') returns uuid language plpgsql as $$
declare c uuid := sim.lead_novo(p_nome); n int;
begin
  n := (sim._conv(c))::int;
  perform sim._servico();
  update public.mari_conversas set
    cep = '36010000', numero = n::text, cidade = 'Juiz de Fora', uf = 'MG', dentro_area = true,
    endereco_cep = jsonb_build_object('logradouro', 'Rua Simulada', 'bairro', 'Centro', 'localidade', 'Juiz de Fora', 'uf', 'MG'),
    elegibilidade = 'ok', segmento = 'varejo', plano_escolhido = 'V-REG-SUP', forma_pagamento = 'boleto', etapa = 'resumo',
    instalacao_preferencia = 'manhã',   -- 0381: no resumo a conversa real já tem a preferência de período (o aviso do crédito pede quando falta)
    nio_viab_resultado = 'viavel', nio_viab_velocidade = '1 Giga', nio_viab_em = now(),
    dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('nome', p_nome, 'cpf', sim.cpf(n), 'email', 'sim' || n || '@exemplo.test', 'telefone_confirmado', true)
  where id = c;
  perform sim.diz('SIMULADOR', 'lead preparado: endereço em Juiz de Fora, viável no portal, plano Super, dados do titular');
  return c;
end $$;

-- lead pronto + handoff "dados completos" (a Mari cria a venda e passa para o time)
create or replace function sim.lead_com_venda(p_nome text default 'Cliente Simulado') returns uuid language plpgsql as $$
declare c uuid := sim.lead_pronto(p_nome); r jsonb;
begin
  r := sim.mari_handoff(c, 'dados_completos', '{}'::jsonb);
  if r ->> 'venda_id' is null then raise exception 'sim.lead_com_venda: a venda não foi criada: %', r; end if;
  perform sim.fila_rodar();
  return c;
end $$;

create or replace function sim.venda(p_conversa uuid) returns uuid language sql stable as
$$ select venda_id from public.mari_conversas where id = p_conversa $$;

grant execute on all functions in schema sim to public;

-- meio-dia de Brasília de hoje: hora fixa para a cadência não depender da hora em que o portão roda (madrugada não envia)
create or replace function sim.meio_dia() returns timestamptz language sql stable as
$$ select date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo' + interval '12 hours' $$;
-- atalhos de leitura
create or replace function sim.cw_de(p_conversa uuid) returns jsonb language sql stable as $$ select sim.foto(p_conversa) -> 'cw' $$;
create or replace function sim.lead_de(p_conversa uuid) returns jsonb language sql stable as $$ select sim.foto(p_conversa) -> 'lead' -> 0 $$;
-- o cliente não responde por p_dias: a cada dia, a cadência roda ao meio-dia e a fila esvazia
create or replace function sim.silencio(p_conversa uuid, p_dias int) returns void language plpgsql as $$
declare i int;
begin
  for i in 1..p_dias loop
    perform sim.passa(p_conversa, '1 day'); perform sim.tique(); perform sim.cadencia(sim.meio_dia()); perform sim.tique();
  end loop;
end $$;
-- chama uma função que DEVE recusar; devolve a mensagem da recusa, ou null se ela aceitou
create or replace function sim.recusa(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql; return null;
exception when others then return sqlerrm;
end $$;
grant execute on all functions in schema sim to public;

-- telefone da conversa (para o mesmo cliente abrir conversa nova)
create or replace function sim.tel(p_conversa uuid) returns text language sql stable as
$$ select telefone from sim.cw where conv = sim._conv(p_conversa) $$;
-- um instante de hoje no horário de Brasília (ex.: sim.hora('03:00'))
create or replace function sim.hora(p_hhmm text) returns timestamptz language sql stable as
$$ select (date_trunc('day', now() at time zone 'America/Sao_Paulo') + p_hhmm::time) at time zone 'America/Sao_Paulo' $$;
grant execute on all functions in schema sim to public;

-- venda pronta para agendar: crédito aprovado e biometria validada (como backoffice). Devolve a conversa.
create or replace function sim.venda_pronta(p_nome text, p_assumir boolean default false) returns uuid language plpgsql as $$
declare c uuid := sim.lead_com_venda(p_nome);
begin
  perform sim.como('backoffice');
  if p_assumir then perform public.backoffice_momento(sim.venda(c), 'assumir'); perform sim.fila_rodar(); perform sim.como('backoffice'); end if;
  perform public.backoffice_momento(sim.venda(c), 'credito', '{"resultado":"aprovado"}');
  perform public.backoffice_momento(sim.venda(c), 'biometria', '{"resultado":"validada"}');
  perform sim.fila_rodar();
  perform sim.como('servico');
  return c;
end $$;
-- a Consulta OS / OSAB leu "Instalada" (o que o operador grava na venda)
create or replace function sim.instalou(p_conversa uuid) returns void language plpgsql as $$
begin
  perform sim._servico();
  update public.vendas set status = '3_instalado', instalado_em = now() where id = sim.venda(p_conversa);
  perform sim.diz('Nio (Consulta OS)', 'instalada');
end $$;
-- quantas mensagens um passo da cadência mandou nesta conversa
create or replace function sim.envios_de(p_conversa uuid, p_por text) returns int language sql stable as
$$ select count(*)::int from sim.envios where conversa = p_conversa and por = p_por $$;
grant execute on all functions in schema sim to public;
