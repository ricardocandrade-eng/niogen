-- NIOGEN | supabase/migrations/0293_situacao_gravada.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "depois siga para o passo 2" (fase 2 do diagnóstico de fechamento, docs/DIAGNOSTICO_fechamento_porta_181126_1503.md §6).
-- Regra A ("um estado só, gravado"): até aqui a situação do lead era só CALCULADA a cada leitura (v_lead_situacao, em cima dos campos
-- antigos). Agora ela é GRAVADA, em sombra:
--  (1) lead_estado: uma linha por lead (mesmo lead_id da v_leads) com situação, vez e prazo. Só a porta escreve: todo evento da porta
--      — executado pela porta() ou anotado pelas cascas e gatilhos zz_porta — passa por porta_sombra; um gatilho de restrição ADIADO
--      (fim da transação) grava a situação daquele lead como ela ficou. Ninguém mais grava (RLS: só leitura para o logado).
--  (2) v_lead_estado_divergencias: lead cuja situação calculada é diferente da gravada = algo mudou SEM evento da porta (handoff da Mari
--      para o time, espera vencida, cliente escreveu sem evento, robô…). É a lista do que falta passar pela porta.
--  (3) ponto de partida: todo lead com a situação de agora (evento 'inicio').
-- Nada muda para o time: as telas seguem lendo a v_lead_situacao. Quando a lista ficar vazia por alguns dias, as telas passam a ler
-- a gravada (passo seguinte).
-- Regra 20: (1) todo lead tem situação, vez e prazo — agora gravados; (2) sem estado novo; (3) quem grava é a porta, com o evento;
-- (4) fonte única: a situação; (5) conferência: a v_lead_estado_divergencias + a regra R14 do portão (aviso). O item no Conferir do
-- Painel/Live fica para depois do debate da Live (regra 20: Live não muda sem debate). Cenário X29. Tela e guia: sem impacto.
-- Desempenho: o gatilho lê a v_lead_situacao de 1 lead por evento, no fim da transação (medido na cópia: ver Diário).
begin;

-- ───────────────────────── 1. a situação gravada ─────────────────────────
create table if not exists public.lead_estado (
  lead_id     text primary key,                 -- o mesmo lead_id da v_leads (texto): a conversa, ou a venda quando não há conversa
  parceiro_id text not null default 'dharma',
  conversa_id uuid,
  venda_id    uuid,
  situacao    text not null,                    -- config_situacao.codigo
  vez         text,
  prazo_em    timestamptz,
  evento      text,                             -- o evento da porta que gravou (porta_sombra.evento)
  origem      text,
  em          timestamptz not null default now()
);
create index if not exists lead_estado_conversa on public.lead_estado (conversa_id);
create index if not exists lead_estado_venda    on public.lead_estado (venda_id);
comment on table public.lead_estado is
  '0293 (fase 2, passo 2): a situação de cada lead GRAVADA a cada evento da porta (no fim da transação). Só a porta escreve. '
  'v_lead_estado_divergencias = o que mudou sem passar pela porta.';

alter table public.lead_estado enable row level security;
drop policy if exists lead_estado_ler on public.lead_estado;
create policy lead_estado_ler on public.lead_estado for select to authenticated using (true);
revoke all on public.lead_estado from anon, authenticated;
grant select on public.lead_estado to authenticated;

-- grava a situação de um lead como ela está agora (lida da v_lead_situacao, a mesma conta de sempre)
create or replace function public._lead_estado_gravar(p_conversa uuid, p_venda uuid, p_evento text, p_origem text)
returns void language plpgsql security definer set search_path = public as $$
declare l record;
begin
  if p_conversa is null and p_venda is null then return; end if;
  select ls.lead_id, ls.conversa_id, ls.venda_id, ls.situacao, ls.vez, ls.prazo_em into l
    from public.v_lead_situacao ls
   where (p_conversa is not null and ls.conversa_id = p_conversa) or (p_venda is not null and ls.venda_id = p_venda)
   order by (ls.conversa_id is not null) desc
   limit 1;
  if l.lead_id is null or l.situacao is null then return; end if;
  -- a venda que ganhou conversa muda de lead_id: a linha antiga sai
  delete from public.lead_estado e
   where e.lead_id <> l.lead_id
     and ((l.conversa_id is not null and e.conversa_id = l.conversa_id) or (l.venda_id is not null and e.venda_id = l.venda_id));
  insert into public.lead_estado as e (lead_id, conversa_id, venda_id, situacao, vez, prazo_em, evento, origem, em)
  values (l.lead_id, l.conversa_id, l.venda_id, l.situacao, l.vez, l.prazo_em, p_evento, p_origem, now())
  on conflict (lead_id) do update
     set conversa_id = excluded.conversa_id, venda_id = excluded.venda_id, situacao = excluded.situacao,
         vez = excluded.vez, prazo_em = excluded.prazo_em, evento = excluded.evento, origem = excluded.origem, em = excluded.em;
exception when others then
  null;   -- gravar a situação nunca derruba o evento
end $$;

-- todo evento da porta (executado ou anotado) passa por porta_sombra: no FIM da transação, grava a situação daquele lead
create or replace function public._porta_sombra_estado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._lead_estado_gravar(new.conversa_id, new.venda_id, new.evento, new.origem);
  return null;
end $$;

drop trigger if exists porta_sombra_estado on public.porta_sombra;
create constraint trigger porta_sombra_estado after insert on public.porta_sombra
  deferrable initially deferred for each row execute function public._porta_sombra_estado();

-- ───────────────────────── 2. o que mudou sem passar pela porta ─────────────────────────
create or replace view public.v_lead_estado_divergencias with (security_invoker = true) as
select l.lead_id, l.conversa_id, l.venda_id, l.nome,
       e.situacao as gravada, l.situacao as calculada,
       e.evento   as ultimo_evento, e.em as gravada_em
  from public.v_lead_situacao l
  left join public.lead_estado e on e.lead_id = l.lead_id
 where e.lead_id is null or e.situacao is distinct from l.situacao;
grant select on public.v_lead_estado_divergencias to authenticated;

-- ───────────────────────── 3. ponto de partida: todo lead com a situação de agora ─────────────────────────
insert into public.lead_estado (lead_id, conversa_id, venda_id, situacao, vez, prazo_em, evento, origem, em)
select ls.lead_id, ls.conversa_id, ls.venda_id, ls.situacao, ls.vez, ls.prazo_em, 'inicio', '0293', now()
  from public.v_lead_situacao ls
 where ls.lead_id is not null and ls.situacao is not null
on conflict (lead_id) do nothing;

commit;
