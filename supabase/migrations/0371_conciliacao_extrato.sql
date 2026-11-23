-- NIOGEN | supabase/migrations/0371_conciliacao_extrato.sql | 23/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 23/11: "No dia 16 saiu o primeiro ciclo de pagamento da Nio, referente a primeira quinzena novembro. […] Já podemos
-- iniciar a tela Conciliação". Arquivo: 202611_1Q_PEDIDOS_X_LINHA_A_LINHA_16112026_V0_DHARMA_TEL.xlsx (pasta do Drive
-- ciclo-comissionamento): aba PEDIDO (1 pedido de compra, R$ 380, NF ainda não identificada) + aba LINHA_A_LINHA (2 linhas
-- da 1ª venda instalada: COMISSAO_ATIVACAO 350 + BONUS TRANSICAO 30 — bate com o previsto do NIOGEN).
-- Chave PROVADA com o 1º arquivo real: LINHA_A_LINHA.NUM_OS_PEDIDO_SIEBEL = vendas.nio_os (= nio_pedido na venda remota);
-- CONTRATO não existe no NIOGEN antes do extrato (vendas.nio_contrato vazio) — fica guardado na linha, a venda não é tocada.
-- Plano: etapa 5c (docs/PLANO_sistema_fechado_etapas_121126_2135.md, Drive). Base: 0158 (razão comissao_lancamentos).
--
-- O quê:
--   1. nio_ciclo_do_rotulo / _xl_data / _num_br — ciclo '1QNOV26' → '2026-11-1Q'; data do Excel (46339 → 13/11/2026); número BR.
--   2. nio_extrato_pedidos — a aba PEDIDO (pedido de compra, valor, NF, previsão e compensação do pagamento), por ciclo.
--   3. nio_contestacoes — contestação registrada no NIOGEN (não envia nada à Nio), com prazo de 120 dias do fato gerador.
--   4. extrato_importar(arquivo, abas) — a única porta do extrato: guarda o arquivo como veio (importacoes + nio_relatorio_linhas),
--      troca as linhas do mesmo ciclo (reimportar é idempotente) e lança cada linha na razão (origem 'extrato'), casada pela OS.
--   5. contestacao_registrar / contestacao_mudar — a única porta da contestação (a tela não grava direto).
--   6. v_conciliacao / v_conciliacao_ciclos — o que a tela conciliacao.html já lê (formato de 05/11, prompt 14b).
--   7. conferencia_itens(): item 32 "Conciliação: o extrato fecha com as vendas" (injetado na versão no ar, como a 0370).
--
-- Regra 20: (1) não cria estado de lead · (2) contestação tem prazo gravado e cobrança na conferência (aberta > 7 d sem envio);
-- ciclo encerrado sem extrato vira atenção · (3) extrato e contestação só por função do banco, com autor (criado_por) ·
-- (4) dinheiro → o extrato da Nio: o NIOGEN só prevê (origem 'sistema') e confere; nada da venda é reescrito ·
-- (5) item 32 da conferência. Parceiro: toda tabela nova com parceiro_id. Tela Live: sem mudança.
begin;

-- ───────────────────────── 1. auxiliares ─────────────────────────
create or replace function public.nio_ciclo_do_rotulo(p_rotulo text)
returns text language sql immutable set search_path = '' as $$
  select '20' || substr(r, 6, 2) || '-'
         || lpad(array_position(array['JAN','FEV','MAR','ABR','MAI','JUN','JUL','AGO','SET','OUT','NOV','DEZ'], substr(r, 3, 3))::text, 2, '0')
         || '-' || substr(r, 1, 2)
    from (select upper(btrim(p_rotulo)) as r) x
   where r ~ '^[12]Q(JAN|FEV|MAR|ABR|MAI|JUN|JUL|AGO|SET|OUT|NOV|DEZ)[0-9]{2}$';
$$;

create or replace function public._xl_data(p text)
returns date language plpgsql immutable set search_path = '' as $$
declare t text := btrim(coalesce(p, ''));
begin
  if t ~ '^[0-9]{5}(\.[0-9]+)?$' then return date '1899-12-30' + floor(t::numeric)::int; end if;   -- número de série do Excel
  if t ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then return left(t, 10)::date; end if;
  if t ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}' then return to_date(left(t, 10), 'DD/MM/YYYY'); end if;
  return null;
exception when others then return null;
end;
$$;

create or replace function public._num_br(p text)
returns numeric language plpgsql immutable set search_path = '' as $$
declare t text := regexp_replace(btrim(coalesce(p, '')), '[R$\s]', '', 'g');
begin
  if t like '%,%' then t := replace(replace(t, '.', ''), ',', '.'); end if;
  if t ~ '^-?[0-9]+(\.[0-9]+)?$' then return t::numeric; end if;
  return null;
end;
$$;

-- ───────────────────────── 2. aba PEDIDO ─────────────────────────
create table if not exists public.nio_extrato_pedidos (
  id                bigserial primary key,
  parceiro_id       text not null default 'dharma',
  importacao_id     uuid references public.importacoes(id) on delete set null,
  ciclo             text not null,                 -- '2026-11-1Q'
  ciclo_nio         text,                          -- '1QNOV26'
  documento_compras text,                          -- o pedido de compra SAP contra o qual a Dharma emite a NF
  item              text,
  valor             numeric(12, 2) not null,
  status            text,                          -- STATUS da Nio ('Não Identificado' = a NF ainda não chegou)
  status_ajustado   text,
  numero_nf         text,
  chave_nf          text,
  data_emissao_nf   date,
  previsao_pg       date,
  dt_compensacao    date,
  pipefy            text,
  dados             jsonb not null,                -- a linha como veio
  criado_em         timestamptz not null default now()
);
create index if not exists nio_extrato_pedidos_ciclo_idx on public.nio_extrato_pedidos (parceiro_id, ciclo);
alter table public.nio_extrato_pedidos enable row level security;
drop policy if exists nio_extrato_pedidos_ler on public.nio_extrato_pedidos;
create policy nio_extrato_pedidos_ler on public.nio_extrato_pedidos for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.nio_extrato_pedidos from anon, authenticated;
grant select on public.nio_extrato_pedidos to authenticated;
grant all on public.nio_extrato_pedidos to service_role;
comment on table public.nio_extrato_pedidos is
  'Aba PEDIDO do extrato quinzenal da Nio (0371): o pedido de compra do ciclo, contra o qual a Dharma emite a NF. Grava só extrato_importar().';

-- ───────────────────────── 3. contestação ─────────────────────────
create table if not exists public.nio_contestacoes (
  id            uuid primary key default gen_random_uuid(),
  parceiro_id   text not null default 'dharma',
  ciclo         text not null,
  venda_id      uuid references public.vendas(id) on delete set null,
  nio_pedido    text,
  nio_contrato  text,
  motivo        text not null check (motivo in ('valor_tabela', 'bonus_nao_pago', 'adicional_nao_pago', 'nao_veio',
                                                'estorno_indevido', 'multa_indevida', 'outro')),
  valor         numeric(10, 2) not null check (valor > 0),
  descricao     text,
  fato_gerador  date,
  prazo_em      date,                              -- fato gerador + config_regras.prazo_contestacao_dias (120)
  status        text not null default 'aberta' check (status in ('aberta', 'enviada', 'aceita', 'recusada', 'cancelada')),
  resposta      text,
  aberta_em     timestamptz not null default now(),
  aberta_por    uuid default auth.uid(),
  mudou_em      timestamptz,
  mudou_por     uuid
);
create index if not exists nio_contestacoes_venda_idx on public.nio_contestacoes (venda_id, ciclo);
alter table public.nio_contestacoes enable row level security;
drop policy if exists nio_contestacoes_ler on public.nio_contestacoes;
create policy nio_contestacoes_ler on public.nio_contestacoes for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.nio_contestacoes from anon, authenticated;
grant select on public.nio_contestacoes to authenticated;
grant all on public.nio_contestacoes to service_role;
comment on table public.nio_contestacoes is
  'Contestação de comissão (0371): registro interno; o envio à Nio é por fora. Grava só contestacao_registrar/contestacao_mudar.';

-- ───────────────────────── 4. a porta do extrato ─────────────────────────
-- p_abas = {"PEDIDO": [ {coluna: valor, …}, … ], "LINHA_A_LINHA": [ … ]} — as linhas do xlsx como o SheetJS lê (cabeçalho = chave).
create or replace function public.extrato_importar(p_arquivo text, p_abas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  imp     uuid;
  ab      text;
  r       jsonb;
  i       int;
  c       text;
  c_nio   text;
  ciclos  text[];
  vid     uuid;
  os      text;
  ctr     text;
  ev      text;
  sub     text;
  val     numeric;
  tp      text;
  n_lin   int := 0;
  n_cas   int := 0;
  n_sem   int := 0;
  n_novo  int := 0;
  tot     numeric := 0;
  ped     numeric;
  subst   int;
  g       text := '-';
begin
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice importam o extrato.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_abas -> 'LINHA_A_LINHA') is distinct from 'array' or jsonb_array_length(p_abas -> 'LINHA_A_LINHA') = 0 then
    raise exception 'O arquivo não tem a aba LINHA_A_LINHA: não parece o extrato quinzenal (Pedidos × Linha a Linha).';
  end if;
  if jsonb_array_length(p_abas -> 'LINHA_A_LINHA') > 30000 then
    raise exception 'O extrato tem mais de 30 mil linhas — parece a base do canal inteiro. Peça à Nio só as linhas da Dharma.';
  end if;

  -- o ciclo: ANO + MES + QUINZENA da linha a linha (e o CICLO da aba PEDIDO, se houver, tem de ser o mesmo)
  select array_agg(distinct x) into ciclos from (
    select public.nio_ciclo_do_rotulo(upper(btrim(l ->> 'QUINZENA')) || upper(btrim(l ->> 'MES')) || right(btrim(l ->> 'ANO'), 2)) x
      from jsonb_array_elements(p_abas -> 'LINHA_A_LINHA') l
    union
    select public.nio_ciclo_do_rotulo(p ->> 'CICLO')
      from jsonb_array_elements(coalesce(p_abas -> 'PEDIDO', '[]')) p) y;
  if ciclos is null or array_length(ciclos, 1) <> 1 or ciclos[1] is null then
    raise exception 'Não reconheci um ciclo único no arquivo (ANO/MES/QUINZENA da linha a linha e CICLO do pedido): %', coalesce(array_to_string(ciclos, ', ', '?'), 'nenhum');
  end if;
  c := ciclos[1];
  c_nio := substr(c, 9, 2) || (array['JAN','FEV','MAR','ABR','MAI','JUN','JUL','AGO','SET','OUT','NOV','DEZ'])[substr(c, 6, 2)::int] || substr(c, 3, 2);

  -- reimportar o mesmo ciclo troca o que veio antes (a versão nova da Nio vale)
  select count(*) into subst from public.comissao_lancamentos where origem = 'extrato' and ciclo = c and parceiro_id = 'dharma';
  delete from public.comissao_lancamentos where origem = 'extrato' and ciclo = c and parceiro_id = 'dharma';
  delete from public.nio_extrato_pedidos where ciclo = c and parceiro_id = 'dharma';

  insert into public.importacoes (tipo, arquivo_nome, dt_ref, linhas, aplicadas, ignoradas, resumo, aplicado_em)
  values ('extrato', p_arquivo,
          case when right(c, 2) = '1Q' then (substr(c, 1, 8) || '15')::date
               else ((substr(c, 1, 8) || '01')::date + interval '1 month' - interval '1 day')::date end,
          0, 0, 0, jsonb_build_object('ciclo', c, 'ciclo_nio', c_nio), now())
  returning id into imp;

  -- o arquivo como veio
  for ab in select jsonb_object_keys(p_abas) loop
    if jsonb_typeof(p_abas -> ab) = 'array' then
      insert into public.nio_relatorio_linhas (importacao_id, tipo, aba, linha, dados)
      select imp, 'extrato', ab, o.n::int, o.v from jsonb_array_elements(p_abas -> ab) with ordinality o(v, n);
    end if;
  end loop;

  -- aba PEDIDO
  for r in select v from jsonb_array_elements(coalesce(p_abas -> 'PEDIDO', '[]')) v loop
    insert into public.nio_extrato_pedidos (importacao_id, ciclo, ciclo_nio, documento_compras, item, valor, status, status_ajustado,
                                            numero_nf, chave_nf, data_emissao_nf, previsao_pg, dt_compensacao, pipefy, dados)
    values (imp, c, c_nio, nullif(btrim(r ->> 'DOCUMENTO DE COMPRAS'), ''), nullif(btrim(r ->> 'ITEM'), ''),
            coalesce(public._num_br(r ->> 'VALOR'), 0),
            nullif(nullif(btrim(r ->> 'STATUS'), ''), g), nullif(nullif(btrim(r ->> 'STATUS_AJUSTADO'), ''), g),
            nullif(nullif(btrim(coalesce(r ->> 'NUMERO_NF', r ->> 'NF')), ''), g), nullif(nullif(btrim(r ->> 'CHAVE_NF'), ''), g),
            public._xl_data(coalesce(r ->> 'DATA_EMISSAO', r ->> 'DT_EMISSÃO')), public._xl_data(r ->> 'PREVISAO_PG'),
            public._xl_data(r ->> 'DT_COMPENSAÇÃO'), nullif(nullif(btrim(r ->> 'NUM. PIPEFY'), ''), g), r);
  end loop;

  -- aba LINHA_A_LINHA → razão, casada pela OS (NUM_OS_PEDIDO_SIEBEL); contrato só como segunda chave
  i := 0;
  for r in select v from jsonb_array_elements(p_abas -> 'LINHA_A_LINHA') v loop
    i := i + 1;
    os  := nullif(nullif(regexp_replace(coalesce(r ->> 'NUM_OS_PEDIDO_SIEBEL', ''), '\.0+$', ''), ''), g);
    ctr := nullif(nullif(regexp_replace(coalesce(r ->> 'CONTRATO', ''), '\.0+$', ''), ''), g);
    ev  := upper(btrim(coalesce(r ->> 'EVENTO', '')));
    sub := upper(btrim(coalesce(r ->> 'SUB_EVENTO', '')));
    val := coalesce(public._num_br(r ->> 'COMISSAO'), 0);
    vid := null;
    if os is not null then
      select v.id into vid from public.vendas v where v.nio_os = os or v.nio_pedido = os
       order by (v.cancelada_apos_instalar_em is null) desc, v.instalado_em desc nulls last limit 1;
    end if;
    if vid is null and ctr is not null then
      select v.id into vid from public.vendas v where v.nio_contrato = ctr limit 1;
    end if;
    tp := case when upper(btrim(coalesce(r ->> 'RECOMPRA', g))) not in ('-', '', 'N', 'NAO', 'NÃO') or ev ~ 'MULTA|RECOMPRA' then 'multa'
               when ev ~ '^ESTORNO' then 'extrato_estorno'
               when ev ~ '^BONUS' then 'extrato_bonus'
               when ev ~ '^COMISS' then 'extrato_comissao'
               when val < 0 then 'extrato_estorno'
               else 'extrato_bonus' end;
    if not (ev ~ '^(ESTORNO|BONUS|COMISS|MULTA|RECOMPRA)') then n_novo := n_novo + 1; end if;
    insert into public.comissao_lancamentos (venda_id, tipo, sub, valor, ciclo, data_ref, origem, importacao_id, chave_nio)
    values (vid, tp, coalesce(nullif(sub, ''), ev), val, c, public._xl_data(r ->> 'DATA_ATV'), 'extrato', imp,
            jsonb_strip_nulls(jsonb_build_object('linha', i, 'ciclo_nio', c_nio, 'os', os, 'contrato', ctr, 'evento', ev, 'sub_evento', sub,
              'produto', nullif(r ->> 'PRODUTO', g), 'oferta', nullif(r ->> 'OFERTA', g), 'metodo', nullif(r ->> 'METODO_PAGAMENTO', g),
              'familia', nullif(r ->> 'FAMILIA', g), 'recompra', nullif(r ->> 'RECOMPRA', g), 'complementar', nullif(r ->> 'CICLO_COMPLEMENTAR', g),
              'municipio', nullif(r ->> 'MUNICIPIO', g), 'bairro', nullif(r ->> 'BAIRRO', g), 'ausente_base', nullif(r ->> 'AUSENTE_BASE', g))));
    n_lin := n_lin + 1;
    tot := tot + val;
    if vid is null then n_sem := n_sem + 1; else n_cas := n_cas + 1; end if;
  end loop;

  select sum(valor) into ped from public.nio_extrato_pedidos where importacao_id = imp;
  update public.importacoes
     set linhas = n_lin, aplicadas = n_cas, ignoradas = n_sem,
         resumo = resumo || jsonb_build_object('total_linhas', tot, 'valor_pedido', ped, 'bate_pedido', ped is null or round(ped, 2) = round(tot, 2),
                                               'sem_venda', n_sem, 'evento_novo', n_novo, 'substituiu', subst)
   where id = imp;
  return jsonb_build_object('importacao_id', imp, 'ciclo', c, 'ciclo_nio', c_nio, 'linhas', n_lin, 'casadas', n_cas, 'sem_venda', n_sem,
                            'evento_novo', n_novo, 'total_linhas', tot, 'valor_pedido', ped,
                            'bate_pedido', ped is null or round(ped, 2) = round(tot, 2), 'substituiu', subst);
end;
$$;
revoke all on function public.extrato_importar(text, jsonb) from public, anon;
grant execute on function public.extrato_importar(text, jsonb) to authenticated, service_role;
comment on function public.extrato_importar(text, jsonb) is
  'Porta única do extrato quinzenal da Nio (0371): guarda o arquivo, troca as linhas do ciclo e lança na razão (origem extrato), casando pela OS.';

-- ───────────────────────── 5. a porta da contestação ─────────────────────────
create or replace function public.contestacao_registrar(p_ciclo text, p_venda uuid, p_nio_pedido text, p_nio_contrato text,
                                                        p_motivo text, p_valor numeric, p_descricao text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  fato date;
  prz  date;
  dias int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_contestacao_dias'), 120);
  novo uuid;
begin
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice registram contestação.' using errcode = '42501';
  end if;
  if p_ciclo !~ '^[0-9]{4}-[0-9]{2}-[12]Q$' then raise exception 'Ciclo inválido: %', p_ciclo; end if;
  if coalesce(p_valor, 0) <= 0 then raise exception 'O valor contestado tem de ser maior que zero.'; end if;
  if p_venda is null and nullif(btrim(coalesce(p_nio_contrato, '')), '') is null and nullif(btrim(coalesce(p_nio_pedido, '')), '') is null then
    raise exception 'Contestação precisa da venda, do contrato ou do pedido.';
  end if;
  -- fato gerador: a ativação da venda; sem venda, a DATA_ATV da linha da Nio
  select (coalesce(v.ativado_em, v.instalado_em) at time zone 'America/Sao_Paulo')::date into fato from public.vendas v where v.id = p_venda;
  if fato is null then
    select min(l.data_ref) into fato from public.comissao_lancamentos l
     where l.origem = 'extrato' and l.ciclo = p_ciclo
       and ((p_venda is not null and l.venda_id = p_venda) or l.chave_nio ->> 'contrato' = p_nio_contrato or l.chave_nio ->> 'os' = p_nio_pedido);
  end if;
  prz := fato + dias;
  if prz < (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'Prazo de contestação vencido em % (% dias da ativação).', to_char(prz, 'DD/MM/YYYY'), dias;
  end if;
  if exists (select 1 from public.nio_contestacoes c where c.ciclo = p_ciclo and c.status in ('aberta', 'enviada')
               and ((p_venda is not null and c.venda_id = p_venda) or (p_venda is null and c.nio_contrato = p_nio_contrato))) then
    raise exception 'Já existe contestação aberta para esta venda neste ciclo.';
  end if;
  insert into public.nio_contestacoes (ciclo, venda_id, nio_pedido, nio_contrato, motivo, valor, descricao, fato_gerador, prazo_em)
  values (p_ciclo, p_venda, nullif(btrim(p_nio_pedido), ''), nullif(btrim(p_nio_contrato), ''), p_motivo, round(p_valor, 2),
          nullif(btrim(coalesce(p_descricao, '')), ''), fato, prz)
  returning id into novo;
  return novo;
end;
$$;
revoke all on function public.contestacao_registrar(text, uuid, text, text, text, numeric, text) from public, anon;
grant execute on function public.contestacao_registrar(text, uuid, text, text, text, numeric, text) to authenticated, service_role;

-- aberta → enviada → aceita | recusada; aberta ou enviada → cancelada. Aceita e recusada são finais.
create or replace function public.contestacao_mudar(p_id uuid, p_status text, p_resposta text default null)
returns void language plpgsql security definer set search_path = public as $$
declare atual text;
begin
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice mudam a contestação.' using errcode = '42501';
  end if;
  select status into atual from public.nio_contestacoes where id = p_id for update;
  if atual is null then raise exception 'Contestação não encontrada.'; end if;
  if not ((atual = 'aberta' and p_status in ('enviada', 'cancelada'))
       or (atual = 'enviada' and p_status in ('aceita', 'recusada', 'cancelada'))) then
    raise exception 'Contestação %: não muda para %.', atual, p_status;
  end if;
  update public.nio_contestacoes
     set status = p_status, resposta = coalesce(nullif(btrim(coalesce(p_resposta, '')), ''), resposta), mudou_em = now(), mudou_por = auth.uid()
   where id = p_id;
end;
$$;
revoke all on function public.contestacao_mudar(uuid, text, text) from public, anon;
grant execute on function public.contestacao_mudar(uuid, text, text) to authenticated, service_role;

-- ───────────────────────── 6. o que a tela lê ─────────────────────────
-- Uma linha por (ciclo × venda): o previsto entra no ciclo da ativação; o pago, no ciclo do extrato. Linha da Nio sem venda
-- no NIOGEN vira linha própria (extra), pelo contrato/OS. Lançamento da Nio de uma venda em ciclo diferente da ativação também
-- vira linha própria (prevista vazia), para não sumir.
create or replace view public.v_conciliacao with (security_invoker = true) as
with prev as (
  select venda_id, ciclo, sum(valor) as prevista
    from public.comissao_lancamentos
   where origem = 'sistema' and tipo in ('prevista', 'bonus_previsto') and venda_id is not null
   group by 1, 2
), ext as (
  select coalesce(venda_id::text, 'c:' || coalesce(chave_nio ->> 'contrato', chave_nio ->> 'os', id::text)) as k,
         venda_id, ciclo, sum(valor) as paga,
         max(chave_nio ->> 'contrato') as contrato, max(chave_nio ->> 'os') as os, min(data_ref) as data_atv,
         jsonb_agg(jsonb_build_object('evento', chave_nio ->> 'evento', 'sub_evento', chave_nio ->> 'sub_evento', 'comissao', valor,
                     'produto', chave_nio ->> 'produto', 'oferta', chave_nio ->> 'oferta', 'recompra', tipo = 'multa',
                     'data_atv', data_ref, 'tipo', tipo) order by (chave_nio ->> 'linha')::int) as linhas
    from public.comissao_lancamentos
   where origem = 'extrato'
   group by 1, 2, 3
), j as (
  select coalesce(p.ciclo, e.ciclo) as ciclo, coalesce(p.venda_id, e.venda_id) as venda_id, e.k,
         p.prevista, e.paga, e.linhas, e.contrato, e.os, e.data_atv
    from prev p full join ext e on e.venda_id = p.venda_id and e.ciclo = p.ciclo
)
select j.ciclo || '|' || coalesce(j.venda_id::text, j.k)                    as chave,
       j.ciclo, j.venda_id, v.cliente_nome,
       coalesce(v.nio_os, v.nio_pedido, j.os)                                as nio_pedido,
       coalesce(v.nio_contrato, j.contrato)                                  as nio_contrato,
       u.nome                                                                as vendedor_nome,
       coalesce(v.ativado_em, v.instalado_em)                                as ativado_em,
       j.prevista,
       case when j.prevista is not null then v.comissao_nominal end          as comissao_nominal,
       case when j.prevista is not null then v.comissao_adicionais end       as comissao_adicionais,
       case when j.prevista is not null then v.bonus_transicao_previsto end  as bonus_transicao_previsto,
       case when j.prevista is not null then v.bonus_nmei_previsto end       as bonus_nmei_previsto,
       coalesce(j.linhas, '[]'::jsonb)                                       as linhas,
       j.paga,
       coalesce((coalesce(v.ativado_em, v.instalado_em) at time zone 'America/Sao_Paulo')::date, j.data_atv) as fato_gerador,
       v.cancelada_apos_instalar_em,
       (select jsonb_build_object('id', c.id, 'aberta_em', c.aberta_em, 'motivo', c.motivo, 'descricao', c.descricao, 'valor', c.valor,
                                  'status', c.status, 'prazo_em', c.prazo_em, 'resposta', c.resposta)
          from public.nio_contestacoes c
         where c.ciclo = j.ciclo and c.status <> 'cancelada'
           and ((j.venda_id is not null and c.venda_id = j.venda_id) or (j.venda_id is null and c.nio_contrato = j.contrato))
         order by c.aberta_em desc limit 1)                                  as contestacao
  from j
  left join public.vendas v on v.id = j.venda_id
  left join public.usuarios u on u.id = v.vendedor_id;
revoke all on public.v_conciliacao from anon;
grant select on public.v_conciliacao to authenticated, service_role;
comment on view public.v_conciliacao is
  'Conciliação por ciclo × venda (0371): prevista (razão, origem sistema) × paga (extrato da Nio), com as linhas da Nio e a contestação.';

create or replace view public.v_conciliacao_ciclos with (security_invoker = true) as
select p.ciclo, max(p.ciclo_nio) as ciclo_nio,
       string_agg(distinct p.documento_compras, ', ') as documento_compras,
       sum(p.valor)                                   as valor_pedido,
       max(coalesce(p.status_ajustado, p.status))     as status_pedido,
       max(p.previsao_pg)                             as previsao_pg,
       max(p.dt_compensacao)                          as dt_compensacao,
       string_agg(distinct p.numero_nf, ', ')         as numero_nf,
       (select sum(l.valor) from public.comissao_lancamentos l where l.origem = 'extrato' and l.ciclo = p.ciclo) as soma_linhas,
       max(i.criado_em)                               as importado_em,
       max(i.arquivo_nome)                            as arquivo
  from public.nio_extrato_pedidos p
  left join public.importacoes i on i.id = p.importacao_id
 group by p.ciclo;
revoke all on public.v_conciliacao_ciclos from anon;
grant select on public.v_conciliacao_ciclos to authenticated, service_role;
comment on view public.v_conciliacao_ciclos is 'Pedido da Nio por ciclo (0371): valor, NF, previsão e compensação do pagamento.';

-- ───────────────────────── 7. conferência: item 32 ─────────────────────────
do $m$
declare
  d text := pg_get_functiondef('public.conferencia_itens(text)'::regprocedure);
  fim text := E'\n  return it;\nend';
  item text := $x$
  -- 32. 0371 — conciliação: o extrato da Nio fecha com o pedido e com as vendas
  select count(*)::int into n from public.v_conciliacao_ciclos where soma_linhas is not null and round(soma_linhas, 2) <> round(valor_pedido, 2);
  select count(*)::int into n2 from public.comissao_lancamentos l
   where l.origem = 'extrato' and l.venda_id is null
     and not exists (select 1 from public.nio_contestacoes c where c.ciclo = l.ciclo and c.nio_contrato = l.chave_nio ->> 'contrato' and c.status <> 'cancelada');
  select count(*)::int into v_tot from public.v_conciliacao x
   where x.prevista is not null and x.contestacao is null and x.cancelada_apos_instalar_em is null
     and exists (select 1 from public.v_conciliacao_ciclos k where k.ciclo = x.ciclo)
     and round(coalesce(x.paga, 0), 2) < round(x.prevista, 2)
     and x.fato_gerador + 120 >= (now() at time zone 'America/Sao_Paulo')::date;
  select count(*)::int, string_agg(z.ciclo, ', ' order by z.ciclo) into v_soma, ex
    from (select distinct l.ciclo from public.comissao_lancamentos l
           where l.origem = 'sistema' and l.ciclo >= '2026-11-1Q'
             and case when right(l.ciclo, 2) = '1Q' then (substr(l.ciclo, 1, 8) || '15')::date
                      else ((substr(l.ciclo, 1, 8) || '01')::date + interval '1 month' - interval '1 day')::date end
                 < (now() at time zone 'America/Sao_Paulo')::date - 5
             and not exists (select 1 from public.nio_extrato_pedidos p where p.ciclo = l.ciclo)) z;
  select string_agg(to_char(aberta_em at time zone 'America/Sao_Paulo', 'DD/MM'), ', ') into v_ex2
    from public.nio_contestacoes where status = 'aberta' and aberta_em < now() - interval '7 days';
  it := it || jsonb_build_object('codigo', 'conciliacao_extrato', 'nome', 'Conciliação: o extrato da Nio fecha com o pedido e as vendas',
    'nivel', case when n > 0 then 'falha' when n2 > 0 or v_tot > 0 or v_soma > 0 or v_ex2 is not null then 'atencao' else 'ok' end,
    'n', n + n2 + v_tot + v_soma,
    'texto', case when n = 0 and n2 = 0 and v_tot = 0 and v_soma = 0 and v_ex2 is null
                  then case when exists (select 1 from public.nio_extrato_pedidos) then 'todo extrato importado bate com o pedido e com as vendas'
                            else 'nenhum extrato da Nio importado ainda' end
                  else concat_ws(' · ',
                         case when n > 0 then format('%s ciclo(s) em que a linha a linha não soma o valor do pedido', n) end,
                         case when v_soma > 0 then format('ciclo encerrado sem extrato importado: %s', ex) end,
                         case when v_tot > 0 then format('%s venda(s) que a Nio pagou a menos (ou não pagou), sem contestação', v_tot) end,
                         case when n2 > 0 then format('%s linha(s) da Nio sem venda no NIOGEN', n2) end,
                         case when v_ex2 is not null then format('contestação aberta há mais de 7 dias sem envio à Nio (%s)', v_ex2) end) end,
    'fazer', case when n > 0 then 'Avisar o Claude Code e conferir o arquivo com a Nio antes de emitir a NF.'
                  when v_soma > 0 then 'Importar o extrato do ciclo na tela Conciliação (chega por e-mail; pedir ao Rogério se não chegou).'
                  when v_tot > 0 then 'Conciliação › Divergências e Faltam na Nio: contestar dentro dos 120 dias ou anotar por que não.'
                  when n2 > 0 then 'Conciliação › Extras da Nio: achar a venda (OS ou contrato) ou registrar o motivo.'
                  when v_ex2 is not null then 'Enviar a contestação à Nio (Rogério) e marcar como enviada.' end);
$x$;
begin
  if position('conciliacao_extrato' in d) > 0 then
    raise notice '0371: o item conciliacao_extrato já existe — nada a fazer';
    return;
  end if;
  if (length(d) - length(replace(d, fim, ''))) / length(fim) <> 1 then
    raise exception '0371: não achei um único "return it;" no fim de conferencia_itens — refazer a migration a partir da versão no ar';
  end if;
  if position('v_tot ' in d) = 0 or position('v_soma ' in d) = 0 or position('n2 ' in d) = 0 or position(E'\n  ex ' in d) = 0
     or position('v_ex2 ' in d) = 0 then
    raise exception '0371: conferencia_itens não declara mais v_tot, v_soma, n2, ex ou v_ex2 — refazer a migration';
  end if;
  execute replace(d, fim, item || fim);
end $m$;

commit;
