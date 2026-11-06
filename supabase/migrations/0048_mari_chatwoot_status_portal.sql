-- NIOGEN | supabase/migrations/0048_mari_chatwoot_status_portal.sql | 06/11/2026 — Claude Code (prompt 27, blocos B e C)
-- Resumo: o que a 1ª venda real (conversa #4, Edson) mostrou do lado do NIOGEN.
--   1. mari_conversas ganha o status do Chatwoot (A resolver / Resolvida), quem está atribuído (agente e time) e as
--      etiquetas, gravados SÓ pela função service-role mari_chatwoot_sync (n8n e a carga única do scripts/).
--   2. v_mari_aguardando_humano: conversas com handoff-venda/handoff-humano, A resolver no Chatwoot e cuja última
--      mensagem é do cliente (sem resposta do time) — o contador "Mari · IA" do menu lateral.
--   3. usuario_vistos: "visto em" por usuário e tela (o contador "Vendas" conta as novas desde a última visita) — no banco,
--      não no navegador.
--   4. vendas.nio_viab_por: quem registrou a viabilidade do portal (a ficha mostra "data e quem registrou") e
--      vendas.ponto_referencia (o portal exige na etapa 2; bloco "Dados para o portal PAP").
--   5. Trava 0 → 1 (vendas_antes_status): passa a exigir a viabilidade do PORTAL = Viável (< 7 dias). O DFV deixa de
--      bastar e a dispensa do DFV deixa de liberar a venda (decisão do Ricardo 06/11 19h10: quem decide é o portal).
--      vendas_antes_cobertura/vendas_antes_dfv seguem iguais: o DFV continua sendo consultado, só que como pista.
-- Numeração: 0045 fica com o prompt 23 (API de Conversões) e 0047 com o prompt 26 (carrossel), ainda não rodados.

-- ---------------------------------------------------------------- 1. status do Chatwoot na conversa da Mari
alter table public.mari_conversas
  add column if not exists chatwoot_status    text,
  add column if not exists chatwoot_agente    text,
  add column if not exists chatwoot_time      text,
  add column if not exists chatwoot_etiquetas text[] not null default '{}',
  add column if not exists chatwoot_sync_em   timestamptz;

alter table public.mari_conversas drop constraint if exists mari_conversas_chatwoot_status_check;
alter table public.mari_conversas add constraint mari_conversas_chatwoot_status_check
  check (chatwoot_status is null or chatwoot_status in ('open', 'pending', 'resolved', 'snoozed'));

comment on column public.mari_conversas.chatwoot_status is
  'Status da conversa no Chatwoot (open/pending = A resolver · resolved = Resolvida · snoozed = adiada). Só mari_chatwoot_sync grava.';
comment on column public.mari_conversas.chatwoot_agente is 'Agente atribuído no Chatwoot (nome), null = ninguém.';
comment on column public.mari_conversas.chatwoot_time is 'Time atribuído no Chatwoot (nome), null = nenhum.';
comment on column public.mari_conversas.chatwoot_etiquetas is 'Etiquetas da conversa no Chatwoot (handoff, handoff-venda, handoff-humano…).';
comment on column public.mari_conversas.chatwoot_sync_em is 'Quando o status do Chatwoot foi lido pela última vez.';

-- Só toca nos campos do Chatwoot; o resto da conversa (motor da Mari) não muda.
create or replace function public.mari_chatwoot_sync(
  p_chatwoot_conversation_id text,
  p_status    text,
  p_agente    text,
  p_time      text,
  p_etiquetas text[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if coalesce(btrim(p_chatwoot_conversation_id), '') = '' then
    return 0;
  end if;
  update public.mari_conversas
     set chatwoot_status    = case when p_status in ('open', 'pending', 'resolved', 'snoozed') then p_status else chatwoot_status end,
         chatwoot_agente    = nullif(btrim(coalesce(p_agente, '')), ''),
         chatwoot_time      = nullif(btrim(coalesce(p_time, '')), ''),
         chatwoot_etiquetas = coalesce(p_etiquetas, '{}'),
         chatwoot_sync_em   = now()
   where chatwoot_conversation_id = btrim(p_chatwoot_conversation_id)
     and canal = 'whatsapp';
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.mari_chatwoot_sync(text, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.mari_chatwoot_sync(text, text, text, text, text[]) to service_role;

-- ---------------------------------------------------------------- 2. aguardando humano (contador do menu)
-- Última fala da conversa é do cliente (depois da última fala da Mari e do time), com handoff para o time e A resolver.
create or replace view public.v_mari_aguardando_humano
with (security_invoker = true) as
select c.id,
       c.chatwoot_conversation_id,
       c.chatwoot_status,
       c.chatwoot_agente,
       c.chatwoot_time,
       l.ult_lead,
       greatest(coalesce(h.ult_humano, '-infinity'::timestamptz), coalesce(m.ult_mari, '-infinity'::timestamptz)) as ult_resposta
  from public.mari_conversas c
  cross join lateral (select max(t.created_at) as ult_lead   from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead')   l
  cross join lateral (select max(t.created_at) as ult_humano from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano') h
  cross join lateral (select max(t.created_at) as ult_mari   from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'mari')   m
 where c.canal = 'whatsapp'
   and c.chatwoot_status in ('open', 'pending')
   and c.chatwoot_etiquetas && array['handoff-venda', 'handoff-humano']
   and l.ult_lead is not null
   and l.ult_lead > greatest(coalesce(h.ult_humano, '-infinity'::timestamptz), coalesce(m.ult_mari, '-infinity'::timestamptz));

comment on view public.v_mari_aguardando_humano is
  'Contador "Mari · IA" do menu: handoff-venda/handoff-humano, A resolver no Chatwoot e a última fala é do cliente. RLS da mari_conversas (admin/backoffice).';
grant select on public.v_mari_aguardando_humano to authenticated;

-- ---------------------------------------------------------------- 3. visto em (por usuário e tela)
create table if not exists public.usuario_vistos (
  usuario_id uuid        not null default auth.uid() references public.usuarios(id) on delete cascade,
  tela       text        not null check (tela in ('vendas', 'mari')),
  visto_em   timestamptz not null default now(),
  primary key (usuario_id, tela)
);
comment on table public.usuario_vistos is 'Última vez que cada usuário abriu a tela (contadores do menu lateral). Cada um só lê e grava o seu.';
alter table public.usuario_vistos enable row level security;
drop policy if exists usuario_vistos_proprio on public.usuario_vistos;
create policy usuario_vistos_proprio on public.usuario_vistos
  for all to authenticated
  using (usuario_id = auth.uid())
  with check (usuario_id = auth.uid());
grant select, insert, update on public.usuario_vistos to authenticated;

-- ---------------------------------------------------------------- 4. quem registrou a viabilidade do portal + referência
alter table public.vendas add column if not exists nio_viab_por uuid references public.usuarios(id);
-- O portal exige ponto de referência na etapa 2 (Viabilidade). A Mari passa a coletar no prompt 27 A5; até lá o backoffice
-- registra na ficha (bloco "Dados para o portal PAP"). Não entra em trava nenhuma. v_funil congela v.*: a ficha lê da tabela.
alter table public.vendas add column if not exists ponto_referencia text;
comment on column public.vendas.ponto_referencia is 'Ponto de referência do endereço (o portal PAP exige na etapa 2). Mari ou backoffice.';
comment on column public.vendas.nio_viab_por is 'Quem registrou a viabilidade do portal PAP (auth.uid() na gravação; null = automático/serviço).';

create or replace function public.vendas_carimba_viab_por()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.nio_viab_resultado is distinct from old.nio_viab_resultado then
    if new.nio_viab_resultado is null then
      new.nio_viab_por := null;
      new.nio_viab_em  := null;
    else
      new.nio_viab_por := coalesce(auth.uid(), new.nio_viab_por);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.vendas_carimba_viab_por() from public, anon, authenticated;

drop trigger if exists vendas_carimba_viab_por on public.vendas;
create trigger vendas_carimba_viab_por
  before insert or update of nio_viab_resultado on public.vendas
  for each row execute function public.vendas_carimba_viab_por();

-- ---------------------------------------------------------------- 5. trava 0 → 1: viabilidade do portal
create or replace function public.vendas_antes_status()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  mudou   boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
begin
  if not mudou then
    return new;
  end if;

  -- Sem pedido aberto no portal PAP e biometria validada (link) não existe venda (Anexo II; venda remota 05/11).
  if vendida
     and (coalesce(btrim(new.nio_pedido), '') = '' or new.biometria_status is distinct from 'validada') then
    raise exception 'Venda bloqueada: para passar de Qualificado é obrigatório o nº do pedido do portal PAP e a biometria validada (link).'
      using errcode = 'P0001';
  end if;

  -- Viabilidade (0048, prompt 27): só a do PORTAL PAP vale, Viável e com menos de 7 dias. O DFV é pista e não libera
  -- (nem a dispensa do DFV). Só na entrada em 1–5 (de Qualificado, de Saída ou já inserida vendida); o OSAB levando
  -- 2 → 3 → 4 não passa aqui.
  if vendida and (tg_op = 'INSERT' or old.status in ('0_qualificado', 'saida'))
     and not (new.nio_viab_resultado = 'viavel' and new.nio_viab_em >= now() - interval '7 days') then
    raise exception 'Venda bloqueada: falta a viabilidade do portal PAP. Consulte o endereço no portal e registre "Viável" na ficha (bloco Viabilidade › Registrar resultado). O DFV é só pista e não libera a venda.'
      using errcode = 'P0001';
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
