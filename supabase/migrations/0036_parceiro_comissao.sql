-- NIOGEN | supabase/migrations/0036_parceiro_comissao.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- Comissão FIXA por plano para o parceiro (sem estorno). parceiro_id nulo = valor PADRÃO; o do parceiro sobrepõe.
-- Nenhum valor é preenchido aqui: o Ricardo configura no Admin (etapa 2).

create table public.parceiro_comissao (
  id             bigint generated always as identity primary key,
  parceiro_id    uuid references public.parceiros (id) on delete cascade,   -- nulo = padrão
  plano_id       bigint not null references public.config_planos (id),
  valor          numeric(10, 2) not null check (valor >= 0),
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid references public.usuarios (id) default auth.uid()
);
create unique index parceiro_comissao_padrao_uq   on public.parceiro_comissao (plano_id) where parceiro_id is null;
create unique index parceiro_comissao_parceiro_uq on public.parceiro_comissao (parceiro_id, plano_id) where parceiro_id is not null;

create or replace function public.parceiro_comissao_carimba()
returns trigger language plpgsql set search_path = public as $$
begin
  new.atualizado_em  := now();
  new.atualizado_por := coalesce(auth.uid(), new.atualizado_por);
  return new;
end;
$$;
revoke execute on function public.parceiro_comissao_carimba() from public, anon, authenticated;
create trigger parceiro_comissao_carimba before insert or update on public.parceiro_comissao
  for each row execute function public.parceiro_comissao_carimba();

-- Valor que o parceiro recebe pelo plano: o dele, senão o padrão, senão null (sem comissão configurada).
create or replace function public.parceiro_comissao_valor(p_parceiro uuid, p_plano bigint)
returns numeric language sql stable set search_path = public as $$
  select coalesce(
    (select valor from public.parceiro_comissao where parceiro_id = p_parceiro and plano_id = p_plano),
    (select valor from public.parceiro_comissao where parceiro_id is null and plano_id = p_plano))
$$;
revoke execute on function public.parceiro_comissao_valor(uuid, bigint) from public, anon;
grant execute on function public.parceiro_comissao_valor(uuid, bigint) to authenticated;

alter table public.parceiro_comissao enable row level security;
create policy parceiro_comissao_admin on public.parceiro_comissao
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy parceiro_comissao_ler on public.parceiro_comissao
  for select to authenticated using (public.meu_perfil() = 'backoffice');
revoke all on public.parceiro_comissao from anon;
