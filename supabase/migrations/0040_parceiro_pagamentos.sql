-- NIOGEN | supabase/migrations/0040_parceiro_pagamentos.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- Pagamentos ao parceiro + o LANÇAMENTO NA INSTALAÇÃO CONFIRMADA (pontos e pagamentos, idempotente).
--
-- "Instalação confirmada" (F5) = status 3/4/5 E nio_situacao = 'Concluído' E nio_venda_valida = true E instalado_em preenchido.
-- Só o aplicar_osab() grava essas colunas; a marcação manual de "Instalado" na ficha NUNCA paga.
--
-- Decisões de implementação (registradas no Diário; mudar = editar parceiro_lancar_instalacao):
--  * Vencimento parte de base = MAIOR entre o dia da instalação e o dia em que o NIOGEN confirmou (o OSAB chega com atraso;
--    senão o pagamento nasceria atrasado). Diário: 1 dia útil depois da base. Quinzenal: base dia 1–15 → dia 20 do mesmo
--    mês; base dia 16–fim → dia 5 do mês seguinte (config_parceiros.quinzenal_dias). Dia 20/5 são pagos no dia (Pix não para).
--  * Competência dos pontos = mês da instalação; se a apuração desse mês já rodou, vale o mês da confirmação.
--  * Multiplicador/incentivo valem pela forma de pagamento do parceiro NA DATA DA INSTALAÇÃO (forma_pagamento_desde).
--  * Comissão sem valor configurado (padrão nem do parceiro) não gera pagamento e deixa o evento 'parceiro_sem_comissao';
--    depois de configurar, chamar parceiro_lancar_instalacao(venda) de novo gera o que faltou (idempotente).
--  * Sem estorno: nada é cancelado automaticamente.

-- ─────────────────────── dia útil (seg–sex, sem feriado) ───────────────────────
create or replace function public.proximo_dia_util(p_data date, p_cidade text default 'Juiz de Fora')
returns date language plpgsql stable set search_path = public as $$
declare
  d date := p_data + 1;
  i int := 0;
begin
  while i < 40 loop
    if extract(isodow from d) < 6
       and not exists (select 1 from public.config_feriados f
                        where f.data = d
                          and (f.escopo = 'nacional'
                               or (f.escopo = 'municipal' and lower(f.cidade) = lower(btrim(coalesce(p_cidade, '')))))) then
      return d;
    end if;
    d := d + 1;
    i := i + 1;
  end loop;
  return d;
end;
$$;
revoke execute on function public.proximo_dia_util(date, text) from public, anon;
grant execute on function public.proximo_dia_util(date, text) to authenticated;

create or replace function public.parceiro_vence_em(p_forma text, p_base date, p_dias int[])
returns date language plpgsql stable set search_path = public as $$
begin
  if p_forma = 'quinzenal' then
    if extract(day from p_base) <= 15 then
      return (date_trunc('month', p_base)::date) + (p_dias[1] - 1);
    end if;
    return ((date_trunc('month', p_base) + interval '1 month')::date) + (p_dias[2] - 1);
  end if;
  return public.proximo_dia_util(p_base);
end;
$$;
revoke execute on function public.parceiro_vence_em(text, date, int[]) from public, anon;
grant execute on function public.parceiro_vence_em(text, date, int[]) to authenticated;

-- ─────────────────────── apurações já feitas (usada aqui e na 0041) ───────────────────────
create table public.parceiro_apuracoes (
  competencia  date primary key check (competencia = date_trunc('month', competencia)::date),
  apurada_em   timestamptz not null default now(),
  apurada_por  uuid references public.usuarios (id) default auth.uid(),
  resumo       jsonb not null default '{}'::jsonb
);
comment on table public.parceiro_apuracoes is 'Meses cujos prêmios já foram apurados (dia 5). Depois disso, pontos tardios do mês valem no mês da confirmação.';

-- ─────────────────────── pagamentos ───────────────────────
create table public.parceiro_pagamentos (
  id                 bigint generated always as identity primary key,
  parceiro_id        uuid not null references public.parceiros (id) on delete restrict,
  tipo               text not null check (tipo in ('comissao', 'incentivo_quinzenal', 'premio_degrau', 'bonus_boas_vindas')),
  venda_id           uuid references public.vendas (id) on delete restrict,       -- nulo no prêmio de degrau
  competencia        date not null check (competencia = date_trunc('month', competencia)::date),
  valor              numeric(10, 2) not null check (valor > 0),
  vence_em           date not null,
  status             text not null default 'previsto' check (status in ('previsto', 'pago', 'cancelado')),
  pago_em            timestamptz,
  pago_por           uuid references public.usuarios (id),
  comprovante_path   text,                      -- objeto do bucket PRIVADO comprovantes_parceiros (0043)
  pix_chave_snapshot text,
  criado_em          timestamptz not null default now(),
  obs                text,
  check (tipo = 'premio_degrau' or venda_id is not null),
  check (status <> 'pago' or pago_em is not null)
);
create unique index parceiro_pagamentos_venda_tipo_uq on public.parceiro_pagamentos (venda_id, tipo) where venda_id is not null;
create unique index parceiro_pagamentos_premio_uq     on public.parceiro_pagamentos (parceiro_id, competencia) where tipo = 'premio_degrau';
create unique index parceiro_pagamentos_boasvindas_uq on public.parceiro_pagamentos (parceiro_id) where tipo = 'bonus_boas_vindas';
create index parceiro_pagamentos_pagar_idx on public.parceiro_pagamentos (vence_em) where status = 'previsto';

comment on table public.parceiro_pagamentos is
  'Pagamentos ao parceiro (comissão fixa, incentivo quinzenal, prêmio de degrau, boas-vindas). SEM ESTORNO: nada é cancelado automaticamente.';

create or replace function public.parceiro_pagamentos_antes()
returns trigger language plpgsql set search_path = public as $$
declare
  p public.parceiros%rowtype;
begin
  if tg_op = 'DELETE' then
    if old.status = 'pago' then
      raise exception 'Pagamento já feito não se apaga.' using errcode = 'P0001';
    end if;
    return old;
  end if;

  select * into p from public.parceiros where id = new.parceiro_id;

  if tg_op = 'INSERT' then
    if new.status <> 'previsto' then
      raise exception 'Pagamento nasce "previsto".' using errcode = 'P0001';
    end if;
    new.pix_chave_snapshot := coalesce(new.pix_chave_snapshot, p.pix_chave);
    return new;
  end if;

  if old.status = 'pago' then
    raise exception 'Pagamento já feito não se altera.' using errcode = 'P0001';
  end if;
  if new.status = 'pago' then
    if p.pix_titular_conferido_em is null then
      raise exception 'Pagamento barrado: o titular da chave Pix do parceiro ainda não foi conferido (mesmo CPF).' using errcode = 'P0001';
    end if;
    new.pago_em            := coalesce(new.pago_em, now());
    new.pago_por           := coalesce(auth.uid(), new.pago_por);
    new.pix_chave_snapshot := p.pix_chave;
  end if;
  return new;
end;
$$;
revoke execute on function public.parceiro_pagamentos_antes() from public, anon, authenticated;
create trigger parceiro_pagamentos_antes before insert or update or delete on public.parceiro_pagamentos
  for each row execute function public.parceiro_pagamentos_antes();

alter table public.parceiro_apuracoes enable row level security;
alter table public.parceiro_pagamentos enable row level security;
create policy apuracoes_ler on public.parceiro_apuracoes
  for select to authenticated using (public.meu_perfil() in ('admin', 'backoffice'));
create policy pagamentos_admin on public.parceiro_pagamentos
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy pagamentos_backoffice_ler on public.parceiro_pagamentos
  for select to authenticated using (public.meu_perfil() = 'backoffice');
revoke all on public.parceiro_apuracoes, public.parceiro_pagamentos from anon;

-- ─────────────────────── lançamento na instalação confirmada ───────────────────────
create or replace function public.parceiro_lancar_instalacao(p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v        public.vendas%rowtype;
  p        public.parceiros%rowtype;
  cfg      public.config_parceiros%rowtype;
  pl       public.config_planos%rowtype;
  a        record;
  inst_dia date;
  base     date;
  forma    text;
  mult     numeric := 1;
  comp     date;
  preco    numeric;
  valor    numeric;
  vence    date;
  n        int;
  n_pontos int := 0;
  n_pag    int := 0;
  primeira boolean;
begin
  select * into v from public.vendas where id = p_venda;
  if not found or v.parceiro_id is null then
    return jsonb_build_object('lancado', false, 'motivo', 'venda sem parceiro');
  end if;
  if not (v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
          and v.nio_situacao = 'Concluído' and v.nio_venda_valida is true and v.instalado_em is not null) then
    return jsonb_build_object('lancado', false, 'motivo', 'instalação ainda não confirmada pela Nio');
  end if;

  select * into p   from public.parceiros where id = v.parceiro_id;
  select * into cfg from public.config_parceiros;

  inst_dia := (v.instalado_em at time zone 'America/Sao_Paulo')::date;
  base     := greatest(inst_dia, (now() at time zone 'America/Sao_Paulo')::date);
  forma    := case when p.forma_pagamento_desde <= v.instalado_em then p.forma_pagamento
                   when p.forma_pagamento = 'diario' then 'quinzenal' else 'diario' end;
  if forma = 'quinzenal' then
    mult := coalesce(p.multiplicador_override, cfg.incentivo_quinzenal_multiplicador, 1);
  end if;

  comp := date_trunc('month', v.instalado_em at time zone 'America/Sao_Paulo')::date;
  if exists (select 1 from public.parceiro_apuracoes where competencia = comp) then
    comp := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  end if;

  -- Pontos: valor contratado do plano na forma escolhida + cada serviço adicional (com preço no book).
  select * into pl from public.config_planos where id = v.plano_id;
  preco := case when v.forma_pagamento = 'cartao' then coalesce(pl.preco_cartao, pl.preco) else pl.preco end;
  if coalesce(preco, 0) > 0 then
    insert into public.pontos_lancamentos (parceiro_id, venda_id, competencia, tipo, valor_base, multiplicador, pontos)
    values (p.id, v.id, comp, 'plano', preco, mult, round(preco * mult, 2))
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
    values (p.id, v.id, a.adicional_id, comp, 'adicional', a.preco * a.qtd, mult, round(a.preco * a.qtd * mult, 2))
    on conflict (venda_id, adicional_id) where tipo = 'adicional' do nothing;
    get diagnostics n = row_count;
    n_pontos := n_pontos + n;
  end loop;

  -- Pagamentos.
  vence := public.parceiro_vence_em(forma, base, cfg.quinzenal_dias);

  valor := public.parceiro_comissao_valor(p.id, v.plano_id);
  if coalesce(valor, 0) > 0 then
    insert into public.parceiro_pagamentos (parceiro_id, tipo, venda_id, competencia, valor, vence_em)
    values (p.id, 'comissao', v.id, date_trunc('month', vence)::date, valor, vence)
    on conflict do nothing;
    get diagnostics n = row_count;
    n_pag := n_pag + n;
  elsif not exists (select 1 from public.eventos_venda where venda_id = v.id and tipo = 'parceiro_sem_comissao') then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'parceiro_sem_comissao', jsonb_build_object('parceiro_id', p.id, 'plano_id', v.plano_id), auth.uid());
  end if;

  if forma = 'quinzenal' then
    valor := coalesce(p.incentivo_valor_override, cfg.incentivo_quinzenal_valor);
    if coalesce(valor, 0) > 0 then
      insert into public.parceiro_pagamentos (parceiro_id, tipo, venda_id, competencia, valor, vence_em)
      values (p.id, 'incentivo_quinzenal', v.id, date_trunc('month', vence)::date, valor, vence)
      on conflict do nothing;
      get diagnostics n = row_count;
      n_pag := n_pag + n;
    end if;
  end if;

  -- Boas-vindas: 1ª venda instalada do parceiro, dentro do prazo contado da aprovação.
  if coalesce(cfg.bonus_boas_vindas_valor, 0) > 0 and cfg.bonus_boas_vindas_prazo_dias is not null
     and p.aprovado_em is not null then
    primeira := not exists (select 1 from public.pontos_lancamentos x
                             where x.parceiro_id = p.id and x.tipo = 'plano' and x.venda_id <> v.id)
                and not exists (select 1 from public.parceiro_pagamentos x
                                 where x.parceiro_id = p.id and x.tipo = 'comissao' and x.venda_id <> v.id);
    if primeira and inst_dia <= (p.aprovado_em at time zone 'America/Sao_Paulo')::date + cfg.bonus_boas_vindas_prazo_dias then
      insert into public.parceiro_pagamentos (parceiro_id, tipo, venda_id, competencia, valor, vence_em)
      values (p.id, 'bonus_boas_vindas', v.id, date_trunc('month', vence)::date, cfg.bonus_boas_vindas_valor, vence)
      on conflict do nothing;
      get diagnostics n = row_count;
      n_pag := n_pag + n;
    end if;
  end if;

  return jsonb_build_object('lancado', true, 'pontos_novos', n_pontos, 'pagamentos_novos', n_pag,
                            'forma', forma, 'multiplicador', mult, 'competencia', comp, 'vence_em', vence);
end;
$$;
-- Só o trigger (dono da função) e o service role chamam; a tela da etapa 2 usará um wrapper com checagem de perfil.
revoke execute on function public.parceiro_lancar_instalacao(uuid) from public, anon, authenticated;
grant execute on function public.parceiro_lancar_instalacao(uuid) to service_role;

create or replace function public.vendas_lanca_parceiro()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.parceiro_id is not null
     and new.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
     and new.nio_situacao = 'Concluído' and new.nio_venda_valida is true and new.instalado_em is not null then
    perform public.parceiro_lancar_instalacao(new.id);
  end if;
  return null;
end;
$$;
revoke execute on function public.vendas_lanca_parceiro() from public, anon, authenticated;
drop trigger if exists vendas_lanca_parceiro on public.vendas;
create trigger vendas_lanca_parceiro
  after insert or update of status, nio_situacao, nio_venda_valida, instalado_em on public.vendas
  for each row execute function public.vendas_lanca_parceiro();
