-- NIOGEN | supabase/migrations/0158_razao_comissao_upload.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- Plano: docs/PLANO_sistema_fechado_etapas_121126_2135.md (Drive), etapa 5a — o que dá para fazer ANTES de chegar arquivo real.
-- Resultado buscado: quando o 1º OSAB e o 1º Extrato reais chegarem, é só ligar — o lugar do dinheiro já existe.
-- O quê:
--   1. comissao_lancamentos — a razão da comissão: uma linha por evento de dinheiro da venda (prevista, bônus previsto e, depois,
--      o que vier do extrato: comissão, bônus, estorno, multa; contestação; pagamento). Formato espelha a aba LINHA_A_LINHA.
--   2. comissao_sincronizar(venda) + gatilho — a venda instalada ganha sozinha os lançamentos "prevista" e "bônus previsto".
--   3. v_dinheiro — a trilha do dinheiro por venda instalada: em risco (30 dias) → firme → no extrato → paga | estornada,
--      com os relógios do contrato (30 d, 180 d, 120 d de contestação, 10º mês do M-10, 15 d de documentos).
--   4. nio_relatorio_linhas — guarda o arquivo da Nio (Extrato, FPD, CHURN) como veio, linha a linha, sem supor coluna. O
--      conciliador lê daqui depois que as chaves forem provadas com arquivo real (os exemplos vieram mascarados).
-- Regras (docs/CONTRATO_DHARMA_regras.md, confirmadas pelo Rogério — D5): estorno de 100 % só em cancelamento e nova ativação
-- em ≤ 30 dias, cliente/endereço já na base e não qualidade; parcial em downgrade ≤ 180 dias; churn e inadimplência NÃO estornam.
-- Por isso "em risco" é marca de atenção, nunca desconto: o desconto só existe quando vier do extrato.
-- Parceiro (D6): nada muda — segue pago na instalação, sem estorno. Aditivo: as colunas antigas de vendas não são tocadas.

-- ───────────────────────── 1. razão ─────────────────────────
create table if not exists public.comissao_lancamentos (
  id            bigserial primary key,
  parceiro_id   text not null default 'dharma',
  venda_id      uuid references public.vendas(id) on delete cascade,
  tipo          text not null check (tipo in ('prevista', 'bonus_previsto', 'extrato_comissao', 'extrato_bonus', 'extrato_estorno',
                                              'multa', 'contestacao', 'pagamento')),
  sub           text not null default '',         -- prevista: '' · bônus: transicao | nmei | m10 · extrato: o SUB_EVENTO da Nio
  valor         numeric(10, 2) not null,          -- negativo = estorno ou multa
  ciclo         text,                             -- '2026-11-2Q' (id ordenável); rótulo da Nio em chave_nio
  data_ref      date,                             -- previsto: ativação · extrato: DATA_ATV da linha
  origem        text not null default 'sistema' check (origem in ('sistema', 'extrato', 'manual')),
  importacao_id uuid references public.importacoes(id) on delete set null,
  chave_nio     jsonb,                            -- contrato, nº da OS/pedido, rótulo do ciclo, linha do arquivo
  obs           text,
  criado_em     timestamptz not null default now(),
  criado_por    uuid
);
create unique index if not exists comissao_lancamentos_previsto_uidx
  on public.comissao_lancamentos (venda_id, tipo, sub) where origem = 'sistema';
create index if not exists comissao_lancamentos_venda_idx on public.comissao_lancamentos (venda_id);
create index if not exists comissao_lancamentos_ciclo_idx on public.comissao_lancamentos (ciclo);
alter table public.comissao_lancamentos enable row level security;
drop policy if exists comissao_lancamentos_ler on public.comissao_lancamentos;
create policy comissao_lancamentos_ler on public.comissao_lancamentos for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.comissao_lancamentos from anon, authenticated;
grant select on public.comissao_lancamentos to authenticated;
grant all on public.comissao_lancamentos to service_role;
grant usage, select on sequence public.comissao_lancamentos_id_seq to service_role;
comment on table public.comissao_lancamentos is
  'Razão da comissão (0158): uma linha por evento de dinheiro da venda. Previsto nasce na instalação (sistema); o realizado entra pelo extrato da Nio. A verdade contábil é a Nio — aqui se confere.';

-- ───────────────────────── 2. previsto nasce sozinho na instalação ─────────────────────────
create or replace function public.comissao_sincronizar(p_venda uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v    public.vendas;
  inst boolean;
  base date;
begin
  select * into v from public.vendas where id = p_venda;
  if not found then return; end if;
  inst := v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  if not inst then
    delete from public.comissao_lancamentos where venda_id = v.id and origem = 'sistema';
    return;
  end if;
  base := (coalesce(v.ativado_em, v.instalado_em, now()) at time zone 'America/Sao_Paulo')::date;
  insert into public.comissao_lancamentos (venda_id, tipo, sub, valor, data_ref, ciclo, origem)
  select v.id, x.tipo, x.sub, x.valor, base,
         to_char(base, 'YYYY-MM-') || case when extract(day from base) <= 15 then '1Q' else '2Q' end, 'sistema'
    from (values ('prevista', '', coalesce(v.comissao_nominal, 0) + coalesce(v.comissao_adicionais, 0)),
                 ('bonus_previsto', 'transicao', coalesce(v.bonus_transicao_previsto, 0)),
                 ('bonus_previsto', 'nmei', coalesce(v.bonus_nmei_previsto, 0))) as x(tipo, sub, valor)
   where x.valor <> 0
  on conflict (venda_id, tipo, sub) where origem = 'sistema'
  do update set valor = excluded.valor, data_ref = excluded.data_ref, ciclo = excluded.ciclo;
  delete from public.comissao_lancamentos l
   where l.venda_id = v.id and l.origem = 'sistema'
     and ((l.tipo = 'bonus_previsto' and l.sub = 'transicao' and coalesce(v.bonus_transicao_previsto, 0) = 0)
       or (l.tipo = 'bonus_previsto' and l.sub = 'nmei' and coalesce(v.bonus_nmei_previsto, 0) = 0));
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('comissao_sincronizar', sqlerrm);
end;
$$;
revoke all on function public.comissao_sincronizar(uuid) from public, anon, authenticated;
grant execute on function public.comissao_sincronizar(uuid) to service_role;

create or replace function public._comissao_venda_mudou()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status or new.instalado_em is distinct from old.instalado_em
     or new.ativado_em is distinct from old.ativado_em or new.comissao_nominal is distinct from old.comissao_nominal
     or new.comissao_adicionais is distinct from old.comissao_adicionais
     or new.bonus_transicao_previsto is distinct from old.bonus_transicao_previsto
     or new.bonus_nmei_previsto is distinct from old.bonus_nmei_previsto then
    perform public.comissao_sincronizar(new.id);
  end if;
  return null;
end;
$$;
-- nome com "z" para rodar depois do gatilho que recalcula a comissão da venda
drop trigger if exists vendas_z_razao_comissao on public.vendas;
create trigger vendas_z_razao_comissao after insert or update on public.vendas
  for each row execute function public._comissao_venda_mudou();

-- vendas já instaladas (hoje: nenhuma) entram na razão
do $$ declare r record; begin
  for r in select id from public.vendas where instalado_em is not null or status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') loop
    perform public.comissao_sincronizar(r.id);
  end loop;
end $$;

-- ───────────────────────── 3. trilha do dinheiro ─────────────────────────
create or replace view public.v_dinheiro with (security_invoker = true) as
select
  v.id as venda_id, 'dharma'::text as parceiro_id, v.cliente_nome, v.cidade, v.nio_os, v.nio_pedido, v.nio_contrato,
  b.base_em                                                    as ativada_em,
  coalesce(l.prevista, 0)                                      as prevista,
  coalesce(l.bonus_previsto, 0)                                as bonus_previsto,
  coalesce(l.prevista, 0) + coalesce(l.bonus_previsto, 0)      as previsto_total,
  coalesce(l.extrato, 0)                                       as no_extrato,
  coalesce(l.estorno, 0)                                       as estornado,
  coalesce(l.multa, 0)                                         as multas,
  coalesce(l.pago, 0)                                          as pago,
  coalesce(l.extrato, 0) + coalesce(l.estorno, 0) + coalesce(l.multa, 0)
    - (coalesce(l.prevista, 0) + coalesce(l.bonus_previsto, 0)) as diferenca,
  case when coalesce(l.estorno, 0) < 0 and coalesce(l.extrato, 0) + coalesce(l.estorno, 0) <= 0 then 'estornada'
       when coalesce(l.n_contestacao, 0) > 0 then 'contestada'
       when coalesce(l.pago, 0) > 0 then 'paga'
       when coalesce(l.n_extrato, 0) > 0 then 'no_extrato'
       when v.cancelada_apos_instalar_em is not null or b.base_em + interval '30 days' > now() then 'em_risco'
       else 'firme' end                                        as estado,
  v.cancelada_apos_instalar_em, v.cancelada_apos_instalar_motivo,
  b.base_em + interval '30 days'                               as risco_ate,          -- estorno de 100 % (cancelamento e nova ativação)
  b.base_em + interval '180 days'                              as downgrade_ate,      -- estorno parcial
  b.base_em + interval '120 days'                              as contestar_ate,      -- contestação (CONFERIR o fato gerador com o 1º extrato)
  b.base_em + interval '10 months'                             as m10_em,             -- M-10 apura no próprio 10º mês
  v.bonus_m10_potencial,
  b.base_em + make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15)) as docs_ate,
  v.docs_entregues_em,
  l.ciclos
from public.vendas v
cross join lateral (select coalesce(v.ativado_em, v.instalado_em) as base_em) b
left join lateral (
  select sum(valor) filter (where tipo = 'prevista')                              as prevista,
         sum(valor) filter (where tipo = 'bonus_previsto')                        as bonus_previsto,
         sum(valor) filter (where tipo in ('extrato_comissao', 'extrato_bonus'))  as extrato,
         count(*)   filter (where tipo like 'extrato_%')                          as n_extrato,
         sum(valor) filter (where tipo = 'extrato_estorno')                       as estorno,
         sum(valor) filter (where tipo = 'multa')                                 as multa,
         sum(valor) filter (where tipo = 'pagamento')                             as pago,
         count(*)   filter (where tipo = 'contestacao')                           as n_contestacao,
         array_agg(distinct ciclo) filter (where ciclo is not null)               as ciclos
    from public.comissao_lancamentos x where x.venda_id = v.id) l on true
where v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme');
revoke all on public.v_dinheiro from anon;
grant select on public.v_dinheiro to authenticated, service_role;
comment on view public.v_dinheiro is
  'Trilha do dinheiro por venda instalada (0158): em_risco → firme → no_extrato → paga | estornada | contestada, com os relógios do contrato. Lê a razão comissao_lancamentos.';

create or replace function public.dinheiro_resumo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'gerado_em', now(),
    'instaladas', count(*),
    'previsto_total', coalesce(sum(previsto_total), 0),
    'no_extrato', coalesce(sum(no_extrato), 0),
    'estornado', coalesce(sum(estornado), 0),
    'pago', coalesce(sum(pago), 0),
    'por_estado', coalesce((select jsonb_object_agg(estado, jsonb_build_object('n', n, 'previsto', p))
                              from (select estado, count(*) n, sum(previsto_total) p from public.v_dinheiro group by 1) x), '{}'::jsonb),
    'canceladas_apos_instalar', count(*) filter (where cancelada_apos_instalar_em is not null),
    'contestar_vencendo_30d', count(*) filter (where estado in ('firme', 'em_risco') and contestar_ate < now() + interval '30 days'),
    'extrato_importado', exists (select 1 from public.importacoes where tipo = 'extrato')
  ) into r from public.v_dinheiro;
  return r;
end;
$$;
revoke all on function public.dinheiro_resumo() from public, anon;
grant execute on function public.dinheiro_resumo() to authenticated, service_role;

-- ───────────────────────── 4. arquivo da Nio guardado como veio ─────────────────────────
create table if not exists public.nio_relatorio_linhas (
  id            bigserial primary key,
  parceiro_id   text not null default 'dharma',
  importacao_id uuid not null references public.importacoes(id) on delete cascade,
  tipo          text not null check (tipo in ('extrato', 'fpd', 'churn', 'faturas')),
  aba           text not null,
  linha         int  not null,
  dados         jsonb not null
);
create index if not exists nio_relatorio_linhas_imp_idx on public.nio_relatorio_linhas (importacao_id, aba, linha);
alter table public.nio_relatorio_linhas enable row level security;
drop policy if exists nio_relatorio_linhas_operar on public.nio_relatorio_linhas;
create policy nio_relatorio_linhas_operar on public.nio_relatorio_linhas for all to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'))
  with check ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.nio_relatorio_linhas from anon;
grant select, insert, delete on public.nio_relatorio_linhas to authenticated;
grant usage, select on sequence public.nio_relatorio_linhas_id_seq to authenticated, service_role;
grant all on public.nio_relatorio_linhas to service_role;
comment on table public.nio_relatorio_linhas is
  'Relatório da Nio (Extrato, FPD, CHURN) guardado como veio: uma linha por linha do arquivo, em JSON, sem supor coluna (0158). Dado de cliente da Nio: não sai do banco. O conciliador lê daqui depois que as chaves forem provadas com arquivo real.';
