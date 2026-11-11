-- NIOGEN | supabase/migrations/0115_parceiro_v2_pocket.sql | 10/11/2026 — Claude Code (docs/Prompt_pocket_parceiro_101126_2025.md)
-- Programa Parceiro PAP v2 (regras de 10/11, §6 do PLANO_PROGRAMA_PARCEIRO_PAP) + funções do Pocket do Parceiro.
--  1. Só quinzenal (sai o diário e o incentivo do quinzenal).
--  2. Calendário de pagamento `parceiro_calendario` (quinta em que a Nio paga → sexta em que o parceiro recebe),
--     semeado com os ciclos 2Q OUT26 → 1Q DEZ26 do calendário Posto Fiscal da Nio (referencia-nio/nio_ciclos_calendario_2026…csv).
--     Vencimento = sexta do ciclo que contém a instalação; sem ciclo cadastrado = NULL ("data a confirmar").
--  3. Degraus em R$ (ajuda de custo): 800 → 300 · 1.300 → 600 · 2.000 → 1.000 · 2.600 → 1.500.
--  4. Garantia Bronze: ≥ 800 pts numa competência → piso de R$ 300 nas 3 seguintes, fazendo ≥ 500 pts.
--  5. Largada em confiança: valor pago no aceite, abatido R$ 100 por instalada até zerar (linha negativa no extrato).
--  6. Venda indevida (admin): cancela o que a venda ia pagar e zera a ajuda de custo do mês.
--  7. Comissão padrão nova.
--  8. Funções SECURITY DEFINER do Pocket (cadastro público, resumo, vendas, pontos, pagamentos, endereço, planos, envio).
-- Regra 15: tabela nova com `parceiro_id` = TENANT ('dharma'). O freelancer é `parceiros.id` (em vendas/pagamentos,
-- a coluna `parceiro_id` continua sendo o freelancer, como desde a 0035).

-- ════════════════════════════════ 1. só quinzenal ════════════════════════════════
alter table public.parceiros drop constraint if exists parceiros_forma_pagamento_check;
update public.parceiros set forma_pagamento = 'quinzenal' where forma_pagamento <> 'quinzenal';
alter table public.parceiros alter column forma_pagamento set default 'quinzenal';
alter table public.parceiros add constraint parceiros_forma_pagamento_check check (forma_pagamento = 'quinzenal');
update public.config_parceiros set incentivo_quinzenal_valor = null, incentivo_quinzenal_multiplicador = null;
comment on column public.config_parceiros.incentivo_quinzenal_valor is 'Aposentado em 10/11/2026 (0115): sem incentivo do quinzenal. Ignorado no cálculo.';
comment on column public.config_parceiros.incentivo_quinzenal_multiplicador is 'Aposentado em 10/11/2026 (0115): multiplicador sempre 1. Ignorado no cálculo.';

-- ════════════════════════════════ colunas novas ════════════════════════════════
alter table public.parceiros
  add column if not exists cidade                        text,
  add column if not exists largada_valor                 numeric(10, 2) not null default 0 check (largada_valor >= 0),
  add column if not exists largada_paga_em               date,
  add column if not exists largada_abatimento_por_venda  numeric(10, 2) not null default 100 check (largada_abatimento_por_venda > 0),
  add column if not exists cadastro_origem               text not null default 'niogen' check (cadastro_origem in ('niogen', 'pocket')),
  add column if not exists acesso_enviado_em             timestamptz;
comment on column public.parceiros.largada_valor is 'Largada em confiança (R$) paga no aceite; abatida largada_abatimento_por_venda por instalada até zerar. Sem cobrança se não vender.';

alter table public.config_parceiros
  add column if not exists garantia_gatilho_pontos numeric(12, 2) not null default 800 check (garantia_gatilho_pontos > 0),
  add column if not exists garantia_piso           numeric(10, 2) not null default 300 check (garantia_piso >= 0),
  add column if not exists garantia_meses          int not null default 3 check (garantia_meses between 0 and 12),
  add column if not exists garantia_min_pontos     numeric(12, 2) not null default 500 check (garantia_min_pontos >= 0),
  add column if not exists envios_por_dia          int not null default 30 check (envios_por_dia > 0);
comment on column public.config_parceiros.garantia_gatilho_pontos is 'Garantia Bronze: quem faz ≥ isto numa competência tem garantia_piso nas garantia_meses seguintes, se fizer ≥ garantia_min_pontos.';

update public.config_parceiros set degraus =
  '[{"pontos":800,"premio":300,"nome":"Bronze"},{"pontos":1300,"premio":600,"nome":"Prata"},{"pontos":2000,"premio":1000,"nome":"Ouro"},{"pontos":2600,"premio":1500,"nome":"Diamante"}]'::jsonb;

alter table public.vendas
  add column if not exists parceiro_indevida        boolean not null default false,
  add column if not exists parceiro_indevida_motivo text,
  add column if not exists parceiro_indevida_em     timestamptz,
  add column if not exists parceiro_indevida_por    uuid references public.usuarios (id);
alter table public.vendas drop constraint if exists vendas_parceiro_indevida_check;
alter table public.vendas add constraint vendas_parceiro_indevida_check
  check (not parceiro_indevida or (origem = 'parceiro_pap' and coalesce(btrim(parceiro_indevida_motivo), '') <> ''));
comment on column public.vendas.parceiro_indevida is 'Venda de parceiro fora das regras (admin): não paga e zera a ajuda de custo do mês do parceiro.';

-- pagamentos: vencimento pode ficar a confirmar; abatimento da largada é linha negativa.
alter table public.parceiro_pagamentos alter column vence_em drop not null;
alter table public.parceiro_pagamentos drop constraint if exists parceiro_pagamentos_tipo_check;
alter table public.parceiro_pagamentos add constraint parceiro_pagamentos_tipo_check
  check (tipo in ('comissao', 'incentivo_quinzenal', 'premio_degrau', 'bonus_boas_vindas', 'largada_abatimento'));
alter table public.parceiro_pagamentos drop constraint if exists parceiro_pagamentos_valor_check;
alter table public.parceiro_pagamentos add constraint parceiro_pagamentos_valor_check
  check ((tipo <> 'largada_abatimento' and valor > 0) or (tipo = 'largada_abatimento' and valor < 0));
alter table public.parceiro_pagamentos drop constraint if exists parceiro_pagamentos_pago_tem_data_check;
alter table public.parceiro_pagamentos add constraint parceiro_pagamentos_pago_tem_data_check
  check (status <> 'pago' or vence_em is not null);
comment on column public.parceiro_pagamentos.vence_em is 'Sexta em que o parceiro recebe (parceiro_calendario). NULL = ciclo ainda não cadastrado ("data a confirmar").';

-- ════════════════════════════════ 2. calendário de pagamento ════════════════════════════════
create table if not exists public.parceiro_calendario (
  id                  bigint generated always as identity primary key,
  parceiro_id         text not null default 'dharma',          -- TENANT (regra 15), não o freelancer
  ciclo               text not null check (btrim(ciclo) <> ''),
  instalacoes_de      date not null,
  instalacoes_ate     date not null,
  nio_paga_em         date not null,
  parceiro_recebe_em  date not null,
  confirmado          boolean not null default false,
  obs                 text,
  atualizado_em       timestamptz not null default now(),
  atualizado_por      uuid references public.usuarios (id) default auth.uid(),
  unique (parceiro_id, ciclo),
  check (instalacoes_de <= instalacoes_ate),
  check (nio_paga_em > instalacoes_ate),
  check (parceiro_recebe_em >= nio_paga_em)
);
comment on table public.parceiro_calendario is
  'Ciclos de pagamento ao parceiro: instalações de..até, quinta em que a Nio paga a Dharma, sexta em que o parceiro recebe. A Dharma nunca adianta caixa.';

-- Sexta seguinte à quinta da Nio; feriado → próximo dia útil.
create or replace function public.parceiro_sexta_de(p_nio date)
returns date language plpgsql stable set search_path = public as $$
declare
  d date := p_nio + ((5 - extract(isodow from p_nio)::int + 7) % 7);
begin
  if d = p_nio then d := d + 7; end if;
  if exists (select 1 from public.config_feriados f where f.data = d and f.escopo = 'nacional') then
    d := public.proximo_dia_util(d);
  end if;
  return d;
end;
$$;
revoke execute on function public.parceiro_sexta_de(date) from public, anon;
grant execute on function public.parceiro_sexta_de(date) to authenticated;

create or replace function public.parceiro_calendario_antes()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.parceiro_recebe_em is null then
    new.parceiro_recebe_em := public.parceiro_sexta_de(new.nio_paga_em);
  end if;
  if exists (select 1 from public.parceiro_calendario c
              where c.parceiro_id = new.parceiro_id and c.id is distinct from new.id
                and daterange(c.instalacoes_de, c.instalacoes_ate, '[]') && daterange(new.instalacoes_de, new.instalacoes_ate, '[]')) then
    raise exception 'O ciclo % cruza com outro ciclo já cadastrado.', new.ciclo using errcode = 'P0001';
  end if;
  new.atualizado_em  := now();
  new.atualizado_por := coalesce(auth.uid(), new.atualizado_por);
  return new;
end;
$$;
revoke execute on function public.parceiro_calendario_antes() from public, anon, authenticated;
drop trigger if exists parceiro_calendario_antes on public.parceiro_calendario;
create trigger parceiro_calendario_antes before insert or update on public.parceiro_calendario
  for each row execute function public.parceiro_calendario_antes();

alter table public.parceiro_calendario enable row level security;
drop policy if exists parceiro_calendario_admin on public.parceiro_calendario;
create policy parceiro_calendario_admin on public.parceiro_calendario
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
drop policy if exists parceiro_calendario_ler on public.parceiro_calendario;
create policy parceiro_calendario_ler on public.parceiro_calendario
  for select to authenticated using (public.meu_perfil() = 'backoffice');
revoke all on public.parceiro_calendario from anon;

-- Vencimento da venda: sexta do ciclo que contém o dia da instalação (fuso SP). NULL sem ciclo.
drop function if exists public.parceiro_vence_em(text, date, int[]);
create or replace function public.parceiro_vence_em(p_venda uuid)
returns date language sql stable security definer set search_path = public as $$
  select c.parceiro_recebe_em
    from public.vendas v
    join public.parceiro_calendario c
      on c.parceiro_id = 'dharma'
     and (v.instalado_em at time zone 'America/Sao_Paulo')::date between c.instalacoes_de and c.instalacoes_ate
   where v.id = p_venda and v.instalado_em is not null
   order by c.instalacoes_de
   limit 1
$$;
revoke execute on function public.parceiro_vence_em(uuid) from public, anon, authenticated;

-- Ajuda de custo da competência: 1ª sexta do calendário a partir do dia da apuração do mês seguinte.
create or replace function public.parceiro_vence_premio(p_competencia date)
returns date language sql stable security definer set search_path = public as $$
  select min(c.parceiro_recebe_em)
    from public.parceiro_calendario c, public.config_parceiros cfg
   where c.parceiro_id = 'dharma'
     and c.parceiro_recebe_em >= ((date_trunc('month', p_competencia) + interval '1 month')::date + (cfg.dia_apuracao - 1))
$$;
revoke execute on function public.parceiro_vence_premio(date) from public, anon, authenticated;

-- Recalcula o vencimento (e a competência do caixa) do que ainda não foi pago. Roda quando o calendário muda.
create or replace function public.parceiro_recalcular_vencimentos()
returns int language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  with novo as (
    select g.id,
           case when g.tipo = 'premio_degrau' then public.parceiro_vence_premio(g.competencia)
                else public.parceiro_vence_em(g.venda_id) end as vence
      from public.parceiro_pagamentos g
     where g.status = 'previsto'
  )
  update public.parceiro_pagamentos g
     set vence_em = n.vence,
         competencia = case when g.tipo = 'premio_degrau' or n.vence is null then g.competencia
                            else date_trunc('month', n.vence)::date end
    from novo n
   where n.id = g.id and g.vence_em is distinct from n.vence;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.parceiro_recalcular_vencimentos() from public, anon, authenticated;

create or replace function public.parceiro_calendario_depois()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.parceiro_recalcular_vencimentos();
  return null;
end;
$$;
revoke execute on function public.parceiro_calendario_depois() from public, anon, authenticated;
drop trigger if exists parceiro_calendario_depois on public.parceiro_calendario;
create trigger parceiro_calendario_depois after insert or update or delete on public.parceiro_calendario
  for each statement execute function public.parceiro_calendario_depois();

-- Semente: ciclos do calendário Posto Fiscal 2026 da Nio (Rogério, 05/11) que pagam a partir de hoje.
insert into public.parceiro_calendario (ciclo, instalacoes_de, instalacoes_ate, nio_paga_em, parceiro_recebe_em, confirmado, obs) values
  ('2QOUT26', '2026-10-16', '2026-10-31', '2026-11-12', public.parceiro_sexta_de('2026-11-12'), true, 'Calendário Posto Fiscal Nio 2026'),
  ('1QNOV26', '2026-11-01', '2026-11-15', '2026-11-26', public.parceiro_sexta_de('2026-11-26'), true, 'Calendário Posto Fiscal Nio 2026'),
  ('2QNOV26', '2026-11-16', '2026-11-30', '2026-12-10', public.parceiro_sexta_de('2026-12-10'), true, 'Calendário Posto Fiscal Nio 2026'),
  ('1QDEZ26', '2026-12-01', '2026-12-15', '2026-12-24', public.parceiro_sexta_de('2026-12-24'), true, 'Calendário Posto Fiscal Nio 2026 · sexta 25/12 é Natal')
on conflict (parceiro_id, ciclo) do nothing;

-- ════════════════════════════════ 7. comissão padrão (10/11) ════════════════════════════════
-- Regular V-REG/V-NFID 150/190/220/240 · BTU V-O50/V-O50N 110/140/165/180 (Ricardo, §6 do plano).
-- Empresas Regular = comissão Nio × 0,43 arredondada a 5 (120→50 · 350→150 · 450→195 · 500→215).
-- Empresas BTU = mesma proporção do Varejo BTU de mesma comissão Nio (263→110 · 338→140 · 375→165).
with alvo(codigo, valor) as (values
  ('V-REG-FIBRA', 150), ('V-NFID-FIBRA', 150), ('V-REG-ESS', 190), ('V-NFID-ESS', 190),
  ('V-REG-SUP', 220),   ('V-NFID-SUP', 220),   ('V-REG-ULT', 240), ('V-NFID-ULT', 240),
  ('V-O50-FIBRA', 110), ('V-O50N-FIBRA', 110), ('V-O50-ESS', 140), ('V-O50N-ESS', 140),
  ('V-O50-SUP', 165),   ('V-O50N-SUP', 165),   ('V-O50-ULT', 180), ('V-O50N-ULT', 180),
  ('E-REG-FIBRA', 50),  ('E-REG-ESS', 150),    ('E-REG-SUP', 195), ('E-REG-ULT', 215),
  ('E-BTU-ESS', 110),   ('E-BTU-SUP', 140),    ('E-BTU-ULT', 165)
), planos as (
  select p.id, a.valor from alvo a join public.config_planos p on p.codigo = a.codigo and p.ativo
), upd as (
  update public.parceiro_comissao c set valor = pl.valor
    from planos pl where c.parceiro_id is null and c.plano_id = pl.id and c.valor <> pl.valor
  returning c.plano_id
)
insert into public.parceiro_comissao (parceiro_id, plano_id, valor)
select null, pl.id, pl.valor from planos pl
 where not exists (select 1 from public.parceiro_comissao c where c.parceiro_id is null and c.plano_id = pl.id);

-- ════════════════════════════════ pontos, degraus e garantia ════════════════════════════════
create or replace function public.parceiro_pontos_de(p_parceiro uuid, p_competencia date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(pontos), 0) from public.pontos_lancamentos
   where parceiro_id = p_parceiro and competencia = date_trunc('month', p_competencia)::date
$$;
revoke execute on function public.parceiro_pontos_de(uuid, date) from public, anon, authenticated;

-- Última competência coberta pela garantia (NULL = sem garantia): gatilho + garantia_meses.
create or replace function public.parceiro_garantia_ate(p_parceiro uuid)
returns date language sql stable security definer set search_path = public as $$
  select (max(x.competencia) + make_interval(months => cfg.garantia_meses))::date
    from (select competencia, sum(pontos) s from public.pontos_lancamentos
           where parceiro_id = p_parceiro group by competencia) x,
         public.config_parceiros cfg
   where x.s >= cfg.garantia_gatilho_pontos and cfg.garantia_meses > 0
   group by cfg.garantia_meses
$$;
revoke execute on function public.parceiro_garantia_ate(uuid) from public, anon, authenticated;

-- Competência de uma venda para a qualidade: a dos pontos dela; sem pontos, o mês da instalação ou do envio.
create or replace function public.parceiro_competencia_venda(p_venda uuid)
returns date language sql stable security definer set search_path = public as $$
  select coalesce(
    (select min(l.competencia) from public.pontos_lancamentos l where l.venda_id = v.id),
    date_trunc('month', coalesce(v.instalado_em, v.criado_em) at time zone 'America/Sao_Paulo')::date)
  from public.vendas v where v.id = p_venda
$$;
revoke execute on function public.parceiro_competencia_venda(uuid) from public, anon, authenticated;

create or replace function public.parceiro_mes_com_indevida(p_parceiro uuid, p_competencia date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.vendas v
                  where v.parceiro_id = p_parceiro and v.parceiro_indevida
                    and public.parceiro_competencia_venda(v.id) = date_trunc('month', p_competencia)::date)
$$;
revoke execute on function public.parceiro_mes_com_indevida(uuid, date) from public, anon, authenticated;

-- ════════════════════════════════ lançamento na instalação confirmada (v2) ════════════════════════════════
create or replace function public.parceiro_lancar_instalacao(p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v        public.vendas%rowtype;
  p        public.parceiros%rowtype;
  cfg      public.config_parceiros%rowtype;
  pl       public.config_planos%rowtype;
  a        record;
  inst_dia date;
  comp     date;
  comp_pg  date;
  preco    numeric;
  valor    numeric;
  vence    date;
  saldo    numeric;
  n        int;
  n_pontos int := 0;
  n_pag    int := 0;
  primeira boolean;
begin
  select * into v from public.vendas where id = p_venda;
  if not found or v.parceiro_id is null then
    return jsonb_build_object('lancado', false, 'motivo', 'venda sem parceiro');
  end if;
  if v.parceiro_indevida then
    return jsonb_build_object('lancado', false, 'motivo', 'venda marcada como indevida');
  end if;
  if not (v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
          and v.nio_situacao = 'Concluído' and v.nio_venda_valida is true and v.instalado_em is not null) then
    return jsonb_build_object('lancado', false, 'motivo', 'instalação ainda não confirmada pela Nio');
  end if;

  select * into p   from public.parceiros where id = v.parceiro_id;
  select * into cfg from public.config_parceiros;
  inst_dia := (v.instalado_em at time zone 'America/Sao_Paulo')::date;

  comp := date_trunc('month', v.instalado_em at time zone 'America/Sao_Paulo')::date;
  if exists (select 1 from public.parceiro_apuracoes where competencia = comp) then
    comp := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  end if;

  -- Pontos: 1 R$ contratado = 1 ponto (plano na forma escolhida + adicionais). Sem multiplicador desde a 0115.
  select * into pl from public.config_planos where id = v.plano_id;
  preco := case when v.forma_pagamento = 'cartao' then coalesce(pl.preco_cartao, pl.preco) else pl.preco end;
  if coalesce(preco, 0) > 0 then
    insert into public.pontos_lancamentos (parceiro_id, venda_id, competencia, tipo, valor_base, multiplicador, pontos)
    values (p.id, v.id, comp, 'plano', preco, 1, round(preco, 2))
    on conflict (venda_id) where tipo = 'plano' do nothing;
    get diagnostics n = row_count;
    n_pontos := n_pontos + n;
  end if;
  for a in
    select va.adicional_id, va.qtd, ca.preco
      from public.venda_adicionais va
      join public.config_adicionais ca on ca.id = va.adicional_id
     where va.venda_id = v.id and coalesce(ca.preco, 0) > 0
  loop
    insert into public.pontos_lancamentos (parceiro_id, venda_id, adicional_id, competencia, tipo, valor_base, multiplicador, pontos)
    values (p.id, v.id, a.adicional_id, comp, 'adicional', a.preco * a.qtd, 1, round(a.preco * a.qtd, 2))
    on conflict (venda_id, adicional_id) where tipo = 'adicional' do nothing;
    get diagnostics n = row_count;
    n_pontos := n_pontos + n;
  end loop;

  -- Pagamentos: sexta do ciclo da instalação (NULL = data a confirmar até o ciclo entrar no calendário).
  vence   := public.parceiro_vence_em(v.id);
  comp_pg := date_trunc('month', coalesce(vence, inst_dia))::date;

  valor := public.parceiro_comissao_valor(p.id, v.plano_id);
  if coalesce(valor, 0) > 0 then
    insert into public.parceiro_pagamentos (parceiro_id, tipo, venda_id, competencia, valor, vence_em)
    values (p.id, 'comissao', v.id, comp_pg, valor, vence)
    on conflict do nothing;
    get diagnostics n = row_count;
    n_pag := n_pag + n;
  elsif not exists (select 1 from public.eventos_venda where venda_id = v.id and tipo = 'parceiro_sem_comissao') then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'parceiro_sem_comissao', jsonb_build_object('parceiro_id', p.id, 'plano_id', v.plano_id), auth.uid());
  end if;

  -- Boas-vindas (se configurado): 1ª venda instalada, dentro do prazo contado da aprovação.
  if coalesce(cfg.bonus_boas_vindas_valor, 0) > 0 and cfg.bonus_boas_vindas_prazo_dias is not null and p.aprovado_em is not null then
    primeira := not exists (select 1 from public.pontos_lancamentos x where x.parceiro_id = p.id and x.tipo = 'plano' and x.venda_id <> v.id)
            and not exists (select 1 from public.parceiro_pagamentos x where x.parceiro_id = p.id and x.tipo = 'comissao' and x.venda_id <> v.id);
    if primeira and inst_dia <= (p.aprovado_em at time zone 'America/Sao_Paulo')::date + cfg.bonus_boas_vindas_prazo_dias then
      insert into public.parceiro_pagamentos (parceiro_id, tipo, venda_id, competencia, valor, vence_em)
      values (p.id, 'bonus_boas_vindas', v.id, comp_pg, cfg.bonus_boas_vindas_valor, vence)
      on conflict do nothing;
      get diagnostics n = row_count;
      n_pag := n_pag + n;
    end if;
  end if;

  -- Largada em confiança: abate na instalada até zerar (só se a largada foi paga e esta venda gerou comissão).
  if p.largada_paga_em is not null and p.largada_valor > 0
     and exists (select 1 from public.parceiro_pagamentos x where x.venda_id = v.id and x.tipo = 'comissao' and x.status <> 'cancelado') then
    select p.largada_valor + coalesce(sum(x.valor), 0) into saldo
      from public.parceiro_pagamentos x
     where x.parceiro_id = p.id and x.tipo = 'largada_abatimento' and x.status <> 'cancelado';
    if saldo > 0 then
      insert into public.parceiro_pagamentos (parceiro_id, tipo, venda_id, competencia, valor, vence_em, obs)
      values (p.id, 'largada_abatimento', v.id, comp_pg, -least(p.largada_abatimento_por_venda, saldo), vence,
              'Abatimento da largada (saldo antes: R$ ' || to_char(saldo, 'FM999G990D00') || ')')
      on conflict do nothing;
      get diagnostics n = row_count;
      n_pag := n_pag + n;
    end if;
  end if;

  return jsonb_build_object('lancado', true, 'pontos_novos', n_pontos, 'pagamentos_novos', n_pag,
                            'competencia', comp, 'vence_em', vence);
end;
$$;
revoke execute on function public.parceiro_lancar_instalacao(uuid) from public, anon, authenticated;
grant execute on function public.parceiro_lancar_instalacao(uuid) to service_role;

-- ════════════════════════════════ apuração mensal (v2: degrau R$, garantia, indevida) ════════════════════════════════
create or replace function public.apurar_premios_parceiros(p_competencia date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m        date := date_trunc('month', p_competencia)::date;
  cfg      public.config_parceiros%rowtype;
  r        record;
  deg      record;
  venc     date;
  n        int;
  n_parc   int := 0;
  n_premio int := 0;
  garante  boolean;
  indev    boolean;
  premio   numeric;
  motivo   text;
  detalhe  jsonb := '[]'::jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só o serviço ou admin/backoffice apuram prêmios.' using errcode = '42501';
  end if;
  if (m + interval '1 month') > (now() at time zone 'America/Sao_Paulo') then
    raise exception 'A competência % ainda não terminou.', to_char(m, 'MM/YYYY') using errcode = 'P0001';
  end if;
  select * into cfg from public.config_parceiros;
  if jsonb_array_length(coalesce(cfg.degraus, '[]'::jsonb)) = 0 then
    raise exception 'Degraus não configurados: configure em Configurações › Programa Parceiro antes de apurar.' using errcode = 'P0001';
  end if;
  venc := public.parceiro_vence_premio(m);

  for r in
    select parceiro_id, sum(pontos) as pontos from public.pontos_lancamentos
     where competencia = m group by parceiro_id having sum(pontos) > 0
  loop
    n_parc := n_parc + 1;
    select (e ->> 'pontos')::numeric as pontos, (e ->> 'premio')::numeric as premio, e ->> 'nome' as nome into deg
      from jsonb_array_elements(cfg.degraus) e
     where (e ->> 'pontos')::numeric <= r.pontos
     order by (e ->> 'pontos')::numeric desc limit 1;
    -- Garantia: algum mês das garantia_meses anteriores chegou ao gatilho, e este mês fez o mínimo.
    garante := cfg.garantia_meses > 0 and r.pontos >= cfg.garantia_min_pontos and exists (
      select 1 from public.pontos_lancamentos x
       where x.parceiro_id = r.parceiro_id and x.competencia >= (m - make_interval(months => cfg.garantia_meses))::date and x.competencia < m
       group by x.competencia having sum(x.pontos) >= cfg.garantia_gatilho_pontos);
    indev := public.parceiro_mes_com_indevida(r.parceiro_id, m);
    premio := case when indev then 0 else greatest(coalesce(deg.premio, 0), case when garante then cfg.garantia_piso else 0 end) end;
    motivo := case when indev then 'venda indevida no mês: sem ajuda de custo'
                   when garante and cfg.garantia_piso > coalesce(deg.premio, 0) then 'Garantia Bronze (' || r.pontos::text || ' pontos no mês)'
                   else 'Degrau ' || coalesce(deg.nome, deg.pontos::text) || ' (' || r.pontos::text || ' pontos no mês)' end;
    n := 0;
    if premio > 0 then
      insert into public.parceiro_pagamentos (parceiro_id, tipo, competencia, valor, vence_em, obs)
      values (r.parceiro_id, 'premio_degrau', m, premio, venc, 'Ajuda de custo · ' || motivo)
      on conflict do nothing;
      get diagnostics n = row_count;
      n_premio := n_premio + n;
    end if;
    detalhe := detalhe || jsonb_build_object('parceiro_id', r.parceiro_id, 'pontos', r.pontos, 'degrau', deg.pontos,
                                             'premio', premio, 'garantia', garante, 'indevida', indev, 'motivo', motivo, 'novo', n = 1);
  end loop;

  insert into public.parceiro_apuracoes (competencia, resumo)
  values (m, jsonb_build_object('parceiros_com_pontos', n_parc, 'premios_novos', n_premio))
  on conflict (competencia) do nothing;

  return jsonb_build_object('competencia', m, 'parceiros_com_pontos', n_parc, 'premios_novos', n_premio,
                            'vence_em', venc, 'detalhe', detalhe);
end;
$$;
revoke execute on function public.apurar_premios_parceiros(date) from public, anon;
grant execute on function public.apurar_premios_parceiros(date) to authenticated, service_role;

-- ════════════════════════════════ 6. venda indevida (admin) ════════════════════════════════
create or replace function public.parceiro_marcar_indevida(p_venda uuid, p_indevida boolean, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v    public.vendas%rowtype;
  comp date;
  n1   int := 0;
  n2   int := 0;
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception 'Só o admin marca venda indevida.' using errcode = '42501';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found or v.origem <> 'parceiro_pap' then
    raise exception 'Venda de parceiro não encontrada.' using errcode = 'P0001';
  end if;
  if p_indevida and coalesce(btrim(p_motivo), '') = '' then
    raise exception 'Marcar venda indevida exige motivo.' using errcode = 'P0001';
  end if;
  comp := public.parceiro_competencia_venda(v.id);

  update public.vendas set parceiro_indevida = p_indevida,
         parceiro_indevida_motivo = case when p_indevida then btrim(p_motivo) end,
         parceiro_indevida_em = case when p_indevida then now() end,
         parceiro_indevida_por = case when p_indevida then auth.uid() end
   where id = v.id;

  if p_indevida then
    update public.parceiro_pagamentos set status = 'cancelado', obs = concat_ws(' · ', obs, '[indevida]')
     where venda_id = v.id and status = 'previsto';
    get diagnostics n1 = row_count;
    update public.parceiro_pagamentos set status = 'cancelado', obs = concat_ws(' · ', obs, '[indevida]')
     where parceiro_id = v.parceiro_id and tipo = 'premio_degrau' and competencia = comp and status = 'previsto';
    get diagnostics n2 = row_count;
  else
    update public.parceiro_pagamentos set status = 'previsto', obs = nullif(btrim(replace(replace(obs, ' · [indevida]', ''), '[indevida]', '')), '')
     where venda_id = v.id and status = 'cancelado' and obs like '%[indevida]%';
    get diagnostics n1 = row_count;
    if not public.parceiro_mes_com_indevida(v.parceiro_id, comp) then
      update public.parceiro_pagamentos set status = 'previsto', obs = nullif(btrim(replace(replace(obs, ' · [indevida]', ''), '[indevida]', '')), '')
       where parceiro_id = v.parceiro_id and tipo = 'premio_degrau' and competencia = comp and status = 'cancelado' and obs like '%[indevida]%';
      get diagnostics n2 = row_count;
    end if;
  end if;

  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'parceiro_indevida', jsonb_strip_nulls(jsonb_build_object('indevida', p_indevida, 'motivo', p_motivo,
          'competencia', comp, 'pagamentos', n1, 'ajuda_de_custo', n2)), auth.uid());
  return jsonb_build_object('indevida', p_indevida, 'competencia', comp, 'pagamentos_mudados', n1, 'ajuda_mudada', n2);
end;
$$;
revoke execute on function public.parceiro_marcar_indevida(uuid, boolean, text) from public, anon;
grant execute on function public.parceiro_marcar_indevida(uuid, boolean, text) to authenticated;

-- ════════════════════════════════ usuário do Pocket não vira usuário do NIOGEN ════════════════════════════════
create or replace function public._usuario_novo()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_perfil text := lower(coalesce(new.raw_user_meta_data ->> 'perfil', ''));
begin
  -- 0115: login do Pocket do Parceiro (app_metadata só o service role grava) não entra em `usuarios`.
  if coalesce(new.raw_app_meta_data ->> 'tipo', '') = 'parceiro' then
    return new;
  end if;
  if v_perfil not in ('admin', 'vendedor', 'backoffice') or v_perfil = 'admin' then
    v_perfil := 'vendedor';   -- admin nunca nasce de convite
  end if;
  insert into public.usuarios (id, nome, perfil, ativo)
  values (new.id,
          coalesce(nullif(btrim(new.raw_user_meta_data ->> 'nome'), ''), split_part(coalesce(new.email, 'novo'), '@', 1)),
          v_perfil, false)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ════════════════════════════════ 8. Pocket do Parceiro ════════════════════════════════
-- Tudo abaixo filtra por parceiro_atual() (auth.uid() → parceiros.auth_user_id). Nunca CPF, telefone, e-mail,
-- logradouro, número, pedido Nio nem observação interna de cliente nenhum.

create or replace function public.parceiro_ativo_ou_erro()
returns public.parceiros language plpgsql stable security definer set search_path = public as $$
declare
  p public.parceiros%rowtype;
begin
  select * into p from public.parceiros where auth_user_id = auth.uid();
  if not found then
    raise exception 'Acesso só para parceiros. Peça um novo link à Dharma.' using errcode = '42501';
  end if;
  if p.status <> 'ativo' then
    raise exception 'Seu cadastro ainda não está ativo. A Dharma vai te chamar no WhatsApp.' using errcode = 'P0001';
  end if;
  return p;
end;
$$;
revoke execute on function public.parceiro_ativo_ou_erro() from public, anon, authenticated;

create or replace function public.parceiro_degraus()
returns table (pontos numeric, premio numeric, nome text)
language sql stable security definer set search_path = public as $$
  select (e ->> 'pontos')::numeric, (e ->> 'premio')::numeric, e ->> 'nome'
    from public.config_parceiros c, jsonb_array_elements(c.degraus) e
   order by 1
$$;
revoke execute on function public.parceiro_degraus() from public, anon, authenticated;

-- Plano que cobre os pontos que faltam ("1 Super", "2 Ultra"): tabela da cidade do parceiro, Varejo com fidelidade.
create or replace function public.parceiro_exemplo_plano(p_parceiro uuid, p_faltam numeric)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  cl   text;
  r    record;
  topo record;
begin
  if p_faltam is null or p_faltam <= 0 then return null; end if;
  select coalesce(public.cluster_da_area(p.cidade, 'MG', null), 'regular') into cl from public.parceiros p where p.id = p_parceiro;
  select split_part(coalesce(pl.nome_curto, pl.nome), ' ', 1) as nome, pl.preco into r
    from public.config_planos pl
   where pl.ativo and pl.portfolio = 'varejo' and pl.cluster = coalesce(cl, 'regular') and pl.variante in ('regular', 'oferta50')
     and pl.preco >= p_faltam and pl.vigencia_inicio <= current_date and (pl.vigencia_fim is null or pl.vigencia_fim >= current_date)
   order by pl.preco limit 1;
  if found then return '1 ' || r.nome; end if;
  select split_part(coalesce(pl.nome_curto, pl.nome), ' ', 1) as nome, pl.preco into topo
    from public.config_planos pl
   where pl.ativo and pl.portfolio = 'varejo' and pl.cluster = coalesce(cl, 'regular') and pl.variante in ('regular', 'oferta50')
     and pl.vigencia_inicio <= current_date and (pl.vigencia_fim is null or pl.vigencia_fim >= current_date)
   order by pl.preco desc limit 1;
  if not found or coalesce(topo.preco, 0) <= 0 then return null; end if;
  return ceil(p_faltam / topo.preco)::int || ' ' || topo.nome;
end;
$$;
revoke execute on function public.parceiro_exemplo_plano(uuid, numeric) from public, anon, authenticated;

-- ─────────── pontos do parceiro (v2: degrau atual, próximo, exemplo de plano, garantia) ───────────
drop function if exists public.parceiro_meus_pontos();
create function public.parceiro_meus_pontos()
returns table (
  competencia date, pontos numeric, degrau_pontos numeric, degrau_premio numeric,
  proximo_degrau_pontos numeric, proximo_degrau_premio numeric, faltam_pontos numeric, apurado boolean,
  degrau_atual jsonb, proximo_degrau jsonb, exemplo_plano text, garantia_ate date, garantia_piso numeric,
  garantia_min_pontos numeric, garantia_vale boolean, indevida boolean, ajuda_prevista numeric)
language sql stable security definer set search_path = public as $$
  with eu as (select public.parceiro_atual() as id),
  cfg as (select * from public.config_parceiros),
  gar as (select public.parceiro_garantia_ate((select id from eu)) as ate)
  select m.competencia, m.pontos, m.degrau_pontos, m.degrau_premio, m.proximo_degrau_pontos, m.proximo_degrau_premio,
         m.faltam_pontos, m.apurado,
         (select jsonb_build_object('pontos', d.pontos, 'premio', d.premio, 'nome', d.nome) from public.parceiro_degraus() d
           where d.pontos <= m.pontos order by d.pontos desc limit 1),
         (select jsonb_build_object('pontos', d.pontos, 'premio', d.premio, 'nome', d.nome) from public.parceiro_degraus() d
           where d.pontos > m.pontos order by d.pontos limit 1),
         public.parceiro_exemplo_plano((select id from eu), m.faltam_pontos),
         g.ate,
         cfg.garantia_piso,
         cfg.garantia_min_pontos,
         -- a garantia cobre este mês: veio de um mês anterior (não do próprio) e ainda não venceu
         (g.ate is not null and m.competencia <= g.ate
            and exists (select 1 from public.pontos_lancamentos x where x.parceiro_id = (select id from eu)
                          and x.competencia >= (m.competencia - make_interval(months => cfg.garantia_meses))::date and x.competencia < m.competencia
                        group by x.competencia having sum(x.pontos) >= cfg.garantia_gatilho_pontos)),
         public.parceiro_mes_com_indevida((select id from eu), m.competencia),
         case when public.parceiro_mes_com_indevida((select id from eu), m.competencia) then 0
              else greatest(coalesce(m.degrau_premio, 0),
                            case when m.pontos >= cfg.garantia_min_pontos and g.ate is not null and m.competencia <= g.ate
                                   and exists (select 1 from public.pontos_lancamentos x where x.parceiro_id = (select id from eu)
                                                 and x.competencia >= (m.competencia - make_interval(months => cfg.garantia_meses))::date and x.competencia < m.competencia
                                               group by x.competencia having sum(x.pontos) >= cfg.garantia_gatilho_pontos)
                                 then cfg.garantia_piso else 0 end) end
    from public.v_parceiro_pontos_mes m, cfg, gar g
   where m.parceiro_id = (select id from eu)
   order by m.competencia desc
$$;

-- ─────────── vendas do parceiro (v2: status em linguagem de gente) ───────────
create or replace function public.parceiro_motivo_texto(p_motivo text)
returns text language sql immutable set search_path = public as $$
  select case p_motivo
    when 'cliente_nao_confirmou' then 'O cliente não confirmou a compra.'
    when 'cliente_nao_atende'    then 'Ligamos e o cliente não atendeu.'
    when 'dados_divergentes'     then 'Os dados do cliente não bateram.'
    when 'sem_cobertura'         then 'Não tem Nio neste endereço.'
    when 'fora_da_area'          then 'Endereço fora da nossa área.'
    when 'ja_cliente_nio'        then 'Este endereço já é cliente Nio.'
    when 'ja_tem_pedido_nio'     then 'Já existe um pedido Nio para este cliente.'
    when 'cancelou_30d'          then 'O cliente cancelou a Nio há pouco tempo.'
    when 'suspeita_fraude'       then 'Venda fora das regras do programa.'
    else 'Fale com a Dharma.' end
$$;

drop function if exists public.parceiro_minhas_vendas();
create function public.parceiro_minhas_vendas()
returns table (
  venda_id uuid, enviada_em timestamptz, mes date, primeiro_nome text, bairro text, cidade text, plano text,
  situacao text, status_texto text, detalhe text, precisa_de_voce boolean, pode_reenviar boolean,
  valor numeric, pontos numeric, recebe_em date, pago_em timestamptz)
language sql stable security definer set search_path = public as $$
  with base as (
    select v.*,
           coalesce(pl.nome_curto, pl.nome) as plano_txt,
           (v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.nio_situacao = 'Concluído'
              and v.nio_venda_valida is true and v.instalado_em is not null) as confirmada,
           (select g.status   from public.parceiro_pagamentos g where g.venda_id = v.id and g.tipo = 'comissao') as pg_status,
           (select g.vence_em from public.parceiro_pagamentos g where g.venda_id = v.id and g.tipo = 'comissao') as pg_vence,
           (select g.pago_em  from public.parceiro_pagamentos g where g.venda_id = v.id and g.tipo = 'comissao') as pg_pago,
           (select count(*) from public.contatos_cliente c where c.venda_id = v.id and c.toque in ('CONF_ATENDEU', 'CONF_SEM_RESPOSTA')
               and c.em >= coalesce((select max(e.criado_em) from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'conferencia'
                                      and e.detalhe ->> 'para' = 'pendente'), v.criado_em)) as tentativas
      from public.vendas v
      left join public.config_planos pl on pl.id = v.plano_id
     where v.parceiro_id = public.parceiro_atual()
  ), st as (
    select b.*,
      case
        when b.parceiro_indevida                         then 'nao_aprovada'
        when b.conferencia_status = 'reprovada'          then 'nao_aprovada'
        when b.conferencia_status = 'devolvida'          then 'precisa'
        when b.status = 'saida'                          then 'cancelada'
        when b.conferencia_status = 'pendente'           then case when b.tentativas > 0 then 'ligando' else 'enviada' end
        when b.confirmada and b.pg_status = 'pago'       then 'paga'
        when b.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then 'instalada'
        when b.instalacao_agendada_para is not null      then 'instalacao'
        when coalesce(b.biometria_status, 'nao_enviada') <> 'validada' then 'biometria'
        else 'agendando' end as sit
      from base b
  )
  select s.id, s.criado_em, date_trunc('month', s.criado_em at time zone 'America/Sao_Paulo')::date,
         split_part(btrim(s.cliente_nome), ' ', 1), s.bairro, s.cidade, s.plano_txt, s.sit,
         case s.sit
           when 'nao_aprovada' then 'Não aprovada'
           when 'precisa'      then 'Precisa de você'
           when 'cancelada'    then 'Cancelada'
           when 'enviada'      then 'Enviada'
           when 'ligando'      then 'Estamos ligando para o cliente'
           when 'paga'         then 'Paga'
           when 'instalada'    then case when s.pg_vence is not null then 'Instalada · recebe ' || to_char(s.pg_vence, 'DD/MM')
                                         when s.confirmada then 'Instalada · data a confirmar'
                                         else 'Instalada' end
           when 'instalacao'   then 'Instalação ' || to_char(s.instalacao_agendada_para at time zone 'America/Sao_Paulo', 'DD/MM')
           when 'biometria'    then 'Esperando biometria'
           else 'Agendando a instalação' end,
         case s.sit
           when 'nao_aprovada' then case when s.parceiro_indevida then 'Venda fora das regras do programa.' else public.parceiro_motivo_texto(s.conferencia_motivo) end
           when 'precisa' then case s.conferencia_motivo
               when 'cliente_nao_atende' then 'Ligamos ' || greatest(s.tentativas, 1) || ' vez(es) e o cliente não atendeu. Peça para ele atender a ligação da Dharma.'
               when 'dados_divergentes'  then 'Os dados não bateram. Confira com o cliente.'
               when 'cliente_nao_confirmou' then 'O cliente não confirmou. Fale com ele.'
               else public.parceiro_motivo_texto(s.conferencia_motivo) end
           when 'cancelada' then 'A venda não seguiu.'
           when 'paga'      then 'Pago em ' || to_char(s.pg_pago at time zone 'America/Sao_Paulo', 'DD/MM') || '.'
           else null end,
         s.sit = 'precisa',
         s.sit = 'precisa' and s.status = '0_qualificado',
         case when s.sit in ('nao_aprovada', 'cancelada') then null else public.parceiro_comissao_valor(s.parceiro_id, s.plano_id) end,
         coalesce((select sum(x.pontos) from public.pontos_lancamentos x where x.venda_id = s.id), 0),
         s.pg_vence, s.pg_pago
    from st s
   order by (s.sit = 'precisa') desc, s.criado_em desc
$$;

-- ─────────── pagamentos do parceiro (v2: extrato com largada, próxima sexta) ───────────
drop function if exists public.parceiro_meus_pagamentos();
create function public.parceiro_meus_pagamentos()
returns table (
  id bigint, tipo text, tipo_texto text, competencia date, valor numeric, vence_em date, status text,
  pago_em timestamptz, tem_comprovante boolean, venda_primeiro_nome text, proximo_recebe_em date, proximo_valor numeric)
language sql stable security definer set search_path = public as $$
  with eu as (select * from public.parceiros where id = public.parceiro_atual()),
  prox as (
    select g.vence_em, sum(g.valor) as valor from public.parceiro_pagamentos g, eu
     where g.parceiro_id = eu.id and g.status = 'previsto' and g.vence_em >= (now() at time zone 'America/Sao_Paulo')::date
     group by g.vence_em order by g.vence_em limit 1
  )
  select g.id, g.tipo,
         case g.tipo when 'comissao' then 'Comissão' when 'premio_degrau' then 'Ajuda de custo' when 'bonus_boas_vindas' then 'Bônus de boas-vindas'
                     when 'largada_abatimento' then 'Abatimento da largada' else 'Incentivo' end,
         g.competencia, g.valor, g.vence_em, g.status, g.pago_em, (g.comprovante_path is not null),
         (select split_part(btrim(v.cliente_nome), ' ', 1) from public.vendas v where v.id = g.venda_id),
         (select vence_em from prox), (select valor from prox)
    from public.parceiro_pagamentos g, eu
   where g.parceiro_id = eu.id and g.status <> 'cancelado'
  union all
  select null, 'largada', 'Largada', date_trunc('month', eu.largada_paga_em)::date, eu.largada_valor, eu.largada_paga_em, 'pago',
         eu.largada_paga_em::timestamptz, false, null, (select vence_em from prox), (select valor from prox)
    from eu where eu.largada_paga_em is not null and eu.largada_valor > 0
  order by 6 desc nulls first, 1 desc nulls last
$$;

revoke execute on function public.parceiro_minhas_vendas(), public.parceiro_meus_pontos(), public.parceiro_meus_pagamentos() from public, anon;
grant execute on function public.parceiro_minhas_vendas(), public.parceiro_meus_pontos(), public.parceiro_meus_pagamentos() to authenticated;

-- ─────────── resumo da tela Início + dados da tela Eu ───────────
create or replace function public.parceiro_resumo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p     public.parceiros%rowtype;
  cfg   public.config_parceiros%rowtype;
  hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  prox  record;
  pts   record;
  aceite record;
  termo record;
  ciclo record;
  r     jsonb;
begin
  select * into p from public.parceiros where auth_user_id = auth.uid();
  if not found then
    raise exception 'Acesso só para parceiros. Peça um novo link à Dharma.' using errcode = '42501';
  end if;
  select * into cfg from public.config_parceiros;

  select g.vence_em, sum(g.valor) as valor, count(*) filter (where g.tipo = 'comissao') as vendas into prox
    from public.parceiro_pagamentos g
   where g.parceiro_id = p.id and g.status = 'previsto' and g.vence_em >= hoje
   group by g.vence_em order by g.vence_em limit 1;
  select * into ciclo from public.parceiro_calendario c where c.parceiro_id = 'dharma' and c.parceiro_recebe_em = prox.vence_em limit 1;
  select * into pts from public.parceiro_meus_pontos() x where x.competencia = date_trunc('month', hoje)::date;
  select a.versao, a.aceito_em into aceite from public.parceiro_aceites a where a.parceiro_id = p.id order by a.aceito_em desc limit 1;
  select t.versao into termo from public.termos_programa t where t.versao = cfg.termo_versao_vigente;

  r := jsonb_build_object(
    'nome', p.nome,
    'primeiro_nome', split_part(p.nome, ' ', 1),
    'status', p.status,
    'cidade', p.cidade,
    'whatsapp', p.whatsapp,
    'pix_chave', p.pix_chave,
    'pix_conferido', p.pix_titular_conferido_em is not null,
    'cpf_final', right(p.cpf, 2),
    'proximo', case when prox.vence_em is null then null else jsonb_build_object(
        'recebe_em', prox.vence_em, 'valor', prox.valor, 'vendas', prox.vendas,
        'instalacoes_de', ciclo.instalacoes_de, 'instalacoes_ate', ciclo.instalacoes_ate) end,
    'a_confirmar', (select jsonb_build_object('valor', coalesce(sum(g.valor), 0), 'vendas', count(*) filter (where g.tipo = 'comissao'))
                      from public.parceiro_pagamentos g where g.parceiro_id = p.id and g.status = 'previsto' and g.vence_em is null),
    'pontos', case when pts.competencia is null then null else jsonb_build_object(
        'competencia', pts.competencia, 'pontos', pts.pontos, 'degrau_atual', pts.degrau_atual, 'proximo_degrau', pts.proximo_degrau,
        'faltam_pontos', pts.faltam_pontos, 'exemplo_plano', pts.exemplo_plano, 'garantia_ate', pts.garantia_ate,
        'garantia_vale', pts.garantia_vale, 'garantia_piso', pts.garantia_piso, 'garantia_min_pontos', pts.garantia_min_pontos,
        'indevida', pts.indevida, 'ajuda_prevista', pts.ajuda_prevista) end,
    'degraus', (select coalesce(jsonb_agg(jsonb_build_object('pontos', d.pontos, 'premio', d.premio, 'nome', d.nome) order by d.pontos), '[]'::jsonb)
                  from public.parceiro_degraus() d),
    'precisa_de_voce', (select count(*) from public.parceiro_minhas_vendas() x where x.precisa_de_voce),
    'largada', case when p.largada_valor > 0 then jsonb_build_object(
        'valor', p.largada_valor, 'paga_em', p.largada_paga_em, 'por_venda', p.largada_abatimento_por_venda,
        'saldo', p.largada_valor + coalesce((select sum(g.valor) from public.parceiro_pagamentos g
                                             where g.parceiro_id = p.id and g.tipo = 'largada_abatimento' and g.status <> 'cancelado'), 0)) end,
    'termo', jsonb_build_object('vigente', termo.versao, 'aceito', aceite.versao, 'aceito_em', aceite.aceito_em,
                                'precisa_aceitar', termo.versao is not null and aceite.versao is distinct from termo.versao),
    'contato_whatsapp', public.tel_norm(coalesce(public.config_regra('parceiro_contato_whatsapp', null) #>> '{}',
                                                 public.config_regra('resumo_destino_whatsapp', null) #>> '{}')),
    'calendario', (select coalesce(jsonb_agg(jsonb_build_object('ciclo', c.ciclo, 'de', c.instalacoes_de, 'ate', c.instalacoes_ate,
                                     'recebe_em', c.parceiro_recebe_em, 'confirmado', c.confirmado) order by c.parceiro_recebe_em), '[]'::jsonb)
                     from public.parceiro_calendario c
                    where c.parceiro_id = 'dharma' and c.parceiro_recebe_em >= hoje - 45));
  return r;
end;
$$;
revoke execute on function public.parceiro_resumo() from public, anon;
grant execute on function public.parceiro_resumo() to authenticated;

-- ─────────── termo do programa ───────────
create or replace function public.parceiro_termo_vigente()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('versao', t.versao, 'texto', t.texto, 'vigente_desde', t.vigente_desde)
    from public.config_parceiros c join public.termos_programa t on t.versao = c.termo_versao_vigente
$$;
revoke execute on function public.parceiro_termo_vigente() from public;
grant execute on function public.parceiro_termo_vigente() to anon, authenticated;

create or replace function public.parceiro_aceitar_termo(p_versao text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  pid uuid := public.parceiro_atual();
begin
  if pid is null then raise exception 'Acesso só para parceiros.' using errcode = '42501'; end if;
  if p_versao is distinct from (select termo_versao_vigente from public.config_parceiros) then
    raise exception 'Este termo não é o vigente. Abra o Pocket de novo.' using errcode = 'P0001';
  end if;
  insert into public.parceiro_aceites (parceiro_id, versao) values (pid, p_versao) on conflict do nothing;
  return jsonb_build_object('aceito', p_versao);
end;
$$;
revoke execute on function public.parceiro_aceitar_termo(text) from public, anon;
grant execute on function public.parceiro_aceitar_termo(text) to authenticated;

-- ─────────── Seja parceiro (público, anônimo, com limite por IP e CPF) ───────────
create table if not exists public.parceiro_cadastro_tentativas (
  id     bigint generated always as identity primary key,
  ip     text,
  cpf    text,
  em     timestamptz not null default now(),
  ok     boolean not null default false
);
create index if not exists parceiro_cadastro_tentativas_ip_idx  on public.parceiro_cadastro_tentativas (ip, em);
create index if not exists parceiro_cadastro_tentativas_cpf_idx on public.parceiro_cadastro_tentativas (cpf, em);
alter table public.parceiro_cadastro_tentativas enable row level security;
drop policy if exists parceiro_cadastro_tentativas_admin on public.parceiro_cadastro_tentativas;
create policy parceiro_cadastro_tentativas_admin on public.parceiro_cadastro_tentativas
  for select to authenticated using (public.meu_perfil() = 'admin');
revoke all on public.parceiro_cadastro_tentativas from anon;

create or replace function public.parceiro_cadastrar(
  p_nome text, p_cpf text, p_whatsapp text, p_pix text, p_cidade text, p_termo_versao text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  hdr   jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip  text := btrim(split_part(coalesce(hdr ->> 'x-forwarded-for', hdr ->> 'x-real-ip', ''), ',', 1));
  cpf_n text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  zap   text := public.tel_norm(p_whatsapp);
  vig   text := (select termo_versao_vigente from public.config_parceiros);
  novo  uuid;
  ok    jsonb := jsonb_build_object('ok', true, 'mensagem', 'Recebemos. A Dharma vai te chamar no WhatsApp.');
begin
  if (select count(*) from public.parceiro_cadastro_tentativas t where t.ip = nullif(v_ip, '') and t.em > now() - interval '1 day') >= 8
     or (select count(*) from public.parceiro_cadastro_tentativas t where t.cpf = cpf_n and t.em > now() - interval '1 day') >= 3 then
    raise exception 'Muitas tentativas. Tente amanhã ou fale com a Dharma.' using errcode = 'P0001';
  end if;
  insert into public.parceiro_cadastro_tentativas (ip, cpf) values (nullif(v_ip, ''), nullif(cpf_n, ''));

  if coalesce(btrim(p_nome), '') = '' or position(' ' in btrim(p_nome)) = 0 then
    raise exception 'Escreva o nome completo.' using errcode = 'P0001';
  end if;
  if not public.mari_cpf_valido(cpf_n) then
    raise exception 'CPF inválido. Confira os números.' using errcode = 'P0001';
  end if;
  if zap is null or zap !~ '^55[0-9]{10,11}$' then
    raise exception 'WhatsApp inválido: escreva DDD + número.' using errcode = 'P0001';
  end if;
  if coalesce(btrim(p_pix), '') = '' then
    raise exception 'Escreva a sua chave Pix.' using errcode = 'P0001';
  end if;
  if coalesce(btrim(p_cidade), '') = '' then
    raise exception 'Escreva a sua cidade.' using errcode = 'P0001';
  end if;
  if vig is not null and p_termo_versao is distinct from vig then
    raise exception 'Leia e aceite o termo do programa.' using errcode = 'P0001';
  end if;

  -- Já cadastrado (CPF ou WhatsApp): mesma resposta, sem revelar nada.
  if exists (select 1 from public.parceiros where cpf = cpf_n or whatsapp = zap) then
    return ok;
  end if;

  insert into public.parceiros (nome, cpf, whatsapp, pix_chave, cidade, status, cadastro_origem)
  values (btrim(p_nome), cpf_n, zap, btrim(p_pix), btrim(p_cidade), 'aguardando', 'pocket')
  returning id into novo;
  if vig is not null then
    insert into public.parceiro_aceites (parceiro_id, versao) values (novo, vig);
  end if;
  update public.parceiro_cadastro_tentativas set ok = true
   where id = (select max(id) from public.parceiro_cadastro_tentativas where cpf = cpf_n);
  return ok;
end;
$$;
revoke execute on function public.parceiro_cadastrar(text, text, text, text, text, text) from public;
grant execute on function public.parceiro_cadastrar(text, text, text, text, text, text) to anon, authenticated;

-- ─────────── Enviar venda: endereço, planos, envio, reenvio ───────────
create or replace function public.parceiro_consultar_endereco(
  p_cep text, p_numero text, p_complemento text, p_cidade text, p_uf text, p_bairro text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p     public.parceiros%rowtype := public.parceiro_ativo_ou_erro();
  atend text;
  dfv   text;
  cl    text;
  cob   text;
  pode  boolean;
  msg   text;
begin
  atend := public.parceiro_checar_endereco(p_cep, p_numero, p_complemento);
  select resultado into dfv from public.dfv_consultar(p_cep, p_numero, p_complemento);
  cl := public.cluster_da_area(p_cidade, coalesce(p_uf, 'MG'), p_bairro);
  cob := case dfv when 'viavel' then 'tem' when 'viavel_predio' then 'tem' when 'endereco_ocupado' then 'ja_cliente'
                  when 'sem_porta_livre' then 'sem_vaga' when 'precisa_numero' then 'precisa_numero' else 'confirmar' end;
  pode := atend = 'livre' and cl is not null and cob in ('tem', 'confirmar');
  msg := case
    when cl is null then 'Esta cidade fica fora da nossa área. Não dá para vender aqui.'
    when atend <> 'livre' then 'A Dharma já está atendendo este endereço. Não dá para enviar.'
    when cob = 'ja_cliente' then 'Este endereço já tem Nio. Não dá para vender.'
    when cob = 'sem_vaga' then 'A Nio passa aqui, mas está sem vaga neste endereço agora.'
    when cob = 'precisa_numero' then 'Falta o número da casa.'
    when cob = 'tem' then 'Tem Nio neste endereço. Ninguém está atendendo. Pode seguir.'
    else 'Não achamos este endereço na lista da Nio. Pode enviar: a gente confirma antes de fazer o pedido.' end;
  return jsonb_build_object('pode_seguir', pode, 'cobertura', cob, 'em_atendimento', atend <> 'livre',
                            'na_area', cl is not null, 'tabela', cl, 'mensagem', msg);
end;
$$;
revoke execute on function public.parceiro_consultar_endereco(text, text, text, text, text, text) from public, anon;
grant execute on function public.parceiro_consultar_endereco(text, text, text, text, text, text) to authenticated;

create or replace function public.parceiro_planos(p_cidade text, p_uf text default 'MG', p_bairro text default null)
returns table (plano_id bigint, nome text, nome_curto text, portfolio text, segmentos text[], formas text[],
               preco numeric, preco_cartao numeric, velocidade text, inclusos text[], comissao numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  p  public.parceiros%rowtype := public.parceiro_ativo_ou_erro();
  cl text := public.cluster_da_area(p_cidade, coalesce(p_uf, 'MG'), p_bairro);
begin
  return query
  select pl.id, pl.nome, coalesce(pl.nome_curto, pl.nome), pl.portfolio, pl.segmentos,
         coalesce(pl.forma_pagamento_permitida, array['boleto', 'cartao', 'dacc']), pl.preco, pl.preco_cartao, pl.velocidade, pl.inclusos,
         public.parceiro_comissao_valor(p.id, pl.id)
    from public.config_planos pl
   where cl is not null and pl.ativo and pl.cluster = cl and pl.variante in ('regular', 'oferta50')
     and pl.vigencia_inicio <= current_date and (pl.vigencia_fim is null or pl.vigencia_fim >= current_date)
   order by pl.portfolio desc, pl.preco;
end;
$$;
revoke execute on function public.parceiro_planos(text, text, text) from public, anon;
grant execute on function public.parceiro_planos(text, text, text) to authenticated;

-- O login do parceiro não é usuário do NIOGEN: as colunas "quem fez" (criado_por, dfv_consultado_por, conferencia_por…)
-- apontam para `usuarios`. Nas gravações do Pocket o auth.uid() é apagado só dentro da transação (e devolvido no fim),
-- para os triggers gravarem "quem" = vazio em vez de quebrar a chave estrangeira. A venda leva o parceiro em parceiro_id.
create or replace function public.parceiro_uid_suspender()
returns text[] language plpgsql security definer set search_path = public as $$
declare
  c text := current_setting('request.jwt.claims', true);
  s text := current_setting('request.jwt.claim.sub', true);
begin
  perform set_config('request.jwt.claims', coalesce((nullif(c, '')::jsonb - 'sub')::text, ''), true);
  perform set_config('request.jwt.claim.sub', '', true);
  return array[coalesce(c, ''), coalesce(s, '')];
end;
$$;
create or replace function public.parceiro_uid_devolver(p text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('request.jwt.claims', p[1], true);
  perform set_config('request.jwt.claim.sub', p[2], true);
end;
$$;
revoke execute on function public.parceiro_uid_suspender(), public.parceiro_uid_devolver(text[]) from public, anon, authenticated;

create or replace function public.parceiro_enviar_venda(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  par    public.parceiros%rowtype := public.parceiro_ativo_ou_erro();
  cfg    public.config_parceiros%rowtype;
  doc    text := regexp_replace(coalesce(p ->> 'cliente_doc', ''), '\D', '', 'g');
  zap    text := public.tel_norm(p ->> 'cliente_whatsapp');
  cep    text := regexp_replace(coalesce(p ->> 'cep', ''), '\D', '', 'g');
  num    text := btrim(coalesce(p ->> 'numero', ''));
  seg    text := coalesce(nullif(p ->> 'segmento', ''), 'PF');
  forma  text := coalesce(nullif(p ->> 'forma_pagamento', ''), 'boleto');
  plano  bigint := nullif(p ->> 'plano_id', '')::bigint;
  pl     record;
  cons   jsonb;
  vid    uuid;
  obs    text := nullif(btrim(coalesce(p ->> 'observacao', '')), '');
  uid    text[];
begin
  select * into cfg from public.config_parceiros;
  if cfg.termo_versao_vigente is not null
     and not exists (select 1 from public.parceiro_aceites a where a.parceiro_id = par.id and a.versao = cfg.termo_versao_vigente) then
    raise exception 'Aceite o termo do programa antes de enviar venda.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.vendas v where v.parceiro_id = par.id and v.criado_em > now() - interval '1 day') >= cfg.envios_por_dia then
    raise exception 'Você já enviou muitas vendas hoje. Fale com a Dharma.' using errcode = 'P0001';
  end if;

  if coalesce(btrim(p ->> 'cliente_nome'), '') = '' or position(' ' in btrim(p ->> 'cliente_nome')) = 0 then
    raise exception 'Escreva o nome completo do cliente.' using errcode = 'P0001';
  end if;
  if not ((length(doc) = 11 and public.mari_cpf_valido(doc)) or length(doc) = 14) then
    raise exception 'CPF do cliente inválido. Confira os números.' using errcode = 'P0001';
  end if;
  if seg in ('MEI', 'NMEI') and length(doc) <> 14 then
    raise exception 'Para empresa, escreva o CNPJ.' using errcode = 'P0001';
  end if;
  if zap is null or zap !~ '^55[0-9]{10,11}$' then
    raise exception 'WhatsApp do cliente inválido: DDD + número.' using errcode = 'P0001';
  end if;
  if zap = par.whatsapp then
    raise exception 'O WhatsApp tem que ser o do cliente, não o seu.' using errcode = 'P0001';
  end if;
  if length(cep) <> 8 or num = '' then
    raise exception 'Falta CEP ou número do endereço.' using errcode = 'P0001';
  end if;
  if seg not in ('PF', 'MEI', 'NMEI') or forma not in ('boleto', 'cartao', 'dacc') then
    raise exception 'Escolha o tipo de cliente e a forma de pagamento.' using errcode = 'P0001';
  end if;

  cons := public.parceiro_consultar_endereco(cep, num, p ->> 'complemento', p ->> 'cidade', p ->> 'uf', p ->> 'bairro');
  if not (cons ->> 'pode_seguir')::boolean then
    raise exception '%', cons ->> 'mensagem' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.vendas v where v.status <> 'saida' and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = doc) then
    raise exception 'Este cliente já está em atendimento com a Dharma.' using errcode = 'P0001';
  end if;

  select x.* into pl from public.parceiro_planos(p ->> 'cidade', p ->> 'uf', p ->> 'bairro') x where x.plano_id = plano;
  if not found then
    raise exception 'Escolha um plano da lista.' using errcode = 'P0001';
  end if;
  if not (seg = any (pl.segmentos)) then
    raise exception 'Este plano não vale para este tipo de cliente.' using errcode = 'P0001';
  end if;
  if not (forma = any (pl.formas)) then
    raise exception 'Este plano não aceita esta forma de pagamento.' using errcode = 'P0001';
  end if;

  uid := public.parceiro_uid_suspender();
  insert into public.vendas (status, origem, parceiro_id, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
                             cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento, instalacao_preferencia,
                             trava_cpf_valido)
  values ('0_qualificado', 'parceiro_pap', par.id, btrim(p ->> 'cliente_nome'), doc, zap, nullif(btrim(coalesce(p ->> 'cliente_email', '')), ''), seg,
          cep, nullif(btrim(coalesce(p ->> 'logradouro', '')), ''), num, nullif(btrim(coalesce(p ->> 'complemento', '')), ''),
          nullif(btrim(coalesce(p ->> 'bairro', '')), ''), nullif(btrim(coalesce(p ->> 'cidade', '')), ''), upper(coalesce(nullif(p ->> 'uf', ''), 'MG')),
          plano, forma, nullif(p ->> 'instalacao_preferencia', ''), length(doc) = 11)
  returning id into vid;

  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (vid, 'parceiro_enviou', jsonb_strip_nulls(jsonb_build_object('parceiro_id', par.id, 'parceiro', par.nome, 'observacao', obs)), null);
  perform public.parceiro_uid_devolver(uid);

  return jsonb_build_object('venda_id', vid, 'comissao', pl.comissao,
                            'mensagem', 'Enviada. A gente liga para o cliente em até ' || cfg.sla_conferencia_horas || ' h úteis.');
end;
$$;
revoke execute on function public.parceiro_enviar_venda(jsonb) from public, anon;
grant execute on function public.parceiro_enviar_venda(jsonb) to authenticated;

-- Venda devolvida: o parceiro falou com o cliente e pede para a Dharma ligar de novo.
create or replace function public.parceiro_reenviar_venda(p_venda uuid, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  par public.parceiros%rowtype := public.parceiro_ativo_ou_erro();
  v   public.vendas%rowtype;
  uid text[];
begin
  select * into v from public.vendas where id = p_venda and parceiro_id = par.id for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.conferencia_status <> 'devolvida' or v.status <> '0_qualificado' then
    raise exception 'Esta venda não está esperando você.' using errcode = 'P0001';
  end if;
  uid := public.parceiro_uid_suspender();
  update public.vendas
     set conferencia_status = 'pendente',
         conferencia_obs = concat_ws(E'\n', conferencia_obs, 'Parceiro pediu nova ligação' || coalesce(': ' || nullif(btrim(p_obs), ''), '') || ' (' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ')')
   where id = v.id;
  perform public.parceiro_uid_devolver(uid);
  return jsonb_build_object('ok', true, 'mensagem', 'Pronto. A gente liga de novo para o cliente.');
end;
$$;
revoke execute on function public.parceiro_reenviar_venda(uuid, text) from public, anon;
grant execute on function public.parceiro_reenviar_venda(uuid, text) to authenticated;

-- ─────────── comprovante: o parceiro abre só o dele (URL assinada de 60 s pelo front) ───────────
drop policy if exists comprovantes_parceiros_proprio on storage.objects;
create policy comprovantes_parceiros_proprio on storage.objects
  for select to authenticated
  using (bucket_id = 'comprovantes_parceiros'
         and exists (select 1 from public.parceiro_pagamentos g
                      where g.comprovante_path = storage.objects.name and g.parceiro_id = public.parceiro_atual()));

-- ─────────── admin: vínculo do login do Pocket (chamado pela edge function parceiro-acesso) ───────────
create or replace function public.parceiro_vincular_login(p_parceiro uuid, p_auth uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Só o serviço vincula o login do parceiro.' using errcode = '42501';
  end if;
  update public.parceiros set auth_user_id = p_auth, acesso_enviado_em = now() where id = p_parceiro;
end;
$$;
revoke execute on function public.parceiro_vincular_login(uuid, uuid) from public, anon, authenticated;
grant execute on function public.parceiro_vincular_login(uuid, uuid) to service_role;
