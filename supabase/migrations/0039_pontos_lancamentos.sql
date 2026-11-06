-- NIOGEN | supabase/migrations/0039_pontos_lancamentos.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- Extrato de pontos do parceiro: 1 real contratado = 1 ponto. SÓ INSERT (nunca update/delete).
-- Quem lança: parceiro_lancar_instalacao() (0040), na instalação CONFIRMADA. Estorno da Nio NÃO gera ajuste.
-- Ajuste manual: só o admin, tipo 'ajuste' (pontos podem ser negativos), com observação.

create table public.pontos_lancamentos (
  id             bigint generated always as identity primary key,
  parceiro_id    uuid not null references public.parceiros (id) on delete restrict,
  venda_id       uuid references public.vendas (id) on delete restrict,
  adicional_id   bigint references public.config_adicionais (id),
  competencia    date not null check (competencia = date_trunc('month', competencia)::date),   -- 1º dia do mês
  tipo           text not null check (tipo in ('plano', 'adicional', 'ajuste')),
  valor_base     numeric(12, 2) not null,
  multiplicador  numeric(5, 2) not null default 1 check (multiplicador > 0),
  pontos         numeric(12, 2) not null,
  criado_em      timestamptz not null default now(),
  obs            text,
  check (tipo = 'ajuste' or (venda_id is not null and valor_base > 0 and pontos > 0)),
  check (tipo <> 'ajuste' or (coalesce(btrim(obs), '') <> ''))
);
-- Idempotência: uma linha de plano por venda e uma por adicional da venda.
create unique index pontos_lancamentos_plano_uq     on public.pontos_lancamentos (venda_id) where tipo = 'plano';
create unique index pontos_lancamentos_adicional_uq on public.pontos_lancamentos (venda_id, adicional_id) where tipo = 'adicional';
create index pontos_lancamentos_parceiro_idx on public.pontos_lancamentos (parceiro_id, competencia);

comment on table public.pontos_lancamentos is
  'Extrato de pontos do Programa Parceiro PAP (só insert). competencia = 1º dia do mês da instalação (ou do mês da confirmação, se a apuração do mês da instalação já rodou).';

create trigger pontos_lancamentos_so_insert before update or delete on public.pontos_lancamentos
  for each row execute function public.so_insert_trg();

alter table public.pontos_lancamentos enable row level security;
create policy pontos_ler on public.pontos_lancamentos
  for select to authenticated using (public.meu_perfil() in ('admin', 'backoffice'));
create policy pontos_ajuste on public.pontos_lancamentos
  for insert to authenticated with check (public.meu_perfil() = 'admin' and tipo = 'ajuste');
revoke all on public.pontos_lancamentos from anon;
