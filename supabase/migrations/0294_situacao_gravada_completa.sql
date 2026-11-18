-- NIOGEN | supabase/migrations/0294_situacao_gravada_completa.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "Sim, siga" — fechar os 6 caminhos que mudavam a situação do lead sem evento da porta (R14 do portão com a 0293):
-- B5 (robô do portal: viável só pelos 200 m), C6 (atribuir-se no Chatwoot, pelo espelho), E4 (pendência da Nio na venda),
-- X23 e X26 (porta() chamada direto, sem a casca que anota — "Sou cliente Nio" da abertura, silenciar sem motivo) e B8 (a espera
-- que vence só com o tempo). Três tipos, três marcas, uma fila:
--  (1) lead_estado_mudancas: o HISTÓRICO de toda troca de situação — de → para, evento, a função que rodou e quem (auth.uid()).
--  (2) lead_estado_fila + gatilho de restrição ADIADO: tudo que pode mudar um lead marca a fila; no fim da transação a situação é
--      gravada uma vez, com o melhor rótulo (evento da porta vence "dado:*"; entre iguais, o último). Só grava se mudou.
--  (3) quem marca: (a) a sombra da porta (como na 0293); (b) gatilho em mari_conversas nos campos que a situação lê — pela porta
--      "porta:<função>", por fora "dado:<dono|viabilidade|espera|handoff|crédito|chatwoot_status|conversa>"; (c) gatilho em vendas —
--      "porta:<função>" ou "dado:<venda_status|pendencia_nio|biometria|venda>"; (d) o tempo: _porta_prazos (10 min) chama
--      _lead_estado_tick, que grava o que divergiu ("prazo:espera_venceu", "prazo:tempo").
-- Com isso a situação gravada fica igual à calculada (R14 vira verde em B5, B8, C6, E4, X23, X26) e o "por fora da porta" deixa de
-- ser uma diferença escondida: vira linha no histórico com evento "dado:*" e a função que gravou — a lista do que falta passar pela porta.
-- Nada muda para o time (as telas seguem na v_lead_situacao). Recriada a partir da versão no ar: _porta_prazos (md5 5fe07331… = produção).
-- Regra 20: (1) situação, vez e prazo gravados para todo lead; (2) sem estado novo; (3) toda troca de situação tem evento, função e autor
-- no histórico; (4) sem fonte nova; (5) conferência: R14 do portão + v_lead_estado_divergencias (o item do Conferir espera o debate
-- da Live). Desempenho: 1 leitura da v_lead_situacao por lead por transação que mexe nele (~4 ms + plano). Guia: sem impacto.
begin;

-- ───────────────────────── 1. o histórico: toda troca de situação, com o evento e quem ─────────────────────────
create table if not exists public.lead_estado_mudancas (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  lead_id     text not null,
  conversa_id uuid,
  venda_id    uuid,
  de          text,                 -- situação gravada antes (nulo = 1ª gravação)
  para        text not null,
  evento      text,                 -- evento da porta, ou o que mudou por fora (dado:*, prazo:*)
  origem      text,                 -- a função que rodou (_porta_quem_rodou) ou a peça
  por         uuid,                 -- auth.uid() de quem fez (nulo = robô / sistema)
  em          timestamptz not null default now()
);
create index if not exists lead_estado_mudancas_lead on public.lead_estado_mudancas (lead_id, em desc);
create index if not exists lead_estado_mudancas_em   on public.lead_estado_mudancas (em desc);
alter table public.lead_estado_mudancas enable row level security;
drop policy if exists lead_estado_mudancas_ler on public.lead_estado_mudancas;
create policy lead_estado_mudancas_ler on public.lead_estado_mudancas for select to authenticated using (true);
revoke all on public.lead_estado_mudancas from anon, authenticated;
grant select on public.lead_estado_mudancas to authenticated;

-- ───────────────────────── 2. a fila do fim da transação ─────────────────────────
-- Tudo que pode mudar a situação de um lead marca o lead aqui; no FIM da transação um gatilho adiado grava a situação uma vez,
-- com o melhor rótulo: evento da porta vence "dado:*" (mudança feita por fora), e entre iguais vence o último.
create table if not exists public.lead_estado_fila (
  id          bigserial primary key,
  conversa_id uuid,
  venda_id    uuid,
  evento      text not null,
  origem      text
);
alter table public.lead_estado_fila enable row level security;
revoke all on public.lead_estado_fila from anon, authenticated;

create or replace function public._lead_estado_marcar(p_conversa uuid, p_venda uuid, p_evento text, p_origem text)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid := p_conversa;
begin
  if c is null and p_venda is not null then
    select m.id into c from public.mari_conversas m where m.venda_id = p_venda and m.canal = 'whatsapp' order by m.created_at desc limit 1;
  end if;
  if c is null and p_venda is null then return; end if;
  insert into public.lead_estado_fila (conversa_id, venda_id, evento, origem) values (c, p_venda, coalesce(p_evento, 'dado'), p_origem);
exception when others then
  null;   -- marcar nunca derruba a gravação
end $$;

-- grava (substitui a da 0293): só escreve quando a situação, a vez ou o prazo mudaram; troca de situação vai para o histórico
create or replace function public._lead_estado_gravar(p_conversa uuid, p_venda uuid, p_evento text, p_origem text)
returns void language plpgsql security definer set search_path = public as $$
declare l record; e public.lead_estado;
begin
  if p_conversa is null and p_venda is null then return; end if;
  select ls.lead_id, ls.conversa_id, ls.venda_id, ls.situacao, ls.vez, ls.prazo_em into l
    from public.v_lead_situacao ls
   where (p_conversa is not null and ls.conversa_id = p_conversa) or (p_venda is not null and ls.venda_id = p_venda)
   order by (ls.conversa_id is not null) desc
   limit 1;
  if l.lead_id is null or l.situacao is null then return; end if;
  -- a venda que ganhou conversa muda de lead_id: a linha antiga sai (e o histórico segue pela linha nova)
  select * into e from public.lead_estado x
   where x.lead_id <> l.lead_id
     and ((l.conversa_id is not null and x.conversa_id = l.conversa_id) or (l.venda_id is not null and x.venda_id = l.venda_id))
   limit 1;
  if found then
    delete from public.lead_estado x where x.lead_id = e.lead_id;
  end if;
  select * into e from public.lead_estado x where x.lead_id = l.lead_id;
  if found and e.situacao is not distinct from l.situacao and e.vez is not distinct from l.vez
     and e.prazo_em is not distinct from l.prazo_em then
    return;   -- nada mudou
  end if;
  if not found or e.situacao is distinct from l.situacao then
    insert into public.lead_estado_mudancas (lead_id, conversa_id, venda_id, de, para, evento, origem, por)
    values (l.lead_id, l.conversa_id, l.venda_id, e.situacao, l.situacao, p_evento, p_origem, auth.uid());
  end if;
  insert into public.lead_estado as x (lead_id, conversa_id, venda_id, situacao, vez, prazo_em, evento, origem, em)
  values (l.lead_id, l.conversa_id, l.venda_id, l.situacao, l.vez, l.prazo_em, p_evento, p_origem, now())
  on conflict (lead_id) do update
     set conversa_id = excluded.conversa_id, venda_id = excluded.venda_id, situacao = excluded.situacao, vez = excluded.vez,
         prazo_em = excluded.prazo_em,
         -- vez/prazo mudaram e a situação não: o evento e a hora continuam os da última troca de situação
         evento = case when x.situacao is distinct from excluded.situacao then excluded.evento else x.evento end,
         origem = case when x.situacao is distinct from excluded.situacao then excluded.origem else x.origem end,
         em     = case when x.situacao is distinct from excluded.situacao then excluded.em else x.em end;
exception when others then
  null;   -- gravar a situação nunca derruba o evento
end $$;

create or replace function public._lead_estado_fila_rodar()
returns trigger language plpgsql security definer set search_path = public as $$
declare melhor boolean := new.evento not like 'dado:%';
begin
  -- outra marca do mesmo lead nesta transação com rótulo melhor (evento da porta > dado; entre iguais, a última)? ela grava.
  if not exists (
       select 1 from public.lead_estado_fila f
        where f.id <> new.id
          and (f.conversa_id = new.conversa_id or (new.venda_id is not null and f.venda_id = new.venda_id))
          and ((f.evento not like 'dado:%') > melhor or ((f.evento not like 'dado:%') = melhor and f.id > new.id))) then
    perform public._lead_estado_gravar(new.conversa_id, new.venda_id, new.evento, new.origem);
  end if;
  delete from public.lead_estado_fila where id = new.id;
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists lead_estado_fila_rodar on public.lead_estado_fila;
create constraint trigger lead_estado_fila_rodar after insert on public.lead_estado_fila
  deferrable initially deferred for each row execute function public._lead_estado_fila_rodar();

-- ───────────────────────── 3. quem marca ─────────────────────────
-- (a) todo evento da porta anotado na sombra (como na 0293, agora pela fila)
create or replace function public._porta_sombra_estado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._lead_estado_marcar(new.conversa_id, new.venda_id, new.evento, new.origem);
  return null;
end $$;
drop trigger if exists porta_sombra_estado on public.porta_sombra;
create trigger porta_sombra_estado after insert on public.porta_sombra
  for each row execute function public._porta_sombra_estado();

-- (b) a conversa mudou num campo que a situação lê. Pela porta (porta.aplicando) = "porta:<quem rodou>"; senão "dado:<o quê>",
--     que é a lista do que ainda muda o lead por fora da porta (C6 espelho do Chatwoot, B5 robô do portal…).
create or replace function public._lead_estado_conversa()
returns trigger language plpgsql security definer set search_path = public as $$
declare ev text;
begin
  if (old.status, old.funil_destino, old.saida_motivo, old.espera_ate, old.humano_atribuido, old.time_atribuido, old.chatwoot_agente,
      old.chatwoot_time, old.venda_id, old.cobertura_decisao, old.nio_viab_resultado, old.handoff_em, old.handoff_motivo,
      old.nao_contatar, old.chatwoot_status, old.credito_resultado)
     is not distinct from
     (new.status, new.funil_destino, new.saida_motivo, new.espera_ate, new.humano_atribuido, new.time_atribuido, new.chatwoot_agente,
      new.chatwoot_time, new.venda_id, new.cobertura_decisao, new.nio_viab_resultado, new.handoff_em, new.handoff_motivo,
      new.nao_contatar, new.chatwoot_status, new.credito_resultado) then
    return null;
  end if;
  ev := case
    when coalesce(current_setting('porta.aplicando', true), '') = '1' then 'porta:' || public._porta_quem_rodou()
    when (old.humano_atribuido, old.time_atribuido, old.chatwoot_agente, old.chatwoot_time)
         is distinct from (new.humano_atribuido, new.time_atribuido, new.chatwoot_agente, new.chatwoot_time) then 'dado:dono'
    when old.chatwoot_status is distinct from new.chatwoot_status then 'dado:chatwoot_status'
    when (old.cobertura_decisao, old.nio_viab_resultado) is distinct from (new.cobertura_decisao, new.nio_viab_resultado) then 'dado:viabilidade'
    when old.espera_ate is distinct from new.espera_ate then 'dado:espera'
    when (old.handoff_em, old.handoff_motivo) is distinct from (new.handoff_em, new.handoff_motivo) then 'dado:handoff'
    when old.credito_resultado is distinct from new.credito_resultado then 'dado:credito'
    else 'dado:conversa' end;
  perform public._lead_estado_marcar(new.id, new.venda_id, ev, public._porta_quem_rodou());
  return null;
exception when others then
  return null;
end $$;
drop trigger if exists mari_conversas_zzz_lead_estado on public.mari_conversas;
create trigger mari_conversas_zzz_lead_estado after update on public.mari_conversas
  for each row execute function public._lead_estado_conversa();

-- (c) a venda mudou (robôs da Nio, ficha, extensão): "porta:<quem>" ou "dado:<o quê>" (E4 pendência da Nio…)
create or replace function public._lead_estado_venda()
returns trigger language plpgsql security definer set search_path = public as $$
declare ev text;
begin
  if (to_jsonb(old) - 'updated_at') = (to_jsonb(new) - 'updated_at') then return null; end if;
  ev := case
    when coalesce(current_setting('porta.aplicando', true), '') = '1' then 'porta:' || public._porta_quem_rodou()
    when old.status is distinct from new.status then 'dado:venda_status'
    when to_jsonb(old) ->> 'nio_pendencia_cod' is distinct from to_jsonb(new) ->> 'nio_pendencia_cod' then 'dado:pendencia_nio'
    when old.biometria_status is distinct from new.biometria_status then 'dado:biometria'
    else 'dado:venda' end;
  perform public._lead_estado_marcar(null::uuid, new.id, ev, public._porta_quem_rodou());
  return null;
exception when others then
  return null;
end $$;
drop trigger if exists vendas_zzz_lead_estado on public.vendas;
create trigger vendas_zzz_lead_estado after update on public.vendas
  for each row execute function public._lead_estado_venda();

-- (d) o tempo: a espera que vence (B8) e o que mais mudar sem ninguém gravar nada. Roda na volta de 10 min (_porta_prazos).
create or replace function public._lead_estado_tick(p_agora timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare d record; n int := 0;
begin
  for d in select * from public.v_lead_estado_divergencias limit 100 loop
    perform public._lead_estado_marcar(d.conversa_id, d.venda_id,
      case when d.gravada = 'em_espera' then 'prazo:espera_venceu' when d.gravada is null then 'prazo:sem_gravacao' else 'prazo:tempo' end,
      '_porta_prazos');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ───────────────────────── 4. a volta de 10 min chama o relógio da situação ─────────────────────────
CREATE OR REPLACE FUNCTION public._porta_prazos(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- 0274: a Retomada (começa quando o cliente some do time; manda D3/D7/D15 pela fila do NIOGEN)
  begin
    n := n + public._retomada_tick(p_agora);
  exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_retomada_tick', sqlerrm);
  end;
  -- 0294: a situação gravada acompanha o que muda só com o tempo (espera que vence…) — fora da conta de n
  begin
    perform public._lead_estado_tick(p_agora);
  exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_lead_estado_tick', sqlerrm);
  end;
  return n;
end $function$;



-- ponto de partida: grava o que tiver divergido desde a 0293
select public._lead_estado_tick(now());

commit;
