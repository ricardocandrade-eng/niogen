-- ============================================================================
-- NÃO APLICAR — aguarda aprovação do Ricardo e o 1º arquivo real
-- ============================================================================
-- NIOGEN | supabase/rascunhos/0022_adimplencia_conciliacao_RASCUNHO.sql | 05/11/2026 — Claude Code (prompt nº 14b)
-- Resumo: tabelas de faturas (FPD + extrato mensal das faturas 4–10) e do extrato quinzenal (aba PEDIDO + aba LINHA_A_LINHA),
-- contestações, views v_adimplencia / v_conciliacao / v_conciliacao_ciclos (lidas por docs/adimplencia.html e
-- docs/conciliacao.html) e a importação com prévia no mesmo padrão do OSAB (o front grava as linhas com importacao_id,
-- mostra a prévia, e a RPC aplicar_* liga às vendas e marca a importação como aplicada).
--
-- Fora de supabase/migrations/ de propósito: o `db push` não enxerga esta pasta. Quando aprovado, vira
-- supabase/migrations/00NN_adimplencia_conciliacao.sql (número livre no dia — 0020 e 0021 já existem; o prompt pedia "0020").
--
-- Fontes das colunas: referencia-nio/FPD_PP_28-09.xlsx, referencia-nio/202609_2Q_PEDIDOS_X_LINHA_A_LINHA_…xlsx e
-- docs/REFERENCIA_NIO_dicionario_dados_021126_2330.md §2 e §4. São EXEMPLOS anonimizados (IDs mascarados).
-- Toda coluna que só o arquivo real confirma está marcada com  -- CONFERIR.
--
-- Regras do contrato que este SQL respeita (docs/CONTRATO_DHARMA_regras.md):
--   * Inadimplência NÃO estorna comissão: faturas só alimentam a adimplência (M-10) e o indicador FPD. Nada aqui mexe em
--     comissao_prevista nem em estorno_previsto.
--   * M-10 = 10º mês ativo, adimplente (nenhuma fatura em aberto > 15 d do vencimento) e sem downgrade, apurado no 11º mês.
--   * Apuração quinzenal; pedido da Nio → NF da Dharma → processamento em até 10 dias úteis.
--   * Contestação em até 120 dias corridos do fato gerador (aqui: a ativação — CONFERIR com o Rogério).
--   * Recompra = multa de R$ 500 (não é estorno); fraude = estorno de 100 %.
-- ============================================================================

begin;

-- ============================================================================
-- 1. Ciclo quinzenal: '2026-10-2Q' (id ordenável) ↔ '2QOUT26' (rótulo da Nio)
-- ============================================================================

create or replace function public.nio_ciclo_de(p_dia date)
returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(p_dia, 'YYYY-MM-') || case when extract(day from p_dia) <= 15 then '1Q' else '2Q' end;
$$;

-- '2QSET26' → '2026-09-2Q'. Meses no padrão da Nio (JAN…DEZ). CONFERIR: o 1º arquivo real usa o mesmo formato em CICLO.
create or replace function public.nio_ciclo_do_rotulo(p_rotulo text)
returns text
language sql
immutable
set search_path = ''
as $$
  select '20' || substr(r, 6, 2) || '-'
         || lpad((array_position(array['JAN','FEV','MAR','ABR','MAI','JUN','JUL','AGO','SET','OUT','NOV','DEZ'], substr(r, 3, 3)))::text, 2, '0')
         || '-' || substr(r, 1, 2)
  from (select upper(btrim(p_rotulo)) as r) x
  where upper(btrim(p_rotulo)) ~ '^[12]Q[A-Z]{3}[0-9]{2}$';
$$;

-- ============================================================================
-- 2. Faturas (FPD = faturas 1–3; extrato mensal = faturas 4–10, ainda não recebido)
-- ============================================================================
-- 1 linha por fatura emitida. A importação substitui a fatura (id_contrato, nr_fatura) pela versão mais nova.

create table public.nio_faturas (
  id                 bigint generated always as identity primary key,
  importacao_id      uuid references public.importacoes (id) on delete set null,
  venda_id           uuid references public.vendas (id) on delete set null,   -- ligado no aplicar_faturas
  id_contrato        text not null,        -- FPD.ID_CONTRATO = vendas.nio_contrato                         -- CONFERIR
  nr_ordem           text,                 -- FPD.nr_ordem = vendas.nio_pedido (= OSAB.PEDIDO)             -- CONFERIR
  nr_fatura          int  not null check (nr_fatura between 1 and 60),   -- FPD.NR_FATURA (1ª, 2ª…)          -- CONFERIR (FPD só traz 1–3)
  indicador          text,                 -- FPD / SPD / TPD
  mes_emissao        date,                 -- FPD.MES_EMISSAO (formato a confirmar)                         -- CONFERIR
  dt_vencimento      date,                 -- FPD.DT_VENC_ORIG
  dt_pagamento       date,                 -- FPD.DT_PAGAMENTO (vazio = não paga)
  dias_atraso        int,                  -- FPD.NR_DIAS_ATRASO (o NIOGEN recalcula pela data; guardado para conferir)
  status_fatura      text,                 -- FPD.DS_STATUS_FATURA: Paga · Aguardando_arrecadacao · Paga_aguardando_repasse · Baixa_por_acordo · Ajustada · Erro_nao_recobravel · Cancelada · Zerada
  sit_fatura         text,                 -- FPD.DS_SIT_FATURA: FECHADA / ABERTA
  faixa              text,                 -- FPD.FAIXA (aging da Nio)
  flg_fpd            boolean,              -- FPD.FLG_FPD
  valor              numeric(10, 2),       -- não aparece no FPD de exemplo                                    -- CONFERIR
  ds_pgto            text,                 -- forma de pagamento
  dt_ativacao        date,                 -- FPD.dt_ativacao_particao
  importado_em       timestamptz not null default now(),
  unique (id_contrato, nr_fatura)
);
create index nio_faturas_venda_idx on public.nio_faturas (venda_id, nr_fatura);
create index nio_faturas_importacao_idx on public.nio_faturas (importacao_id);

comment on table public.nio_faturas is
  'Faturas por contrato (FPD + extrato mensal 4–10). Só adimplência/M-10 e indicador FPD: inadimplência não estorna comissão.';

-- Situação simplificada que o front usa nas bolinhas. CONFERIR com o 1º arquivo: em qual status a Nio considera "paga".
create or replace function public.nio_fatura_situacao(p_status text, p_pagamento date)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_pagamento is not null then 'paga'
    when p_status in ('Paga', 'Paga_aguardando_repasse', 'Baixa_por_acordo') then 'paga'
    when p_status in ('Zerada', 'Cancelada', 'Ajustada', 'Erro_nao_recobravel') then 'sem_cobranca'   -- CONFERIR
    else 'aberta'
  end;
$$;

-- ============================================================================
-- 3. Extrato quinzenal: aba PEDIDO (1 por ciclo) e aba LINHA_A_LINHA (1 por evento de comissão)
-- ============================================================================

create table public.nio_extrato_pedidos (
  ciclo              text primary key,     -- '2026-09-2Q' (de CICLO = '2QSET26')
  ciclo_nio          text not null,        -- PEDIDO.CICLO como veio
  importacao_id      uuid references public.importacoes (id) on delete set null,
  fornecedor         text,                 -- código SAP da Dharma
  documento_compras  text,                 -- PEDIDO."DOCUMENTO DE COMPRAS" (o pedido SAP contra o qual sai a NF)
  texto_breve        text,
  valor_pedido       numeric(12, 2),       -- PEDIDO.VALOR = soma da linha a linha                            -- CONFERIR (bateu no exemplo: 31.600)
  cnpj               text,
  filial             text,
  status_pedido      text,                 -- PEDIDO.STATUS / STATUS_AJUSTADO
  numero_nf          text,
  chave_nf           text,
  num_pipefy         text,
  previsao_pg        date,                 -- PEDIDO."PREVISÃO_PG"                                             -- CONFERIR formato
  dt_compensacao     date,                 -- PEDIDO."DT_COMPENSAÇÃO"
  importado_em       timestamptz not null default now()
);

create table public.nio_extrato_linhas (
  id                 bigint generated always as identity primary key,
  importacao_id      uuid references public.importacoes (id) on delete set null,
  ciclo              text not null,        -- de ANO + MES + QUINZENA ('2026','SET','2Q')
  ciclo_complementar boolean not null default false,   -- CICLO_COMPLEMENTAR ('SIM'/'NAO')                  -- CONFERIR
  venda_id           uuid references public.vendas (id) on delete set null,   -- ligado no aplicar_extrato
  evento             text not null,        -- COMISSAO · ESTORNO · BONUS · (MULTA?)                            -- CONFERIR como vem a multa de recompra
  sub_evento         text,                 -- COMISSAO_ATIVACAO · INCONSISTENCIA_CADASTRAL · SINERGIA · TRANSICAO? · NMEI?  -- CONFERIR nomes de transição/NMEI
  familia            text,
  produto            text,
  oferta             text,
  metodo_pagamento   text,
  contrato           text,                 -- = vendas.nio_contrato                                            -- CONFERIR (chave do pedido)
  num_os_pedido      text,                 -- NUM_OS_PEDIDO_SIEBEL = vendas.nio_pedido (= OSAB.PEDIDO)         -- CONFERIR (chave do pedido)
  data_atv           date,                 -- DATA_ATV (serial Excel, base 1899-12-30 — o front converte)
  comissao           numeric(10, 2) not null,   -- negativo = estorno / multa
  recompra           boolean,              -- RECOMPRA ('-' = não)                                              -- CONFERIR valor quando é recompra
  tipo_cliente       text,                 -- PF / MEI / NMEI
  ausente_base       boolean,              -- AUSENTE_BASE ('S'/'N')
  importado_em       timestamptz not null default now()
);
create index nio_extrato_linhas_ciclo_idx on public.nio_extrato_linhas (ciclo);
create index nio_extrato_linhas_venda_idx on public.nio_extrato_linhas (venda_id);
create index nio_extrato_linhas_importacao_idx on public.nio_extrato_linhas (importacao_id);

-- ============================================================================
-- 4. Contestações (só registro interno; o envio à Nio é por fora)
-- ============================================================================

create table public.nio_contestacoes (
  id            bigint generated always as identity primary key,
  criado_em     timestamptz not null default now(),
  criado_por    uuid references public.usuarios (id) default auth.uid(),
  ciclo         text not null,
  venda_id      uuid references public.vendas (id) on delete set null,
  nio_pedido    text,
  nio_contrato  text,
  valor         numeric(10, 2) not null check (valor > 0),
  motivo        text not null check (motivo in ('valor_tabela', 'bonus_nao_pago', 'adicional_nao_pago', 'nao_veio',
                                                 'estorno_indevido', 'multa_indevida', 'outro')),
  descricao     text,
  prazo_em      date,                       -- fato gerador + 120 d (gravado na abertura)
  status        text not null default 'aberta' check (status in ('aberta', 'enviada', 'aceita', 'recusada')),
  resolvida_em  timestamptz
);
create index nio_contestacoes_venda_idx on public.nio_contestacoes (venda_id, ciclo);

-- ============================================================================
-- 5. RLS — só admin e backoffice (as telas também são só deles)
-- ============================================================================

alter table public.nio_faturas          enable row level security;
alter table public.nio_extrato_pedidos  enable row level security;
alter table public.nio_extrato_linhas   enable row level security;
alter table public.nio_contestacoes     enable row level security;

create policy nio_faturas_operar on public.nio_faturas
  for all to authenticated using (public.meu_perfil() in ('admin', 'backoffice')) with check (public.meu_perfil() in ('admin', 'backoffice'));
create policy nio_extrato_pedidos_operar on public.nio_extrato_pedidos
  for all to authenticated using (public.meu_perfil() in ('admin', 'backoffice')) with check (public.meu_perfil() in ('admin', 'backoffice'));
create policy nio_extrato_linhas_operar on public.nio_extrato_linhas
  for all to authenticated using (public.meu_perfil() in ('admin', 'backoffice')) with check (public.meu_perfil() in ('admin', 'backoffice'));
create policy nio_contestacoes_ler on public.nio_contestacoes
  for select to authenticated using (public.meu_perfil() in ('admin', 'backoffice'));
create policy nio_contestacoes_inserir on public.nio_contestacoes
  for insert to authenticated with check (public.meu_perfil() in ('admin', 'backoffice'));
create policy nio_contestacoes_alterar on public.nio_contestacoes
  for update to authenticated using (public.meu_perfil() in ('admin', 'backoffice')) with check (public.meu_perfil() in ('admin', 'backoffice'));
-- sem delete: contestação registrada não some (muda de status).

-- ============================================================================
-- 6. Importação com prévia (padrão OSAB)
-- ============================================================================
-- Fluxo no front (Configurações › Importação, a fazer): lê o .xlsx → cria importacoes (tipo 'faturas' ou 'extrato',
-- aplicado_em null) → grava as linhas nas tabelas acima com importacao_id → mostra a prévia (quantas ligam a venda,
-- quantas não, soma do ciclo × VALOR do pedido) → "Aplicar" chama a RPC. Importação não aplicada pode ser descartada
-- (delete das linhas com aquele importacao_id). O tipo 'faturas' e 'extrato' já existem no check de importacoes.

create or replace function public.aplicar_faturas(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  imp      public.importacoes%rowtype;
  n_lig    int;
  n_sem    int;
  v_resumo jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice aplicam importação.' using errcode = '42501';
  end if;
  select * into imp from public.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'Importação % não encontrada.', p_importacao_id using errcode = 'P0001'; end if;
  if imp.tipo not in ('fpd', 'faturas') then raise exception 'Importação % não é de faturas.', p_importacao_id using errcode = 'P0001'; end if;
  if imp.aplicado_em is not null then raise exception 'Esta importação já foi aplicada em %.', imp.aplicado_em using errcode = 'P0001'; end if;

  -- Liga cada fatura à venda: primeiro pelo contrato, depois pelo pedido.                                     -- CONFERIR chave
  update public.nio_faturas f set venda_id = v.id
    from public.vendas v
   where f.importacao_id = p_importacao_id and f.venda_id is null
     and ((v.nio_contrato is not null and v.nio_contrato = f.id_contrato) or (v.nio_pedido is not null and v.nio_pedido = f.nr_ordem));

  select count(*) filter (where venda_id is not null), count(*) filter (where venda_id is null)
    into n_lig, n_sem from public.nio_faturas where importacao_id = p_importacao_id;

  -- Grava o contrato na venda quando ela ainda não tem (só preenche vazio; nunca sobrescreve).
  update public.vendas v set nio_contrato = f.id_contrato
    from public.nio_faturas f
   where f.importacao_id = p_importacao_id and f.venda_id = v.id and v.nio_contrato is null;

  v_resumo := jsonb_build_object('ligadas', n_lig, 'sem_venda', n_sem);
  update public.importacoes set aplicadas = n_lig, ignoradas = n_sem, resumo = resumo || v_resumo, aplicado_em = now()
   where id = p_importacao_id;
  return v_resumo;
end;
$$;

create or replace function public.aplicar_extrato(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  imp      public.importacoes%rowtype;
  n_lig    int;
  n_sem    int;
  v_ciclos text[];
  v_resumo jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice aplicam importação.' using errcode = '42501';
  end if;
  select * into imp from public.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'Importação % não encontrada.', p_importacao_id using errcode = 'P0001'; end if;
  if imp.tipo <> 'extrato' then raise exception 'Importação % não é extrato.', p_importacao_id using errcode = 'P0001'; end if;
  if imp.aplicado_em is not null then raise exception 'Esta importação já foi aplicada em %.', imp.aplicado_em using errcode = 'P0001'; end if;

  select array_agg(distinct ciclo) into v_ciclos from public.nio_extrato_linhas where importacao_id = p_importacao_id;

  -- Reimportar o mesmo ciclo substitui as linhas antigas dele (o extrato da Nio é a verdade contábil).
  delete from public.nio_extrato_linhas
   where ciclo = any (v_ciclos) and importacao_id is distinct from p_importacao_id and not ciclo_complementar;

  update public.nio_extrato_linhas l set venda_id = v.id
    from public.vendas v
   where l.importacao_id = p_importacao_id and l.venda_id is null
     and ((v.nio_contrato is not null and v.nio_contrato = l.contrato) or (v.nio_pedido is not null and v.nio_pedido = l.num_os_pedido));   -- CONFERIR chave

  select count(*) filter (where venda_id is not null), count(*) filter (where venda_id is null)
    into n_lig, n_sem from public.nio_extrato_linhas where importacao_id = p_importacao_id;

  -- comissao_paga / ciclo_pago da venda = soma de tudo que a Nio já lançou para ela (comissão, bônus, estornos, multas).
  update public.vendas v set
      comissao_paga = s.total,
      ciclo_pago    = s.ultimo_ciclo
    from (select venda_id, sum(comissao) as total, max(ciclo) as ultimo_ciclo
            from public.nio_extrato_linhas where venda_id is not null group by venda_id) s
   where s.venda_id = v.id
     and v.id in (select venda_id from public.nio_extrato_linhas where importacao_id = p_importacao_id and venda_id is not null);

  v_resumo := jsonb_build_object('ligadas', n_lig, 'sem_venda', n_sem, 'ciclos', to_jsonb(v_ciclos));
  update public.importacoes set aplicadas = n_lig, ignoradas = n_sem, resumo = resumo || v_resumo, aplicado_em = now()
   where id = p_importacao_id;
  return v_resumo;
end;
$$;

revoke execute on function public.aplicar_faturas(uuid) from public, anon;
revoke execute on function public.aplicar_extrato(uuid) from public, anon;
grant execute on function public.aplicar_faturas(uuid) to authenticated;
grant execute on function public.aplicar_extrato(uuid) to authenticated;

-- ============================================================================
-- 7. Views lidas pelas telas (security_invoker: valem as RLS de quem lê)
-- ============================================================================

-- Adimplência: 1 linha por venda ativa (status 4 e 5 = "Ativo"), faturas em jsonb. Formato que docs/adimplencia.html lê.
create or replace view public.v_adimplencia
with (security_invoker = true) as
select v.id                     as venda_id,
       v.cliente_nome,
       v.cliente_cpf_cnpj,
       v.cliente_whatsapp,
       v.bairro,
       v.cidade,
       v.vendedor_id,
       u.nome                   as vendedor_nome,
       v.nio_pedido,
       v.nio_contrato,
       coalesce(v.ativado_em, v.instalado_em) as ativado_em,
       v.bonus_m10_potencial,
       coalesce((
         select jsonb_agg(jsonb_build_object(
                  'nr', f.nr_fatura, 'vencimento', f.dt_vencimento, 'pagamento', f.dt_pagamento, 'valor', f.valor,
                  'situacao', public.nio_fatura_situacao(f.status_fatura, f.dt_pagamento)) order by f.nr_fatura)
           from public.nio_faturas f where f.venda_id = v.id), '[]'::jsonb) as faturas
  from public.vendas v
  left join public.usuarios u on u.id = v.vendedor_id
 where v.status in ('4_ativo_provisorio', '5_comissao_firme');

-- Conciliação: 1 linha por (ciclo, venda) e por (ciclo, lançamento da Nio sem venda).
-- Ciclo esperado da venda = quinzena da ativação (no exemplo, DATA_ATV 24/09 veio no 2QSET26).                    -- CONFERIR
-- Lançamento de uma venda num ciclo diferente do esperado (estorno tardio, complemento) vira linha própria sem prevista.
create or replace view public.v_conciliacao
with (security_invoker = true) as
with prev as (
  select v.id as venda_id, public.nio_ciclo_de((coalesce(v.ativado_em, v.instalado_em) at time zone 'America/Sao_Paulo')::date) as ciclo,
         v.cliente_nome, v.nio_pedido, v.nio_contrato, u.nome as vendedor_nome,
         (coalesce(v.ativado_em, v.instalado_em) at time zone 'America/Sao_Paulo')::date as ativado_em,
         v.comissao_prevista as prevista, v.comissao_nominal, v.comissao_adicionais, v.bonus_transicao_previsto, v.bonus_nmei_previsto
    from public.vendas v
    left join public.usuarios u on u.id = v.vendedor_id
   where coalesce(v.ativado_em, v.instalado_em) is not null
     and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme', 'saida')   -- saída depois de ativar ainda é conciliada
),
lin as (
  select l.ciclo, l.venda_id,
         case when l.venda_id is null then coalesce(l.contrato, 'sem-contrato-' || l.id) end as chave_sem_venda,
         min(l.contrato) as contrato, min(l.num_os_pedido) as pedido, min(l.data_atv) as data_atv,
         sum(l.comissao) as paga,
         jsonb_agg(jsonb_build_object('evento', l.evento, 'sub_evento', l.sub_evento, 'produto', l.produto, 'oferta', l.oferta,
                                      'comissao', l.comissao, 'recompra', coalesce(l.recompra, false)) order by l.id) as linhas
    from public.nio_extrato_linhas l
   group by l.ciclo, l.venda_id, case when l.venda_id is null then coalesce(l.contrato, 'sem-contrato-' || l.id) end
)
select coalesce(p.ciclo, l.ciclo)                         as ciclo,
       coalesce(p.venda_id, l.venda_id)                   as venda_id,
       p.cliente_nome,
       coalesce(p.nio_pedido, l.pedido)                   as nio_pedido,
       coalesce(p.nio_contrato, l.contrato)               as nio_contrato,
       p.vendedor_nome,
       coalesce(p.ativado_em, l.data_atv)                 as ativado_em,
       p.prevista, p.comissao_nominal, p.comissao_adicionais, p.bonus_transicao_previsto, p.bonus_nmei_previsto,
       l.paga,
       coalesce(l.linhas, '[]'::jsonb)                    as linhas,
       coalesce(p.ativado_em, l.data_atv)                 as fato_gerador,                                       -- CONFERIR fato gerador
       (select jsonb_build_object('id', c.id, 'aberta_em', c.criado_em::date, 'motivo', c.motivo, 'descricao', c.descricao,
                                  'valor', c.valor, 'status', c.status)
          from public.nio_contestacoes c
         where c.ciclo = coalesce(p.ciclo, l.ciclo)
           and (c.venda_id = coalesce(p.venda_id, l.venda_id) or (c.venda_id is null and c.nio_contrato = l.contrato))
         order by c.criado_em desc limit 1)              as contestacao
  from prev p
  full join lin l on l.venda_id = p.venda_id and l.ciclo = p.ciclo;

-- Rodapé do ciclo (NF a emitir) e seletor de ciclos.
create or replace view public.v_conciliacao_ciclos
with (security_invoker = true) as
select ciclo, ciclo_nio, documento_compras, valor_pedido, status_pedido, numero_nf, previsao_pg, dt_compensacao, importado_em
  from public.nio_extrato_pedidos;

commit;

-- ============================================================================
-- Antes de aplicar (checklist):
--  1. Abrir o 1º FPD real e o 1º extrato real e conferir cada "-- CONFERIR" (sobretudo as chaves CONTRATO / PEDIDO,
--     o formato de MES_EMISSAO / PREVISÃO_PG e os nomes de evento da transição, NMEI e multa de recompra).
--  2. Confirmar com o Rogério: fato gerador da contestação (ativação? data do pedido?) e o ciclo em que a ativação é paga.
--  3. Renumerar para o próximo número livre em supabase/migrations/ e rodar só com o OK do Ricardo.
--  4. Telas: docs/adimplencia.html e docs/conciliacao.html já leem estas views no formato acima; sem elas, mostram o estado vazio.
-- ============================================================================
