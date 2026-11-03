-- NIOGEN | supabase/migrations/0003_importacao_osab.sql | 03/11/2026
-- Importação do OSAB (relatório de pedidos/instalação da Nio), metas do mês, alertas do contrato e views do Painel.
-- Regras: docs/REFERENCIA_NIO_dicionario_dados_021126_2330.md §1 e prompt nº 2 (Drive).
-- O OSAB nunca rebaixa status e nunca apaga com vazio um campo que já tem valor.

-- ============================================================================
-- Tabelas
-- ============================================================================

create table public.importacoes (
  id            uuid primary key default gen_random_uuid(),
  tipo          text not null check (tipo in ('osab', 'fpd', 'churn', 'extrato', 'faturas')),
  arquivo_nome  text,
  dt_ref        date,
  linhas        int,
  aplicadas     int,
  ignoradas     int,
  resumo        jsonb not null default '{}'::jsonb,
  criado_em     timestamptz not null default now(),
  criado_por    uuid references public.usuarios (id) default auth.uid(),
  aplicado_em   timestamptz
);

create index importacoes_tipo_idx on public.importacoes (tipo, criado_em desc);

-- Snapshot do ÚLTIMO OSAB aplicado (aplicar_osab apaga o que não é do arquivo atual).
create table public.nio_osab (
  pedido                  text primary key,
  dt_ref                  date,
  produto                 text,
  uf                      text,
  localidade              text,
  celula                  text,
  segmento                text,
  velocidade              text,
  matricula_vendedor      text,
  situacao                text,
  data_agendamento        timestamptz,
  data_abertura           timestamptz,
  data_fechamento         timestamptz,
  cod_pendencia           text,
  desc_pendencia          text,
  numero_ba               text,
  venda_valida            boolean,
  meio_pagamento          text,
  campanha                text,
  flg_mei                 text,
  motivo_cancelamento     text,
  submotivo_cancelamento  text,
  classificacao           text,
  importacao_id           uuid references public.importacoes (id) on delete set null
);

create index nio_osab_importacao_idx on public.nio_osab (importacao_id);

create table public.config_metas (
  mes          date primary key check (mes = date_trunc('month', mes)::date),
  meta_vendas  int not null check (meta_vendas >= 0)
);

insert into public.config_metas (mes, meta_vendas) values
  ('2026-11-01', 30), ('2026-12-01', 50), ('2027-01-01', 70);

alter table public.vendas
  add column nio_osab_em timestamptz,          -- última vez que o OSAB tocou a venda
  add column nio_venda_valida boolean;         -- fg_venda_valida do OSAB

-- ============================================================================
-- RLS
-- ============================================================================

alter table public.importacoes   enable row level security;
alter table public.nio_osab      enable row level security;
alter table public.config_metas  enable row level security;

-- Histórico de importação: todos leem (o Funil mostra "OSAB de DD/MM aplicado"); só admin/backoffice gravam.
create policy importacoes_ler on public.importacoes
  for select to authenticated using (public.meu_perfil() is not null);
create policy importacoes_inserir on public.importacoes
  for insert to authenticated with check (public.meu_perfil() in ('admin', 'backoffice'));
create policy importacoes_alterar on public.importacoes
  for update to authenticated using (public.meu_perfil() in ('admin', 'backoffice')) with check (public.meu_perfil() in ('admin', 'backoffice'));

create policy nio_osab_operar on public.nio_osab
  for all to authenticated using (public.meu_perfil() in ('admin', 'backoffice')) with check (public.meu_perfil() in ('admin', 'backoffice'));

create policy config_metas_ler on public.config_metas
  for select to authenticated using (public.meu_perfil() is not null);
create policy config_metas_admin on public.config_metas
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

-- ============================================================================
-- Classificação do OSAB (a mesma regra roda na prévia do front: docs/assets/osab.js)
-- ============================================================================

-- Situações que tiram a venda do funil antes de instalar.
create function public.osab_cancelada(p_situacao text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_situacao in ('Cancelado', 'Em Cancelamento') or p_situacao like 'Reprovado%' or p_situacao like 'Draft-%', false)
$$;

-- Sinais de multa/estorno: venda inválida ou motivos que são cláusula do contrato.
create function public.osab_risco(p_valida boolean, p_desc_pendencia text, p_motivo text)
returns boolean
language sql
immutable
as $$
  select p_valida is false
      or upper(btrim(coalesce(p_desc_pendencia, ''))) in ('VENDA INDEVIDA', 'CANCELAMENTO ERRO DE DADOS DO CLIENTE')
      or coalesce(p_motivo, '') ~* '(venda indevida|venda errada|pedido duplicado|possui pedido fibra instalado no mesmo endere)'
$$;

-- ============================================================================
-- aplicar_osab: casa nio_osab × vendas pelo nº do pedido e atualiza o funil
-- ============================================================================

create function public.aplicar_osab(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  imp         public.importacoes%rowtype;
  r           record;
  v_concl     boolean;
  v_cancel    boolean;
  v_risco     boolean;
  v_pcod      text;
  v_pdesc     text;
  v_novo      text;
  v_mudou     boolean;
  n_atual     int := 0;
  n_status    int := 0;
  n_saidas    int := 0;
  n_pend      int := 0;
  n_inval     int := 0;
  n_sem       int := 0;
  sem         jsonb;
  v_resumo    jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice aplicam importação.' using errcode = '42501';
  end if;

  select * into imp from public.importacoes where id = p_importacao_id for update;
  if not found then
    raise exception 'Importação % não encontrada.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.tipo <> 'osab' then
    raise exception 'Importação % não é OSAB.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.aplicado_em is not null then
    raise exception 'Esta importação já foi aplicada em %.', imp.aplicado_em using errcode = 'P0001';
  end if;

  -- Wipe-and-replace: o snapshot passa a ser só o arquivo atual.
  delete from public.nio_osab where importacao_id is distinct from p_importacao_id;

  for r in
    select o.*,
           v.id                        as venda_id,
           v.status                    as v_status,
           v.nio_situacao              as v_situacao,
           v.nio_pendencia_cod         as v_pcod,
           v.nio_pendencia_desc        as v_pdesc,
           v.nio_venda_valida          as v_valida
    from public.nio_osab o
    join public.vendas v on v.nio_pedido = o.pedido
    where o.importacao_id = p_importacao_id
  loop
    n_atual  := n_atual + 1;
    v_concl  := r.situacao = 'Concluído' and r.venda_valida is true;
    v_cancel := public.osab_cancelada(r.situacao);
    v_risco  := public.osab_risco(r.venda_valida, r.desc_pendencia, concat_ws(' ', r.motivo_cancelamento, r.submotivo_cancelamento));

    -- Pendência: vazio no OSAB = mantém; OK / 00 / N/A = resolvida; resto = pendência da Nio.
    if coalesce(btrim(r.cod_pendencia), '') = '' and coalesce(btrim(r.desc_pendencia), '') = '' then
      v_pcod := r.v_pcod;
      v_pdesc := r.v_pdesc;
    elsif upper(btrim(coalesce(r.desc_pendencia, ''))) in ('OK', 'N/A') or btrim(coalesce(r.cod_pendencia, '')) in ('0', '00') then
      v_pcod := null;
      v_pdesc := null;
    else
      v_pcod := nullif(btrim(r.cod_pendencia), '');
      v_pdesc := nullif(btrim(r.desc_pendencia), '');
    end if;

    update public.vendas set
      nio_situacao             = coalesce(nullif(btrim(r.situacao), ''), nio_situacao),
      nio_pendencia_cod        = v_pcod,
      nio_pendencia_desc       = v_pdesc,
      nio_venda_valida         = coalesce(r.venda_valida, nio_venda_valida),
      instalacao_agendada_para = coalesce(instalacao_agendada_para, r.data_agendamento),
      instalado_em             = case when v_concl then coalesce(instalado_em, r.data_fechamento) else instalado_em end,
      ativado_em               = case when v_concl then coalesce(ativado_em, r.data_fechamento) else ativado_em end,
      nio_osab_em              = now()
    where id = r.venda_id;

    -- Status: só avança. Concluído/válida leva 2 → 3 → 4; cancelamento leva 1–2 → saída.
    v_novo := null;
    if v_concl and r.v_status in ('2_aguardando_instalacao', '3_instalado') then
      if r.v_status = '2_aguardando_instalacao' then
        update public.vendas set status = '3_instalado' where id = r.venda_id;
      end if;
      update public.vendas set status = '4_ativo_provisorio' where id = r.venda_id;
      v_novo := '4_ativo_provisorio';
    elsif v_cancel and r.v_status in ('1_vendido', '2_aguardando_instalacao') then
      update public.vendas set
        status = 'saida',
        motivo_saida = 'Nio: ' || coalesce(nullif(btrim(r.motivo_cancelamento), ''), r.situacao)
                       || coalesce(' · ' || nullif(btrim(r.submotivo_cancelamento), ''), '')
      where id = r.venda_id;
      v_novo := 'saida';
      n_saidas := n_saidas + 1;
    end if;
    if v_novo is not null then n_status := n_status + 1; end if;
    if v_novo is null and v_pcod is not null and r.v_status in ('1_vendido', '2_aguardando_instalacao') then
      n_pend := n_pend + 1;
    end if;
    if v_risco then n_inval := n_inval + 1; end if;

    -- Evento só quando algo mudou (reimportar o mesmo arquivo não enche a linha do tempo).
    v_mudou := v_novo is not null
            or r.situacao is distinct from r.v_situacao
            or v_pcod is distinct from r.v_pcod
            or r.venda_valida is distinct from r.v_valida;
    if v_mudou then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (r.venda_id, 'osab', jsonb_strip_nulls(jsonb_build_object(
        'situacao', r.situacao, 'pendencia_cod', v_pcod, 'pendencia_desc', v_pdesc, 'venda_valida', r.venda_valida,
        'de', case when v_novo is not null then r.v_status end, 'para', v_novo,
        'dt_ref', r.dt_ref, 'importacao_id', p_importacao_id)), auth.uid());
      if v_risco then
        insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
        values (r.venda_id, 'osab_venda_invalida', jsonb_strip_nulls(jsonb_build_object(
          'venda_valida', r.venda_valida, 'pendencia_desc', r.desc_pendencia,
          'motivo', nullif(concat_ws(' · ', r.motivo_cancelamento, r.submotivo_cancelamento), ''),
          'importacao_id', p_importacao_id)), auth.uid());
      end if;
    end if;
  end loop;

  -- Pedidos que a Nio enxerga e o NIOGEN não.
  select count(*), coalesce(jsonb_agg(s.pedido order by s.pedido) filter (where s.n <= 1000), '[]'::jsonb)
    into n_sem, sem
  from (
    select o.pedido, row_number() over (order by o.pedido) as n
    from public.nio_osab o
    where o.importacao_id = p_importacao_id
      and not exists (select 1 from public.vendas v where v.nio_pedido = o.pedido)
  ) s;

  v_resumo := coalesce(imp.resumo, '{}'::jsonb) || jsonb_build_object(
    'atualizadas', n_atual, 'mudaram_status', n_status, 'saidas', n_saidas, 'pendencias', n_pend,
    'invalidas', n_inval, 'sem_venda', n_sem, 'sem_venda_pedidos', sem);

  update public.importacoes set
    aplicadas   = n_atual,
    ignoradas   = coalesce(ignoradas, 0) + n_sem,
    resumo      = v_resumo,
    aplicado_em = now()
  where id = p_importacao_id;

  return v_resumo;
end;
$$;

revoke execute on function public.aplicar_osab(uuid) from public, anon;
grant execute on function public.aplicar_osab(uuid) to authenticated;

-- ============================================================================
-- Views: v_funil e v_instalacoes recriadas (v.* passa a trazer as colunas novas;
-- concluídas agora incluem o 4, porque o OSAB leva 2 → 4 na mesma passada)
-- ============================================================================

drop view public.v_instalacoes;
drop view public.v_funil;

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

create view public.v_instalacoes
with (security_invoker = true) as
with base as (
  select
    f.*,
    (now() at time zone 'America/Sao_Paulo')::date                          as hoje_sp,
    (f.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date     as agendada_dia_sp
  from public.v_funil f
  where f.status in ('1_vendido', '2_aguardando_instalacao')
     or (f.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and f.instalado_em >= now() - interval '7 days')
)
select
  b.*,
  case
    when b.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then 'concluida'
    when b.nio_pendencia_cod is not null or b.nio_pendencia_desc is not null  then 'pendencia'
    when b.status = '1_vendido' or b.instalacao_agendada_para is null         then 'agendar'
    when b.agendada_dia_sp < b.hoje_sp                                        then 'pendencia'   -- data passou sem instalar
    when b.agendada_dia_sp = b.hoje_sp                                        then 'hoje'
    when b.agendada_dia_sp = b.hoje_sp + 1                                    then 'amanha'
    else 'semana'
  end as coluna
from base b;

-- Barra de alertas do Funil e "Agora · o que precisa de alguém" do Painel.
create view public.v_alertas_contrato
with (security_invoker = true) as
select f.id as venda_id, f.cliente_nome, 'venda_invalida'::text as tipo, 'bad'::text as nivel,
       'Nio marcou venda inválida' || coalesce(' · ' || f.nio_pendencia_desc, '') as texto,
       'venda.html?id=' || f.id as link, f.nio_osab_em as desde, null::numeric as horas
from public.v_funil f
where f.nio_venda_valida is false and f.status <> '5_comissao_firme'
union all
select f.id, f.cliente_nome, 'risco_contrato', 'bad',
       'Risco de multa/estorno · ' || coalesce(f.nio_pendencia_desc, f.motivo_saida),
       'venda.html?id=' || f.id, f.nio_osab_em, null
from public.v_funil f
where f.nio_venda_valida is not false
  and public.osab_risco(null, f.nio_pendencia_desc, f.motivo_saida)
union all
select f.id, f.cliente_nome, 'sem_agendamento', 'bad',
       'vendida há ' || floor(f.horas_sem_agendamento)::int || 'h'
         || lpad((round((f.horas_sem_agendamento - floor(f.horas_sem_agendamento)) * 60))::int::text, 2, '0') || ' sem agendamento',
       'instalacoes.html', f.vendido_em, f.horas_sem_agendamento
from public.v_funil f
where f.horas_sem_agendamento > 4
union all
select f.id, f.cliente_nome, 'docs', case when f.docs_prazo_em < now() then 'bad' else 'warn' end,
       case when f.docs_prazo_em < now() then 'documentos à Nio atrasados desde ' else 'documentos à Nio até ' end
         || to_char(f.docs_prazo_em at time zone 'America/Sao_Paulo', 'DD/MM'),
       'venda.html?id=' || f.id, f.instalado_em, null
from public.v_funil f
where f.docs_entregues_em is null and f.docs_prazo_em is not null
  and f.docs_prazo_em <= now() + interval '3 days'
  and f.status in ('3_instalado', '4_ativo_provisorio');

-- ============================================================================
-- Painel
-- ============================================================================

-- Um registro por mês (meses com venda ou com meta). "Vendida" = status 1–5 com vendido_em no mês
-- e sem venda inválida da Nio (inválida não conta para meta nem comissão).
create view public.v_painel_mes
with (security_invoker = true) as
with base as (
  select
    f.*,
    date_trunc('month', f.vendido_em at time zone 'America/Sao_Paulo')::date as mes_venda,
    (f.vendido_em at time zone 'America/Sao_Paulo')::date                    as dia_venda,
    date_trunc('month', f.instalado_em at time zone 'America/Sao_Paulo')::date as mes_inst,
    (f.instalado_em at time zone 'America/Sao_Paulo')::date                  as dia_inst,
    f.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')    as instalada,
    public.osab_risco(f.nio_venda_valida, f.nio_pendencia_desc, f.motivo_saida) as em_risco
  from public.v_funil f
),
vend as (
  select * from base
  where vendido_em is not null
    and status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')
    and nio_venda_valida is not false
),
saidas as (
  select e.venda_id, date_trunc('month', e.criado_em at time zone 'America/Sao_Paulo')::date as mes
  from public.eventos_venda e
  where (e.tipo = 'status' and e.detalhe ->> 'para' = 'saida')
     or (e.tipo = 'criada' and e.detalhe ->> 'status' = 'saida')
),
meses as (
  select mes_venda as mes from vend
  union
  select mes from public.config_metas
)
select
  m.mes,
  cm.meta_vendas,
  (select count(*) from vend where mes_venda = m.mes)::int                         as vendidas,
  (select count(*) from vend where mes_venda = m.mes and instalada)::int           as instaladas,
  (select count(*) from vend where mes_venda = m.mes and not instalada)::int       as aguardando,
  (select count(*) from base
    where status in ('4_ativo_provisorio', '5_comissao_firme')
      and coalesce(ativado_em, instalado_em) < ((m.mes + interval '1 month')::timestamp at time zone 'America/Sao_Paulo'))::int as ativas_carteira,
  (select count(distinct s.venda_id) from saidas s where s.mes = m.mes)::int       as saidas,
  (select b.motivo_saida from saidas s join base b on b.id = s.venda_id
    where s.mes = m.mes and b.motivo_saida is not null
    group by b.motivo_saida order by count(*) desc, b.motivo_saida limit 1)        as saidas_motivo_top,
  (select coalesce(sum(comissao_prevista), 0) from vend where mes_venda = m.mes)    as comissao_prevista,
  (select coalesce(sum(comissao_prevista), 0) from vend where mes_venda = m.mes and instalada) as comissao_instalada,
  (select coalesce(sum(comissao_prevista), 0) from base where mes_venda = m.mes and em_risco and status <> 'saida') as comissao_em_risco,
  (select coalesce(jsonb_object_agg(origem, n), '{}'::jsonb)
     from (select origem, count(*) n from vend where mes_venda = m.mes group by origem) x)   as por_origem,
  (select coalesce(jsonb_object_agg(coalesce(cidade, '—'), n), '{}'::jsonb)
     from (select cidade, count(*) n from vend where mes_venda = m.mes group by cidade) x)   as por_cidade,
  (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'vendidas', n, 'instaladas', i) order by n desc, nome), '[]'::jsonb)
     from (select coalesce(vendedor_nome, '—') nome, count(*) n, count(*) filter (where instalada) i
           from vend where mes_venda = m.mes group by 1) x)                                  as por_vendedor,
  (select coalesce(jsonb_object_agg(coalesce(plano_nome, '—'), n), '{}'::jsonb)
     from (select plano_nome, count(*) n from vend where mes_venda = m.mes group by plano_nome) x) as por_plano,
  (select coalesce(jsonb_object_agg(coalesce(forma_pagamento, '—'), n), '{}'::jsonb)
     from (select forma_pagamento, count(*) n from vend where mes_venda = m.mes group by forma_pagamento) x) as por_forma,
  (select coalesce(jsonb_object_agg(dia_venda::text, n), '{}'::jsonb)
     from (select dia_venda, count(*) n from vend where mes_venda = m.mes group by dia_venda) x) as por_dia_vendas,
  (select coalesce(jsonb_object_agg(dia_inst::text, n), '{}'::jsonb)
     from (select dia_inst, count(*) n from base where mes_inst = m.mes and instalada group by dia_inst) x) as por_dia_instaladas
from meses m
left join public.config_metas cm on cm.mes = m.mes;

create view public.v_painel_hoje
with (security_invoker = true) as
with f as (
  select v.*, (now() at time zone 'America/Sao_Paulo')::date as hoje
  from public.v_funil v
)
select
  max(hoje) as hoje,
  count(*) filter (where (vendido_em at time zone 'America/Sao_Paulo')::date = hoje
                     and status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')
                     and nio_venda_valida is not false)::int                                                      as vendas_hoje,
  count(*) filter (where (instalado_em at time zone 'America/Sao_Paulo')::date = hoje)::int                       as instaladas_hoje,
  count(*) filter (where (biometria_em at time zone 'America/Sao_Paulo')::date = hoje
                     and biometria_status in ('agendada', 'aprovada'))::int                                       as biometrias_hoje,
  count(*) filter (where status = '0_qualificado')::int                                                           as qualificados,
  count(*) filter (where status = '0_qualificado' and biometria_status is distinct from 'aprovada')::int         as esperando_biometria,
  count(*) filter (where horas_sem_agendamento > 4)::int                                                          as sem_agendamento_4h,
  count(*) filter (where (instalacao_agendada_para at time zone 'America/Sao_Paulo')::date = hoje
                     and instalado_em is null and status in ('1_vendido', '2_aguardando_instalacao'))::int        as instalacoes_agendadas_hoje,
  count(*) filter (where status in ('1_vendido', '2_aguardando_instalacao')
                     and (nio_pendencia_cod is not null or nio_pendencia_desc is not null))::int                  as pendencias_osab,
  mode() within group (order by nio_pendencia_desc) filter (where status in ('1_vendido', '2_aguardando_instalacao')
                     and nio_pendencia_desc is not null)                                                          as pendencia_top
from f;

grant select on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje to authenticated;
revoke all on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje from anon;
