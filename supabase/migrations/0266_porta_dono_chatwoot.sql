-- NIOGEN | supabase/migrations/0266_porta_dono_chatwoot.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 5 do caminho (porta única), 2º grupo: DONO E CHATWOOT — Ricardo, 17/11: "Sim, construa" (desenho + sugestões 1–4).
-- (1) Situação 3 "Com o time — esperando o cliente" passa a existir (C10): pessoa ou time é dono, a vez é do cliente. Era o que a
--     sombra mostrava na produção: 15 "time respondeu" caindo em "Mari atendendo" porque a situação 3 não era derivável.
-- (2) Prazos do time, pela porta (robô _porta_prazos, no indicacao_tick de 10 em 10 min):
--     · prazo:esperando_fechar (C10) — o time falou por último, com uma pessoa como dona, e o cliente não respondeu em 1 h →
--       a conversa fecha sozinha no Chatwoot, COM o dono guardado; se o cliente escrever, reabre com o mesmo dono.
--     · prazo:handoff_sem_resposta (C4) — handoff para o time (pediu uma pessoa, objeção, urgência) sem resposta em 24 h úteis
--       (seg–sex 9–21, sáb 10–16) → o time sai, a Mari volta. (Alerta de 30 min = prazo da tarefa, 0256. Aviso no celular: depois.)
-- (3) C3: "interesse caindo" e "múltiplos decisores" não passam para o time — a conversa fica com a Mari (o 🔥 na Live fica
--     para o debate da Live, decisão 2 de 17/11).
-- (4) C11: em espera, o cliente escreve antes da data → a espera acaba, a conversa abre, a vez é do time (porta, cliente_escreveu).
-- (5) H3: resolvida direto no Chatwoot com a Mari atendendo → além do selo, o NIOGEN reabre na hora (Chatwoot é tela).
-- (6) G-3: as 3 automações do Chatwoot (24387 resolvida → tira dono e time · 24389/24390 handoff-* → time) são DESLIGADAS à mão
--     pelo Ricardo junto desta migration (o n8n já põe o time no handoff — nó 9h). config_regras.chatwoot_automacoes = desligadas
--     registra o combinado (o simulador do portão lê esta chave).
-- Regra 20: estados novos (situação 3) com saída automática e prazo; toda mudança por evento na porta com autor ("o sistema" nos
-- prazos) e anotada em porta_sombra; conferência: R12 do portão (bloqueio) e v_porta_divergencias.
begin;

-- ── (0) combinados ──
insert into public.config_regras (chave, valor, descricao) values
  ('chatwoot_automacoes', '"desligadas"', 'G-3 (17/11): as automações 24387/24389/24390 da conta foram desligadas; o NIOGEN (projetor da porta) e o n8n (9h) fazem o que elas faziam'),
  ('esperando_fechar_min', '60', 'C10: minutos sem resposta do cliente, com uma pessoa dona e a última fala do time, para a conversa fechar sozinha (dono guardado)'),
  ('handoff_sem_resposta_horas_uteis', '24', 'C4: horas úteis do time sem resposta a um handoff para a conversa voltar para a Mari'),
  ('time_horario', '{"1": [9, 21], "2": [9, 21], "3": [9, 21], "4": [9, 21], "5": [9, 21], "6": [10, 16]}', 'horário do time por dia da semana (ISO: 1 = segunda … 7 = domingo; ausente = fechado), America/Sao_Paulo')
on conflict (chave) do nothing;

-- ── (1) situação 3 ──
create or replace function public.lead_situacao(p_status text, p_destino text, p_saida_motivo text, p_em_espera boolean, p_vez text, p_com_dono boolean)
returns text language sql immutable set search_path = public as $$
  select case
    when p_destino = 'instalada' then 'instalada'
    when p_destino = 'teste_duplicada' then 'saida_definitiva'
    when p_destino = 'saida' then case
      when p_saida_motivo = 'nao_contatar' then 'nao_contatar'
      when p_saida_motivo = 'ja_cliente_nio' then 'cliente_nio'
      when p_saida_motivo in ('credito_negado', 'reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude', 'teste_duplicada') then 'saida_definitiva'
      when p_saida_motivo in ('recusou', 'sem_resposta', 'fachada_nao_atendida', 'cidade_nao_atendida') then 'saida_pode_voltar'
      end
    when p_destino = 'em_andamento' then case
      when coalesce(p_em_espera, false) then 'em_espera'
      when p_status in ('pendencia_nio', 'defesa_nio') then 'instalacao_pendencia'
      when p_status in ('aguardando_instalacao', 'aguarda_cartao') then 'instalacao_aguardando'
      when p_status in ('agendar', 'remarcar') then 'instalacao_agendar'
      when p_status = 'abrir_os' then 'qualificado_os'
      when p_status = 'aguarda_biometria' then 'qualificado_biometria'
      when p_status in ('rodar_credito', 'fazer_pedido') then 'qualificado_credito'
      when p_status in ('pediu_humano', 'conferir_200m', 'antifraude_conferir') then 'time_agora'
      when p_status in ('nova', 'respondeu', 'consultando_cep', 'viu_planos') then case
        when p_vez = 'time' then 'time_agora'
        when coalesce(p_com_dono, false) then 'time_esperando'   -- 0266 (C10): o time é dono e a vez é do cliente
        else 'mari_atendendo' end
      end
    end
$$;
-- a assinatura antiga (5 argumentos) segue valendo para quem já a chama: sem dono
create or replace function public.lead_situacao(p_status text, p_destino text, p_saida_motivo text, p_em_espera boolean, p_vez text)
returns text language sql immutable set search_path = public as $$
  select public.lead_situacao(p_status, p_destino, p_saida_motivo, p_em_espera, p_vez, false)
$$;

create or replace view public.v_lead_situacao with (security_invoker = true) as
select l.lead_id, l.conversa_id, l.venda_id, l.nome,
       public.lead_situacao(l.status, l.destino, l.saida_motivo, l.em_espera, l.vez, d.com_dono) as situacao,
       s.numero as situacao_numero, s.nome as situacao_nome,
       l.status, l.destino, l.saida_motivo, l.vez, l.prazo_em, l.em_espera,
       (coalesce(c.nao_contatar, false) and l.destino = 'em_andamento') as sem_mensagens
  from public.v_leads l
  left join public.mari_conversas c on c.id = l.conversa_id
  cross join lateral (select coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false)
                             or c.chatwoot_agente is not null or c.chatwoot_time is not null as com_dono) d
  left join public.config_situacao s on s.codigo = public.lead_situacao(l.status, l.destino, l.saida_motivo, l.em_espera, l.vez, d.com_dono);
grant select on public.v_lead_situacao to authenticated;

update public.config_situacao
   set cw_status = '{open,resolved}', dono = 'time',
       nota = 'derivável desde 0266 (C10): pessoa/time dono e vez do cliente; fecha sozinha em 1 h sem resposta, com o dono guardado'
 where codigo = 'time_esperando';

-- ── (2) a tabela ──
insert into public.config_evento (codigo, nome, funcao, quem, nota) values
  ('prazo:*', 'Prazo do time vencido (robô)', '_porta_prazos', 'sistema', 'esperando_fechar (C10) · handoff_sem_resposta (C4)')
on conflict (codigo) do update set nome = excluded.nome, funcao = excluded.funcao, quem = excluded.quem, nota = excluded.nota;

insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('prazo:esperando_fechar',      'andamento',  '{=}', true, null, 'C10: fecha no Chatwoot com o dono guardado; a situação não muda', null),
  ('prazo:handoff_sem_resposta',  'time_agora', '{mari_atendendo}', true, null, 'C4: 24 h úteis sem resposta do time → a Mari volta', null),
  ('prazo:*',                     '*', null, false, 'Prazo do time só vale com o lead em andamento.', null, null),
  ('mari_passou:multiplos_decisores', 'andamento', '{=}', true, null, 'C3 (0266): fica com a Mari', null),
  ('mari_passou:interesse_caindo',    'andamento', '{=}', true, null, 'C3 (0266): fica com a Mari', null),
  ('cliente_escreveu', 'time_esperando', '{time_agora,=,nao_contatar}', true, null, 'C10: volta para o mesmo dono', null),
  ('cliente_escreveu', 'em_espera', '{time_agora,qualificado_credito,qualificado_biometria,qualificado_os,instalacao_agendar,instalacao_pendencia,mari_atendendo,=,nao_contatar}', true, null,
     'C11 (0266): a espera acaba e a vez volta para quem estava com ela', null),
  ('time_respondeu', 'mari_atendendo', '{time_agora,time_esperando}', true, null, 'C7: responder sem assumir = vira dono; a vez passa ao cliente', null),
  ('time_respondeu', 'time_agora',     '{=,time_esperando}', true, null, 'o time respondeu: agora espera o cliente (situação 3)', null),
  ('time_respondeu', 'time_esperando', '{=}', true, null, null, null),
  ('time_respondeu', '*', '{=}', true, null, null, null)
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota, exige = excluded.exige;

-- ── (3) horas úteis do time ──
create or replace function public._horas_uteis(p_de timestamptz, p_ate timestamptz) returns numeric
language plpgsql stable set search_path = public as $$
declare
  h jsonb := public._bo_cfg('time_horario', '{"1": [9, 21], "2": [9, 21], "3": [9, 21], "4": [9, 21], "5": [9, 21], "6": [10, 16]}'::jsonb);
  d date; ini timestamptz; fim timestamptz; faixa jsonb; total numeric := 0;
begin
  if p_de is null or p_ate is null or p_ate <= p_de then return 0; end if;
  d := (p_de at time zone 'America/Sao_Paulo')::date;
  while d <= (p_ate at time zone 'America/Sao_Paulo')::date and d < (p_de at time zone 'America/Sao_Paulo')::date + 400 loop
    faixa := h -> extract(isodow from d)::int::text;
    if faixa is not null then
      ini := (d + make_time((faixa ->> 0)::int, 0, 0)) at time zone 'America/Sao_Paulo';
      fim := (d + make_time((faixa ->> 1)::int, 0, 0)) at time zone 'America/Sao_Paulo';
      ini := greatest(ini, p_de); fim := least(fim, p_ate);
      if fim > ini then total := total + extract(epoch from fim - ini) / 3600; end if;
    end if;
    d := d + 1;
  end loop;
  return total;
end $$;

-- ── (4) os efeitos novos ──
-- C10: fecha no Chatwoot com o dono guardado
create or replace function public._porta_esperando_fechar(c public.mari_conversas)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f text[];
begin
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[o time falou e o cliente não respondeu — conversa resolvida no Chatwoot com o dono guardado (C10); se ele escrever, volta para o mesmo dono]', false);
  f := public._porta_projetar(c.id, 'esperando_fechar', null, 'resolved');
  return jsonb_build_object('ok', true, 'feito', to_jsonb(f), 'resumo', '✓ resolvida no Chatwoot, dono guardado');
end $$;

-- C4: o time não respondeu o handoff → a Mari volta
create or replace function public._porta_handoff_devolver(c public.mari_conversas)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g uuid := gen_random_uuid(); f text[] := '{}';
begin
  perform public._mari_fechar_ciclo(c.id, 'o time não respondeu em 24 h úteis — a conversa volta para a Mari (C4)');
  -- o espelho já fica sem time (como a 0243): as ordens abaixo tiram no Chatwoot e o webhook confirma
  update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_time = null, chatwoot_resolvida = false,
         cadencia_retorno_em = now()
   where id = c.id returning * into c;
  if c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
    perform public._porta_ordem(g, 1, 'handoff_sem_resposta', c, 'etiquetas',
      jsonb_build_object('add', '[]'::jsonb, 'remove', '["handoff", "handoff-venda", "handoff-humano"]'::jsonb));
    perform public._porta_ordem(g, 2, 'handoff_sem_resposta', c, 'desatribuir', jsonb_build_object('team_id', null));
    perform public._porta_ordem(g, 3, 'handoff_sem_resposta', c, 'desatribuir', jsonb_build_object('assignee_id', null));
    f := f || 'sem time'::text || public._porta_projetar(c.id, 'handoff_sem_resposta',
      '↩ Ninguém do time respondeu este handoff em 24 h úteis — a conversa voltou para a Mari. Se quiser atender, use Assumir no NIOGEN.', 'open');
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(f), 'resumo', '✓ de volta para a Mari');
end $$;

-- C11: o cliente escreveu antes da data da espera
create or replace function public._porta_fim_espera(c public.mari_conversas)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f text[];
begin
  update public.mari_conversas set espera_ate = null, espera_motivo = null, espera_em = null, espera_por = null where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[espera encerrada: o cliente escreveu antes da data (C11) — a vez volta para quem estava com ela]', false);
  f := public._porta_projetar(c.id, 'fim_espera', '▶ Espera encerrada: o cliente escreveu antes da data.', 'open');
  return jsonb_build_object('ok', true, 'feito', to_jsonb(f), 'resumo', '✓ espera encerrada');
end $$;

revoke execute on function public._porta_esperando_fechar(public.mari_conversas) from public, anon, authenticated;
revoke execute on function public._porta_handoff_devolver(public.mari_conversas) from public, anon, authenticated;
revoke execute on function public._porta_fim_espera(public.mari_conversas) from public, anon, authenticated;

-- ── (5) a porta ganha os eventos do grupo (o resto igual à 0265) ──
create or replace function public.porta(p_evento text, p_conversa uuid, p_venda uuid, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
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
  if r.aceito is not true then
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes, 'frase', r.frase); end if;
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação (' || antes || ').');
  end if;
  if r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  if r.exige = 'cliente_escreveu_depois' and c.id is not null then
    select max(t.created_at) into v_opt from public.mari_turnos t
     where t.conversa_id = c.id and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%';
    if v_opt is not null and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > v_opt) then
      raise exception '%', r.frase;
    end if;
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
end $$;
revoke execute on function public.porta(text, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.porta(text, uuid, uuid, jsonb) to service_role;

-- ── (6) o robô dos prazos ──
create or replace function public._porta_prazos(p_agora timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare
  c     public.mari_conversas;
  ult   record;
  antes text;
  r     jsonb;
  n     int := 0;
  v_min int := coalesce(nullif(public._bo_cfg('esperando_fechar_min', '60'::jsonb) #>> '{}', '')::int, 60);
  v_h   numeric := coalesce(nullif(public._bo_cfg('handoff_sem_resposta_horas_uteis', '24'::jsonb) #>> '{}', '')::numeric, 24);
begin
  -- C10: o time falou por último, com uma pessoa dona, e o cliente não respondeu → fecha no Chatwoot com o dono guardado.
  -- Só com as automações do Chatwoot desligadas (a 24387 tirava o dono de toda conversa resolvida).
  if public._bo_cfg('chatwoot_automacoes', '"ligadas"'::jsonb) #>> '{}' = 'desligadas' then
    for c in
      select m.* from public.mari_conversas m
       where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
         and coalesce(m.chatwoot_status, 'open') = 'open' and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento'
         and (m.chatwoot_agente is not null or coalesce(m.humano_atribuido, false))
         and m.espera_ate is null and not coalesce(m.nao_contatar, false)
         and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
       limit 30
       for update of m skip locked
    loop
      select t.papel, t.created_at into ult from public.mari_turnos t
       where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
      if ult.papel is distinct from 'humano' or ult.created_at > p_agora - make_interval(mins => v_min) then continue; end if;
      begin
        antes := public._porta_situacao(c.id, null::uuid);
        r := public.porta('prazo:esperando_fechar', c.id, null::uuid, '{}'::jsonb);
        perform public._porta_anotar('prazo:esperando_fechar', '_porta_prazos', c.id, null::uuid, antes, r);
        n := n + 1;
      exception when others then
        insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'C10 ' || c.id::text || ': ' || sqlerrm);
      end;
    end loop;
  end if;

  -- C4: handoff para o time sem resposta em N horas úteis → a Mari volta
  for c in
    select m.* from public.mari_conversas m
     where m.status = 'handoff_realizado' and m.handoff_motivo in ('pedido_humano', 'objecao', 'urgencia_alta')
       and m.venda_id is null and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento' and m.espera_ate is null
       and (coalesce(m.time_atribuido, false) or m.chatwoot_time is not null)
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano' and t.created_at > m.handoff_em)
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
       and public._horas_uteis(m.handoff_em, p_agora) >= v_h
     limit 30
     for update of m skip locked
  loop
    begin
      antes := public._porta_situacao(c.id, null::uuid);
      r := public.porta('prazo:handoff_sem_resposta', c.id, null::uuid, '{}'::jsonb);
      perform public._porta_anotar('prazo:handoff_sem_resposta', '_porta_prazos', c.id, null::uuid, antes, r);
      n := n + 1;
    exception when others then
      insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'C4 ' || c.id::text || ': ' || sqlerrm);
    end;
  end loop;
  return n;
end $$;
revoke all on function public._porta_prazos(timestamptz) from public, anon, authenticated;

-- ── (7) C11: o cliente que escreve encerra a espera (todo turno do cliente, pela Mari ou com ela calada pelo guard) ──
create or replace function public._porta_turno_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
declare antes text; r jsonb; dentro boolean := coalesce(current_setting('porta.dentro', true), '') <> '';
begin
  if not exists (select 1 from public.mari_conversas m where m.id = new.conversa_id and m.espera_ate is not null and m.espera_ate > now()) then
    return null;
  end if;
  antes := public._porta_situacao(new.conversa_id, null::uuid);
  r := public.porta('cliente_escreveu', new.conversa_id, null::uuid, '{"acao": "fim_espera"}'::jsonb);
  if not dentro then   -- pela mari_entrada a casca já anota o evento
    perform public._porta_anotar('cliente_escreveu', '_porta_turno_cliente', new.conversa_id, null::uuid, antes, r);
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_porta_turno_cliente', new.conversa_id::text || ': ' || sqlerrm);
  return null;
end $$;
drop trigger if exists mari_turnos_cliente_porta on public.mari_turnos;
create trigger mari_turnos_cliente_porta after insert on public.mari_turnos
  for each row when (new.papel = 'lead') execute function public._porta_turno_cliente();

-- ── (8) indicacao_tick chama o robô dos prazos ──
CREATE OR REPLACE FUNCTION public.indicacao_tick(p_agora timestamp with time zone DEFAULT now())
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  g     uuid;
  cfg   jsonb := public._ind_cfg();
  p     public.pos_instalacao;
  i     public.indicacoes;
  c     public.mari_conversas;
  v     public.vendas;
  ind   public.vendas;
  v_id  bigint;
  conta text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
begin
  perform public._instaladas_fechar(p_agora);   -- 0244: roda mesmo com a indicação desligada
  perform public._saidas_fechar(p_agora);       -- 0249: Saída aberta sem ninguém com o que fazer
  perform public._porta_prazos(p_agora);        -- 0266: prazos do time pela porta (C10 fecha com dono guardado · C4 handoff sem resposta)
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return; end if;

  -- validade
  update public.pos_instalacao set estado = 'sem_resposta', encerrada_em = p_agora
   where estado = 'enviada' and enviada_em < p_agora - make_interval(days => coalesce((cfg ->> 'validade_resposta_dias')::int, 7));
  update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora
   where estado = 'pediu' and pediu_em < p_agora - make_interval(hours => coalesce((cfg ->> 'validade_pedido_horas')::int, 48));

  -- (1) mensagem de pós-instalação
  for p in select * from public.pos_instalacao where estado = 'agendada' and enviar_em <= p_agora order by enviar_em limit 20 for update skip locked loop
    select * into v from public.vendas where id = p.venda_id;
    if v.status not in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
       or v.instalado_em < p_agora - make_interval(days => coalesce((cfg ->> 'janela_instalacao_dias')::int, 3)) then
      update public.pos_instalacao set estado = 'expirada', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    select * into c from public.mari_conversas
     where id = coalesce(p.conversa_id, (select m.id from public.mari_conversas m where m.venda_id = v.id order by m.updated_at desc limit 1));
    if c.id is null or coalesce(c.canal, '') <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then
      update public.pos_instalacao set estado = 'sem_conversa', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    if coalesce(c.nao_contatar, false) then
      update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora, resposta = 'cliente pediu para não ser contatado' where id = p.id;
      continue;
    end if;
    if not public.mari_no_horario(p_agora, coalesce(v.cidade, c.cidade)) then continue; end if;
    -- 0243: instalou = o ciclo da venda fechou e o dono sai (regra do "dono da conversa", 0227). A 0226 (M4) esperava enquanto
    -- houvesse pessoa/time atribuído, mas nada tirava o time depois da instalação: a mensagem nunca saía e expirava em 3 dias
    -- (caso Ivon, 16/11). Agora só espera quem está falando de verdade (fala do time nas últimas 2 h); senão o dono sai, com nota.
    if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'
                  and t.created_at > p_agora - interval '2 hours') then continue; end if;
      g := gen_random_uuid();
      -- 0248: as etiquetas de handoff saem ANTES do time — as automações 24389/24390 do Chatwoot reatribuem o time backoffice
      -- sempre que uma conversa com handoff-venda/handoff-humano é atualizada (a resposta do cliente trazia o time de volta).
      perform public._bo_enfileirar(g, 1, 'pos_instalacao', v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(g, 4, 'pos_instalacao', v.id, c, 'nota', jsonb_build_object('content',
        '🏠 NIOGEN · cliente instalado: a venda fechou e a conversa sai do time. A mensagem de pós-instalação (App Nio + indicação) '
        || 'sai agora pela automação. Se o cliente escrever, a nota de pós-venda avisa — responda pelo NIOGEN.'));
      update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_agente = null, chatwoot_time = null
       where id = c.id;
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[cliente instalado — a conversa saiu do time (pós-instalação, 0243); a mensagem de pós-instalação foi enfileirada]', false);
      select * into c from public.mari_conversas where id = c.id;
    end if;
    v_id := public._ind_template(c, v.id, 'pos_instalacao', 'nio_pos_instalacao',
                                 jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(v.cliente_nome, c.nome_contato)), 'tudo bem')));
    if v_id is null then continue; end if;   -- template ainda não aprovado: tenta na próxima volta
    update public.pos_instalacao set estado = 'enviada', enviada_em = p_agora, conversa_id = c.id where id = p.id;
  end loop;

  -- (2) insistir uma vez com quem recebeu o pedido e ficou em silêncio (só com a janela de 24 h aberta)
  for p in select * from public.pos_instalacao
            where estado = 'pediu' and insistencias = 0
              and pediu_em <= p_agora - make_interval(mins => coalesce((cfg ->> 'insistir_apos_min')::int, 120))
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = p.conversa_id;
    if c.id is null or coalesce(c.nao_contatar, false) or c.ultima_msg_lead_at is null
       or p_agora >= c.ultima_msg_lead_at + interval '23 hours' then
      update public.pos_instalacao set insistencias = 1 where id = p.id;   -- janela fechou: não insiste por template
      continue;
    end if;
    if not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
    if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then continue; end if;   -- 0226 (M4)
    perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
    update public.pos_instalacao set insistencias = 1, insistiu_em = p_agora where id = p.id;
  end loop;

  -- (3) prêmio previsto e sem chave Pix: pede a chave a quem indicou (template)
  for i in select * from public.indicacoes where premio_status = 'previsto' and pix_chave is null and pix_pedido_em is null
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = i.indicador_conversa_id;
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if c.id is null or not public.mari_no_horario(p_agora, coalesce(ind.cidade, c.cidade)) then continue; end if;
    v_id := public._ind_template(c, i.indicador_venda_id, 'indicacao_premio', 'nio_indicacao_premio',
              jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(ind.cliente_nome, c.nome_contato)), 'tudo bem'),
                                coalesce(public._ind_primeiro_nome(coalesce(i.indicado_nome,
                                  (select vv.cliente_nome from public.vendas vv where vv.id = i.venda_id))), 'Quem você indicou')));
    if v_id is null then continue; end if;
    update public.indicacoes set pix_pedido_em = p_agora where id = i.id;
  end loop;

  -- (4) indicados a abrir no Chatwoot (a rotina cria contato + conversa e chama indicacao_abertura_resultado)
  if not coalesce((cfg ->> 'abrir_conversa')::boolean, false)
     or not exists (select 1 from public.config_templates_waba where nome = 'nio_indicacao_contato' and status = 'APPROVED') then
    return;
  end if;
  for i in select * from public.indicacoes x
            where x.estado = 'recebida' and x.tentativas < 3
              and (x.tentativa_em is null or x.tentativa_em < p_agora - interval '30 minutes')
            order by x.criado_em limit 10 for update skip locked loop
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if not public.mari_no_horario(p_agora, ind.cidade) then continue; end if;
    update public.indicacoes set tentativas = tentativas + 1, tentativa_em = p_agora where id = i.id;
    return next jsonb_build_object(
      'id', i.id,
      -- 0178: sem nome, o contato nasce com o telefone (como todo contato novo do WhatsApp) — a Mari não chama ninguém de "Indicação"
      'nome', coalesce(i.indicado_nome, '+' || i.indicado_telefone),
      'telefone', '+' || i.indicado_telefone,
      'inbox_id', coalesce((cfg ->> 'inbox_id')::int, 153431),
      'base', 'https://app.chatwoot.com/api/v1/accounts/' || conta);
  end loop;
  return;
end $function$;

-- ── (9) C3 na mari_handoff ──
CREATE OR REPLACE FUNCTION public.mari_handoff__nucleo(p_conversa uuid, p_motivo text, p_lead jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  l        jsonb := coalesce(p_lead, '{}'::jsonb);
  d        jsonb;
  v_plano  public.config_planos;
  v_venda  uuid;
  v_motivo text;
  v_seg    text;
  v_forma  text;
  v_orig   text;
  v_cpf    text;
  v_tel    text;
  v_cluster text;
  v_dfv    jsonb;
  v_brief  text;
  v_obs    text;
  v_inst   text;
  v_viab   text;
  v_vnota  text;
  v_prox   text;
  v_endp   text;
  v_exist  uuid;   -- 0030: venda que já existe (duplicidade) — o link vai na nota do Chatwoot
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'motivo_recusa', 'conversa inexistente'); end if;

  -- Guard-rail 10: não repetir handoff.
  if c.status <> 'ativo' then
    return jsonb_build_object('ok', true, 'repetido', true, 'venda_id', c.venda_id);
  end if;

  -- 0266 (C3, Ricardo 17/11): "interesse caindo" e "múltiplos decisores" não passam para o time — a conversa fica com a Mari
  -- (status ativo; a Mari segue respondendo). O 🔥 na Live fica para o debate da Live.
  if p_motivo in ('interesse_caindo', 'multiplos_decisores') then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[a Mari sinalizou ' || case p_motivo when 'interesse_caindo' then 'interesse caindo' else 'múltiplos decisores' end
            || ' — a conversa fica com ela (C3)]', false);
    return jsonb_build_object('ok', true, 'fica_com_mari', true, 'venda_id', c.venda_id);
  end if;

  d := c.dados || coalesce(l -> 'dados', '{}'::jsonb);
  v_inst := coalesce(nullif(btrim(c.instalacao_preferencia), ''), nullif(btrim(l ->> 'instalacao_preferencia'), ''));
  v_viab := coalesce(c.nio_viab_resultado, nullif(l ->> 'nio_viab_resultado', ''));
  if v_viab not in ('viavel', 'sem_viabilidade', 'nao_encontrado', 'posse', 'indisponivel') then v_viab := null; end if;
  v_endp := coalesce(nullif(btrim(c.nio_viab_endereco_portal), ''), nullif(btrim(l ->> 'nio_viab_endereco_portal'), ''));

  -- Nota da viabilidade oficial (nunca nega venda): viável = atendido; o resto = conferir à mão antes do pedido.
  v_vnota := case
    when v_viab = 'viavel' then 'portal: viável' || coalesce(' · até ' || coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'), '')
    when v_viab = 'posse' then 'portal: posse (endereço com Nio ativo) — cliente disse que não tem; conferir manualmente antes de abrir o pedido'
    when v_viab is not null then 'portal: ' || v_viab || ' — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido'
    else 'portal: não consultado — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido' end
    || coalesce(' · endereço como a Nio cadastrou: ' || v_endp, '');

  -- Próximo passo do humano (venda remota, 05/11; 0032: o link da biometria é da Nio): sempre o mesmo texto.
  v_prox := case when p_motivo = 'dados_completos' then
    'Próximo passo: abrir pedido no portal PAP'
    || case when coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') is not null
            then ' (interesse ' || coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') || ' já criado na viabilidade)' else '' end
    || ' e registrar o nº do pedido no NIOGEN → a Nio dispara o link da biometria (WhatsApp + e-mail) → avisar o cliente nesta conversa → agendar a instalação ('
    || coalesce(v_inst, 'preferência não informada') || ').' end;

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    handoff_briefing = concat_ws(E'\n', coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing),
                                 case when p_motivo = 'dados_completos' or v_viab is not null then v_vnota end, v_prox),
    dados = d, processando_ate = null,
    instalacao_preferencia = coalesce(v_inst, instalacao_preferencia),
    -- 0189: recusa não é pedido de parar — o "não contatar" fica só para quem pediu (SAIR, PARAR, botão do time)
    agendamento_retorno = coalesce((l ->> 'agendamento_retorno')::timestamptz, agendamento_retorno)
  where id = p_conversa
  returning * into c;

  if p_motivo <> 'dados_completos' then
    return jsonb_build_object('ok', true, 'venda_id', null);
  end if;

  -- Pré-condições da venda (ordem: elegibilidade, área, plano, dados mínimos, duplicidade). Viabilidade NÃO entra.
  v_cluster := public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> 'bairro');
  v_cpf := regexp_replace(coalesce(d ->> 'cpf', ''), '\D', '', 'g');
  v_tel := regexp_replace(coalesce(d ->> 'telefone', c.telefone), '\D', '', 'g');
  select * into v_plano from public.config_planos where codigo = c.plano_escolhido;

  -- 0030: a mesma regra de duplicidade de sempre, agora guardando QUAL venda já existe (a mais recente).
  select v.id into v_exist from public.vendas v
   where v.status <> 'saida'
     and ((v_cpf <> '' and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = v_cpf)
       or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = c.cep
           and lower(btrim(coalesce(v.numero, ''))) = lower(btrim(c.numero))
           and lower(btrim(coalesce(v.complemento, ''))) = lower(btrim(coalesce(c.complemento, '')))))
   order by v.criado_em desc
   limit 1;

  v_motivo := case
    when coalesce(c.elegibilidade, '') <> 'ok' then 'elegibilidade não confirmada (' || coalesce(c.elegibilidade, 'vazia') || ')'
    when v_cluster is null then 'fora da área de atuação (' || coalesce(c.cidade, 'cidade desconhecida') || ')'
    when v_plano.id is null then 'plano não escolhido'
    when coalesce(btrim(d ->> 'nome'), '') = '' then 'nome do cliente ausente'
    when c.cep is null or c.numero is null then 'endereço incompleto'
    when v_exist is not null
      then 'duplicidade: CPF ou endereço já tem venda ativa no NIOGEN'
  end;

  if v_motivo is null then
    v_seg := case when c.segmento = 'empresas' then case when c.mei then 'MEI' else 'NMEI' end else 'PF' end;
    v_forma := coalesce(c.forma_pagamento, l ->> 'forma_pagamento');
    v_forma := case v_forma when 'debito' then 'dacc' when 'debito_automatico' then 'dacc' else v_forma end;
    if v_forma not in ('boleto', 'cartao', 'dacc') then v_forma := null; end if;
    v_orig := case when c.origem in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao') then c.origem else 'outro' end;
    v_dfv := c.dfv_detalhe;

    v_brief := coalesce(l ->> 'briefing', '');
    v_obs := concat_ws(E'\n',
      'Mari (' || c.canal || ') — handoff dados_completos em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
      'Plano: ' || v_plano.nome || ' · forma: ' || coalesce(v_forma, '?'),
      'Instalação: preferência ' || coalesce(v_inst, '?') || ' (data o nosso time confirma)',
      'Viabilidade Nio — ' || v_vnota,
      'DFV: ' || case coalesce(c.dfv_resultado, '')
                   when 'viavel' then 'viável'
                   when 'viavel_predio' then 'viável (prédio) — conferir unidade'
                   when 'endereco_ocupado' then 'indica Nio ativo no endereço — confirmar com o cliente e no portal antes de abrir o pedido'
                   else 'conferir manualmente antes de abrir o pedido' end,
      nullif(v_brief, ''),
      v_prox);

    begin
      insert into public.vendas (
        status, origem, origem_ref, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
        cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento,
        trava_area, trava_cpf_valido, trava_contato_confirmado, observacoes,
        dfv_viabilidade, dfv_resultado, dfv_hp_livre, dfv_hcs, dfv_faixa_credito, dfv_classificacao,
        dfv_particao, dfv_origem, dfv_consultado_em,
        instalacao_preferencia, biometria_status,
        nio_viab_resultado, nio_viab_velocidade, nio_viab_interesse_id, nio_viab_em, nio_viab_origem, nio_viab_endereco_portal)
      values (
        '0_qualificado', v_orig, 'mari:' || c.id, btrim(d ->> 'nome'), nullif(v_cpf, ''), v_tel, nullif(btrim(d ->> 'email'), ''), v_seg,
        c.cep, c.endereco_cep ->> 'logradouro', c.numero, c.complemento,
        coalesce(c.endereco_cep ->> 'bairro', v_dfv ->> 'bairro'), c.cidade, c.uf, v_plano.id, v_forma,
        true, case when v_cpf <> '' then public.mari_cpf_valido(v_cpf) end,
        case when coalesce((d ->> 'telefone_confirmado')::boolean, false) or v_tel <> '' then true end, v_obs,
        case c.dfv_resultado
          when 'viavel' then 'viavel' when 'viavel_predio' then 'viavel_predio'
          when 'endereco_ocupado' then 'sem_viabilidade' when 'sem_porta_livre' then 'sem_viabilidade'
          when 'nao_encontrado' then 'nao_encontrado'
          else 'nao_consultado' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then c.dfv_resultado end,
        (v_dfv ->> 'hp_livre')::int, (v_dfv ->> 'hc_tot')::int,
        public.dfv_faixa_codigo(v_dfv ->> 'faixa_credito'),
        case when v_dfv ->> 'classificacao' in ('ALTO', 'MEDIO', 'BAIXO') then v_dfv ->> 'classificacao' end,
        (v_dfv ->> 'particao')::date,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then 'auto' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then now() end,
        v_inst, 'nao_enviada',
        v_viab, coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'),
        coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id'),
        case when v_viab is not null then coalesce(c.nio_viab_em, now()) end,
        case when v_viab is not null then 'mari' end,
        v_endp)
      returning id into v_venda;

      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v_venda, 'mari_handoff', jsonb_strip_nulls(jsonb_build_object(
        'conversa_id', c.id, 'motivo', p_motivo, 'canal', c.canal, 'briefing', nullif(v_brief, ''),
        'instalacao_preferencia', v_inst, 'nio_viab_resultado', v_viab, 'dfv_resultado', c.dfv_resultado)));

      update public.mari_conversas set venda_id = v_venda where id = p_conversa;
    exception when others then
      v_motivo := sqlerrm;
    end;
  end if;

  if v_motivo is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_handoff', 'venda não criada: ' || v_motivo,
            jsonb_strip_nulls(jsonb_build_object('lead', l, 'dados', d, 'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end)));
    return jsonb_build_object('ok', false, 'venda_id', null, 'motivo_recusa', v_motivo,
                              'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end);
  end if;

  return jsonb_build_object('ok', true, 'venda_id', v_venda);
end;
$function$;

-- ── (10) H3 na mari_encerrar_ciclo ──
CREATE OR REPLACE FUNCTION public.mari_encerrar_ciclo(p_chatwoot_conversation_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
  u    public.mari_conversas;
begin
  if coalesce(btrim(p_chatwoot_conversation_id), '') = '' then
    return jsonb_build_object('ok', false, 'erro', 'conversa do Chatwoot vazia');
  end if;
  -- 0147: trava "não se atende pelo Chatwoot"
  select * into u from public.mari_conversas
   where canal = 'whatsapp' and chatwoot_conversation_id = btrim(p_chatwoot_conversation_id)
   order by updated_at desc limit 1;
  if found and coalesce(u.funil_destino, 'em_andamento') = 'em_andamento'
     and not exists (select 1 from public.chatwoot_acoes a
                      where a.chatwoot_conversation_id = btrim(p_chatwoot_conversation_id) and a.tipo = 'resolver'
                        and a.criada_em > now() - interval '30 minutes') then
    update public.mari_conversas set funil_alerta = 'resolvida_fora_niogen', funil_alerta_em = now() where id = u.id;
    insert into public.funil_eventos (conversa_id, tipo, para, detalhe)
    values (u.id, 'alerta', 'resolvida_fora_niogen', 'resolvida direto no Chatwoot sem destino');
    -- 0266 (H3): com a Mari atendendo (sem dono, sem handoff, sem espera), o NIOGEN desfaz na hora — o Chatwoot é só tela
    if u.status = 'ativo' and u.chatwoot_agente is null and u.chatwoot_time is null and not coalesce(u.humano_atribuido, false)
       and not coalesce(u.time_atribuido, false) and u.espera_ate is null then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (u.id, 'sistema', '[resolvida direto no Chatwoot com a Mari atendendo — o NIOGEN reabriu (H3)]', false);
      perform public._porta_projetar(u.id, 'fora_niogen',
        '↩ Resolvida direto no Chatwoot com a Mari atendendo — o NIOGEN reabriu (o Chatwoot é só tela). Para encerrar, use Saída no NIOGEN.', 'open');
    end if;
  end if;

  select id into v_id from public.mari_conversas
   where canal = 'whatsapp' and chatwoot_conversation_id = btrim(p_chatwoot_conversation_id)
     and status = 'handoff_realizado'
   order by updated_at desc limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'fechado', false, 'motivo', 'nenhuma conversa da Mari em handoff com esse id');
  end if;
  return public._mari_fechar_ciclo(v_id, 'conversa resolvida no Chatwoot');
end;
$function$;

commit;
