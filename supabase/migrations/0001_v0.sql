-- NIOGEN | supabase/migrations/0001_v0.sql | 03/11/2026
-- Migration v0 do Supabase Nio: usuários, configuração (planos e área de atuação),
-- vendas com as travas do contrato, eventos, contatos e as views do Funil e de Instalações.
-- Regras de origem: docs/CONTRATO_DHARMA_regras.md (Drive) e ESTUDO §4.1/§4.2.

-- ============================================================================
-- Tabelas
-- ============================================================================

create table public.usuarios (
  id         uuid primary key references auth.users (id) on delete cascade,
  nome       text not null,
  perfil     text not null check (perfil in ('admin', 'vendedor', 'backoffice')),
  cidade     text,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

create table public.config_planos (
  id                         bigint generated always as identity primary key,
  nome                       text not null,
  familia                    text,
  velocidade                 text,
  segmento                   text not null check (segmento in ('PF', 'MEI', 'NMEI')),
  preco                      numeric(10, 2),          -- null = preço ainda não informado pela Nio
  comissao                   numeric(10, 2),          -- Anexo II, biometria aprovada
  forma_pagamento_permitida  text[] not null default array['boleto', 'cartao', 'dacc'],
  vigencia_inicio            date not null default current_date,
  vigencia_fim               date,
  ativo                      boolean not null default true
);

-- Área de atuação (Anexo III). bairro null = cidade inteira.
create table public.config_area (
  id      bigint generated always as identity primary key,
  cidade  text not null,
  bairro  text,
  uf      text not null default 'MG',
  ativo   boolean not null default true
);

create table public.vendas (
  id                          uuid primary key default gen_random_uuid(),
  criado_em                   timestamptz not null default now(),
  criado_por                  uuid references public.usuarios (id) default auth.uid(),

  status                      text not null default '0_qualificado' check (status in (
                                '0_qualificado', '1_vendido', '2_aguardando_instalacao', '3_instalado',
                                '4_ativo_provisorio', '5_comissao_firme', 'saida')),
  motivo_saida                text,
  interesse_futuro_em         date,

  origem                      text not null check (origem in ('meta_ads', 'fila_vero', 'rua', 'indicacao', 'site', 'outro')),
  origem_ref                  text,                   -- ad_id, OS da fila, nome de quem indicou

  cliente_nome                text not null,
  cliente_cpf_cnpj            text,
  cliente_whatsapp            text,
  cliente_email               text,
  segmento                    text check (segmento in ('PF', 'MEI', 'NMEI')),

  cep                         text,
  logradouro                  text,
  numero                      text,
  complemento                 text,
  bairro                      text,
  cidade                      text,
  uf                          text,

  plano_id                    bigint references public.config_planos (id),
  forma_pagamento             text check (forma_pagamento in ('boleto', 'cartao', 'dacc')),
  vencimento_dia              int check (vencimento_dia between 1 and 31),

  comissao_prevista           numeric(10, 2),
  comissao_paga               numeric(10, 2),
  ciclo_pago                  text,
  estorno_previsto            numeric(10, 2) not null default 0,

  nio_pedido                  text unique,
  nio_contrato                text,
  nio_situacao                text,
  nio_pendencia_cod           text,
  nio_pendencia_desc          text,

  biometria_status            text check (biometria_status in ('agendada', 'aprovada', 'reprovada')),
  biometria_em                timestamptz,

  vendido_em                  timestamptz,
  agendamento_registrado_em   timestamptz,
  instalacao_agendada_para    timestamptz,
  instalado_em                timestamptz,
  ativado_em                  timestamptz,
  docs_entregues_em           timestamptz,

  vendedor_id                 uuid references public.usuarios (id),

  -- travas (gravadas no momento da venda, para auditoria). null = não verificada.
  trava_cobertura             boolean,
  trava_area                  boolean,
  trava_sem_produto_ativo     boolean,
  trava_sem_cancelamento_30d  boolean,
  trava_cpf_valido            boolean,
  trava_contato_confirmado    boolean
);

create index vendas_status_idx      on public.vendas (status);
create index vendas_vendedor_idx    on public.vendas (vendedor_id);
create index vendas_criado_por_idx  on public.vendas (criado_por);
create index vendas_cidade_idx      on public.vendas (cidade);
create index vendas_cep_numero_idx  on public.vendas (cep, numero);
create index vendas_cpf_idx         on public.vendas (cliente_cpf_cnpj);

-- Toda mudança de status e todo contato vira evento.
create table public.eventos_venda (
  id          bigint generated always as identity primary key,
  venda_id    uuid not null references public.vendas (id) on delete cascade,
  tipo        text not null,
  detalhe     jsonb not null default '{}'::jsonb,
  criado_em   timestamptz not null default now(),
  criado_por  uuid references public.usuarios (id) default auth.uid()
);

create index eventos_venda_venda_idx on public.eventos_venda (venda_id, criado_em);

create table public.contatos_cliente (
  id        bigint generated always as identity primary key,
  venda_id  uuid not null references public.vendas (id) on delete cascade,
  canal     text not null check (canal in ('whatsapp', 'ligacao', 'presencial')),
  direcao   text not null check (direcao in ('saida', 'entrada')),
  por       text not null check (por in ('mari', 'vendedor', 'cliente')),
  em        timestamptz not null default now(),
  resumo    text
);

create index contatos_cliente_venda_idx on public.contatos_cliente (venda_id, em);

-- ============================================================================
-- Perfil do usuário logado (usado pelas policies)
-- ============================================================================

create function public.meu_perfil()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select perfil from public.usuarios where id = auth.uid() and ativo
$$;

revoke execute on function public.meu_perfil() from public, anon;
grant execute on function public.meu_perfil() to authenticated;

-- Trava de recompra (Anexo I): o endereço ou o documento já têm venda ativa na base NIOGEN?
-- security definer para enxergar vendas de outros vendedores; devolve só sim/não, nenhum dado.
create function public.checar_duplicidade(p_cpf_cnpj text, p_cep text, p_numero text, p_ignorar uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'endereco', exists (
      select 1 from public.vendas
      where status <> 'saida' and id is distinct from p_ignorar
        and regexp_replace(coalesce(cep, ''), '\D', '', 'g') = regexp_replace(coalesce(p_cep, ''), '\D', '', 'g')
        and lower(btrim(coalesce(numero, ''))) = lower(btrim(coalesce(p_numero, '')))
        and coalesce(p_cep, '') <> ''),
    'documento', exists (
      select 1 from public.vendas
      where status <> 'saida' and id is distinct from p_ignorar
        and regexp_replace(coalesce(cliente_cpf_cnpj, ''), '\D', '', 'g') = regexp_replace(coalesce(p_cpf_cnpj, ''), '\D', '', 'g')
        and regexp_replace(coalesce(p_cpf_cnpj, ''), '\D', '', 'g') <> '')
  )
  where public.meu_perfil() is not null
$$;

revoke execute on function public.checar_duplicidade(text, text, text, uuid) from public, anon;
grant execute on function public.checar_duplicidade(text, text, text, uuid) to authenticated;

-- ============================================================================
-- Triggers de vendas
-- ============================================================================

-- BEFORE: travas de status e carimbos de data.
create function public.vendas_antes_status()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  mudou boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
begin
  if not mudou then
    return new;
  end if;

  -- Sem pedido do APP NiO PAP e biometria aprovada não existe venda (Anexo II).
  if new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')
     and (coalesce(btrim(new.nio_pedido), '') = '' or new.biometria_status is distinct from 'aprovada') then
    raise exception 'Venda bloqueada: para passar de Qualificado é obrigatório o nº do pedido do APP NiO PAP e a biometria aprovada.'
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

create trigger vendas_antes_status
  before insert or update of status on public.vendas
  for each row execute function public.vendas_antes_status();

-- AFTER: grava o evento. security definer para o evento sair mesmo quando quem
-- mudou o status não tem insert direto em eventos_venda.
create function public.vendas_registra_evento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'criada', jsonb_build_object('status', new.status, 'origem', new.origem), auth.uid());
  elsif new.status is distinct from old.status then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'status',
            jsonb_strip_nulls(jsonb_build_object('de', old.status, 'para', new.status, 'motivo', new.motivo_saida)),
            auth.uid());
  end if;

  if new.instalacao_agendada_para is not null
     and (tg_op = 'INSERT' or new.instalacao_agendada_para is distinct from old.instalacao_agendada_para) then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'agendamento',
            jsonb_build_object('para', new.instalacao_agendada_para,
                               'reagendamento', tg_op = 'UPDATE' and old.instalacao_agendada_para is not null),
            auth.uid());
  end if;

  return null;
end;
$$;

create trigger vendas_registra_evento
  after insert or update of status, instalacao_agendada_para on public.vendas
  for each row execute function public.vendas_registra_evento();

-- Contato registrado vira evento da venda.
create function public.contatos_registra_evento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (new.venda_id, 'contato',
          jsonb_strip_nulls(jsonb_build_object('canal', new.canal, 'direcao', new.direcao, 'por', new.por, 'resumo', new.resumo)),
          auth.uid());
  return null;
end;
$$;

create trigger contatos_registra_evento
  after insert on public.contatos_cliente
  for each row execute function public.contatos_registra_evento();

-- ============================================================================
-- Views (security_invoker: respeitam o RLS de quem consulta)
-- ============================================================================

-- Teto do contrato: 2 contatos/dia e 15/mês por cliente (só os de saída contam).
create view public.v_contatos_limite
with (security_invoker = true) as
select
  v.id as venda_id,
  count(c.id) filter (
    where (c.em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
  )::int as hoje,
  count(c.id) filter (
    where date_trunc('month', c.em at time zone 'America/Sao_Paulo') = date_trunc('month', now() at time zone 'America/Sao_Paulo')
  )::int as mes
from public.vendas v
left join public.contatos_cliente c on c.venda_id = v.id and c.direcao = 'saida'
group by v.id;

create view public.v_funil
with (security_invoker = true) as
select
  v.*,
  p.nome        as plano_nome,
  p.familia     as plano_familia,
  p.velocidade  as plano_velocidade,
  p.preco       as plano_preco,
  u.nome        as vendedor_nome,
  case
    when v.status = '1_vendido' and v.agendamento_registrado_em is null and v.vendido_em is not null
      then round((extract(epoch from now() - v.vendido_em) / 3600)::numeric, 2)
  end as horas_sem_agendamento,
  case
    when v.status = '0_qualificado' and v.biometria_status is distinct from 'aprovada'
      then round((extract(epoch from now() - v.criado_em) / 86400)::numeric, 2)
  end as dias_esperando_biometria,
  (v.instalado_em + interval '15 days')  as docs_prazo_em,
  (v.instalado_em + interval '180 days') as firme_em
from public.vendas v
left join public.config_planos p on p.id = v.plano_id
left join public.usuarios u on u.id = v.vendedor_id;

-- Instalações por tempo: 1_vendido / 2_aguardando / 3_instalado dos últimos 7 dias.
create view public.v_instalacoes
with (security_invoker = true) as
with base as (
  select
    f.*,
    (now() at time zone 'America/Sao_Paulo')::date                          as hoje_sp,
    (f.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date     as agendada_dia_sp
  from public.v_funil f
  where f.status in ('1_vendido', '2_aguardando_instalacao')
     or (f.status = '3_instalado' and f.instalado_em >= now() - interval '7 days')
)
select
  b.*,
  case
    when b.status = '3_instalado'                                     then 'concluida'
    when b.nio_pendencia_cod is not null                              then 'pendencia'
    when b.status = '1_vendido' or b.instalacao_agendada_para is null then 'agendar'
    when b.agendada_dia_sp < b.hoje_sp                                then 'pendencia'   -- data passou sem instalar
    when b.agendada_dia_sp = b.hoje_sp                                then 'hoje'
    when b.agendada_dia_sp = b.hoje_sp + 1                            then 'amanha'
    else 'semana'
  end as coluna
from base b;

grant select on public.v_contatos_limite, public.v_funil, public.v_instalacoes to authenticated;
revoke all on public.v_contatos_limite, public.v_funil, public.v_instalacoes from anon;

-- ============================================================================
-- RLS
-- admin: tudo · vendedor: só as vendas dele (vendedor_id ou criado_por)
-- backoffice: lê tudo, escreve vendas e eventos (e registra contato)
-- ============================================================================

alter table public.usuarios          enable row level security;
alter table public.config_planos     enable row level security;
alter table public.config_area       enable row level security;
alter table public.vendas            enable row level security;
alter table public.eventos_venda     enable row level security;
alter table public.contatos_cliente  enable row level security;

-- usuarios: todo usuário ativo lê (nomes no filtro e na venda); só admin escreve.
create policy usuarios_ler on public.usuarios
  for select to authenticated using (public.meu_perfil() is not null);
create policy usuarios_admin on public.usuarios
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

-- configuração: todos leem; só admin escreve.
create policy config_planos_ler on public.config_planos
  for select to authenticated using (public.meu_perfil() is not null);
create policy config_planos_admin on public.config_planos
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

create policy config_area_ler on public.config_area
  for select to authenticated using (public.meu_perfil() is not null);
create policy config_area_admin on public.config_area
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

-- vendas
create policy vendas_admin on public.vendas
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

create policy vendas_backoffice_ler on public.vendas
  for select to authenticated using (public.meu_perfil() = 'backoffice');
create policy vendas_backoffice_inserir on public.vendas
  for insert to authenticated with check (public.meu_perfil() = 'backoffice');
create policy vendas_backoffice_alterar on public.vendas
  for update to authenticated using (public.meu_perfil() = 'backoffice') with check (public.meu_perfil() = 'backoffice');

create policy vendas_vendedor_ler on public.vendas
  for select to authenticated
  using (public.meu_perfil() = 'vendedor' and (vendedor_id = auth.uid() or criado_por = auth.uid()));
create policy vendas_vendedor_inserir on public.vendas
  for insert to authenticated
  with check (public.meu_perfil() = 'vendedor' and (vendedor_id = auth.uid() or criado_por = auth.uid()));
create policy vendas_vendedor_alterar on public.vendas
  for update to authenticated
  using (public.meu_perfil() = 'vendedor' and (vendedor_id = auth.uid() or criado_por = auth.uid()))
  with check (public.meu_perfil() = 'vendedor' and (vendedor_id = auth.uid() or criado_por = auth.uid()));

-- eventos_venda: quem vê a venda vê os eventos (o subselect em vendas passa pelo RLS de vendas).
create policy eventos_admin on public.eventos_venda
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy eventos_ler on public.eventos_venda
  for select to authenticated
  using (public.meu_perfil() in ('backoffice', 'vendedor') and venda_id in (select id from public.vendas));
create policy eventos_inserir on public.eventos_venda
  for insert to authenticated
  with check (public.meu_perfil() in ('backoffice', 'vendedor') and venda_id in (select id from public.vendas));

-- contatos_cliente
create policy contatos_admin on public.contatos_cliente
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy contatos_ler on public.contatos_cliente
  for select to authenticated
  using (public.meu_perfil() in ('backoffice', 'vendedor') and venda_id in (select id from public.vendas));
create policy contatos_inserir on public.contatos_cliente
  for insert to authenticated
  with check (public.meu_perfil() in ('backoffice', 'vendedor') and venda_id in (select id from public.vendas));
