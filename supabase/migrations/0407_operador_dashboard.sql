-- NIOGEN | supabase/migrations/0407_operador_dashboard.sql | 25/11/2026 — Claude Code / Opus 5.5
-- Resumo: a rotina diária do operador no Dashboard (Performance em Foco) do portal PAP. O n8n pede ao operador da VPS BR que
-- abra o Dashboard com a sessão guardada do login de gestão (exceção da regra 5, Ricardo 25/11: "Vamos pelo terceiro caminho"),
-- exporte a OSAB e as Faturas em Aberto e liste as outras abas; aqui fica o que o banco precisa para receber isso:
--   1. config_dashboard_abas — o que fazer em cada aba (importar | listar), filtros e ordem. Nada fixo no código (regra 15).
--   2. config_regras.dashboard_rotina — horário e meses.
--   3. dashboard_rodadas — uma linha por rodada (o que entrou, erro). É o que a conferência lê.
--   4. dashboard_mapa — o modo "listar": os visuais de cada aba e quais exportam (o mapeamento sai de graça).
--   5. nio_faturas_abertas + faturas_importar() — retrato das faturas em aberto (aba FPD SPD TPD). Tabela vazia é válida
--      quando os cartões FPD/SPD/TPD dizem 0 em aberto; vazia com cartão > 0 é recusada (download falho não apaga o retrato).
--   6. dashboard_config() e dashboard_rodada_registrar() — o que o n8n chama.
--   7. ficha_venda ganha "faturas" (sem chamada nova na ficha — regra 19).
--   8. conferencia_itens ganha o item 38 (Dashboard rodou · instalada sem OSAB · faturas vencidas).
-- A OSAB continua entrando por osab_importar (0168), a mesma porta da importação automática. Inadimplência NÃO estorna
-- comissão (contrato): nada aqui mexe em comissão, estorno, Live ou régua de pagamento.
-- Prompt: docs/Prompt_operador_dashboard_osab_fpd_251126_1847.md (Drive).
begin;

-- 1. configuração das abas ------------------------------------------------------------------------------------------------
create table if not exists public.config_dashboard_abas (
  aba         text primary key,
  ordem       int  not null,
  modo        text not null check (modo in ('importar', 'listar')),
  visual      text,                -- título (aria-label) da tabela exportada; só no modo importar
  filtros     jsonb not null default '{}'::jsonb,   -- {combobox: "todos" | "meses"}
  ativo       boolean not null default true,
  parceiro_id text not null default 'dharma'
);
alter table public.config_dashboard_abas enable row level security;
drop policy if exists config_dashboard_abas_le on public.config_dashboard_abas;
create policy config_dashboard_abas_le on public.config_dashboard_abas for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
drop policy if exists config_dashboard_abas_admin on public.config_dashboard_abas;
create policy config_dashboard_abas_admin on public.config_dashboard_abas for all to authenticated
  using ((select public.meu_perfil()) = 'admin') with check ((select public.meu_perfil()) = 'admin');

insert into public.config_dashboard_abas (aba, ordem, modo, visual, filtros) values
  ('Dinâmica - OSAB',        1, 'importar', 'Exportação - OSAB',    '{"tp_venda_irregular": "todos", "ANOMES": "meses"}'),
  ('Dinâmica - FPD SPD TPD', 2, 'importar', 'Exportação - Faturas', '{"FAIXA": "todos", "NR_DIAS_ATE_BLOQUEIO": "todos", "ANOMES": "todos"}'),
  ('Geral',                  3, 'listar', null, '{}'),
  ('Atuação de Campo',       4, 'listar', null, '{}'),
  ('Operacional Vendas',     5, 'listar', null, '{}'),
  ('Produtividade Vendedor', 6, 'listar', null, '{}'),
  ('Eficácia',               7, 'listar', null, '{}'),
  ('Indicadores Qualidade',  8, 'listar', null, '{}'),
  ('Glossário',              9, 'listar', null, '{}')
on conflict (aba) do nothing;

-- 2. regra de horário ----------------------------------------------------------------------------------------------------
insert into public.config_regras (chave, valor, descricao)
values ('dashboard_rotina', '{"hora": "15:00", "meses": 2, "ativo": false}'::jsonb,
        '0407: rotina diária do operador no Dashboard do portal (OSAB + Faturas em Aberto). hora = Brasília; meses = ANOMES da OSAB (atual e anteriores que existirem).')
on conflict (chave) do nothing;

-- 3. rodadas -------------------------------------------------------------------------------------------------------------
create table if not exists public.dashboard_rodadas (
  id           bigserial primary key,
  iniciada_em  timestamptz not null default now(),
  terminada_em timestamptz,
  origem       text not null default 'rotina',       -- rotina | teste | manual
  ok           boolean not null default false,
  erro         text,
  resumo       jsonb not null default '{}'::jsonb,   -- por aba: modo, linhas, atualizado, importacao
  parceiro_id  text not null default 'dharma'
);
alter table public.dashboard_rodadas enable row level security;
drop policy if exists dashboard_rodadas_le on public.dashboard_rodadas;
create policy dashboard_rodadas_le on public.dashboard_rodadas for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));

-- 4. mapa das abas -------------------------------------------------------------------------------------------------------
create table if not exists public.dashboard_mapa (
  aba         text primary key,
  visuais     jsonb not null default '[]'::jsonb,    -- [{titulo, tipo, exporta}]
  lido_em     timestamptz not null default now(),
  parceiro_id text not null default 'dharma'
);
alter table public.dashboard_mapa enable row level security;
drop policy if exists dashboard_mapa_le on public.dashboard_mapa;
create policy dashboard_mapa_le on public.dashboard_mapa for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));

-- 5. faturas em aberto ---------------------------------------------------------------------------------------------------
create table if not exists public.nio_faturas_abertas (
  id                bigserial primary key,
  importacao_id     uuid references public.importacoes(id) on delete set null,
  nr_ordem          text not null,
  venda_id          uuid references public.vendas(id) on delete set null,
  nr_fatura         text,
  indicador         text,           -- FPD | SPD | TPD (Tipo Fatura)
  dt_ativacao       date,
  dt_geracao        date,
  dt_vencimento     date,
  dt_pagamento      date,
  status_pgto       text,
  dias_atraso       int,
  faixa             text,
  forma_pgto        text,
  modelo_pgto       text,
  dias_ate_bloqueio int,
  regra_bloqueio    text,
  bruto             jsonb not null default '{}'::jsonb,
  lido_em           timestamptz not null default now(),
  parceiro_id       text not null default 'dharma'
);
create index if not exists nio_faturas_abertas_venda on public.nio_faturas_abertas (venda_id);
create index if not exists nio_faturas_abertas_ordem on public.nio_faturas_abertas (nr_ordem);
alter table public.nio_faturas_abertas enable row level security;
drop policy if exists nio_faturas_abertas_le on public.nio_faturas_abertas;
create policy nio_faturas_abertas_le on public.nio_faturas_abertas for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));

create or replace function public.faturas_importar(p_arquivo text, p_linhas jsonb, p_cartoes jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_imp      uuid;
  n_linhas   int;
  n_casaram  int;
  v_abertas  int;
  v_sem      jsonb;
begin
  if not public._os_pode_gravar() then
    raise exception 'Sem permissão para importar as faturas.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_linhas) is distinct from 'array' then raise exception 'p_linhas precisa ser uma lista.' using errcode = 'P0001'; end if;
  n_linhas := jsonb_array_length(p_linhas);
  -- Cartões FPD/SPD/TPD: a soma de "A vencer" + "Vencidas" é o que a tabela tem de trazer.
  select sum(coalesce((c ->> 'a_vencer')::int, 0) + coalesce((c ->> 'vencidas')::int, 0))::int into v_abertas
    from jsonb_each(coalesce(p_cartoes, '{}'::jsonb)) e(k, c) where jsonb_typeof(c) = 'object';
  if n_linhas = 0 and coalesce(v_abertas, 0) > 0 then
    raise exception 'Faturas: o arquivo veio vazio mas os cartões dizem % em aberto — nada foi trocado.', v_abertas using errcode = 'P0001';
  end if;
  if n_linhas = 0 and p_cartoes is null then
    raise exception 'Faturas: arquivo vazio sem os cartões para conferir — nada foi trocado.' using errcode = 'P0001';
  end if;

  insert into public.importacoes (tipo, arquivo_nome, dt_ref, linhas, aplicadas, ignoradas, resumo, aplicado_em)
  values ('faturas', left(coalesce(nullif(btrim(p_arquivo), ''), 'Faturas em Aberto automático'), 200),
          (now() at time zone 'America/Sao_Paulo')::date, n_linhas, n_linhas, 0,
          jsonb_build_object('automatico', true, 'cartoes', p_cartoes), now())
  returning id into v_imp;

  delete from public.nio_faturas_abertas where parceiro_id = 'dharma';
  insert into public.nio_faturas_abertas (importacao_id, nr_ordem, venda_id, nr_fatura, indicador, dt_ativacao, dt_geracao,
         dt_vencimento, dt_pagamento, status_pgto, dias_atraso, faixa, forma_pgto, modelo_pgto, dias_ate_bloqueio, regra_bloqueio, bruto)
  select v_imp, btrim(x ->> 'nr_ordem'),
         (select v.id from public.vendas v where btrim(v.nio_pedido) = btrim(x ->> 'nr_ordem') order by v.criado_em desc limit 1),
         nullif(btrim(x ->> 'nr_fatura'), ''), nullif(btrim(x ->> 'indicador'), ''),
         nullif(x ->> 'dt_ativacao', '')::date, nullif(x ->> 'dt_geracao', '')::date, nullif(x ->> 'dt_vencimento', '')::date,
         nullif(x ->> 'dt_pagamento', '')::date, nullif(btrim(x ->> 'status_pgto'), ''),
         nullif(x ->> 'dias_atraso', '')::numeric::int, nullif(btrim(x ->> 'faixa'), ''), nullif(btrim(x ->> 'forma_pgto'), ''),
         nullif(btrim(x ->> 'modelo_pgto'), ''), nullif(x ->> 'dias_ate_bloqueio', '')::numeric::int,
         nullif(btrim(x ->> 'regra_bloqueio'), ''), coalesce(x -> 'bruto', '{}'::jsonb)
    from jsonb_array_elements(p_linhas) x
   where nullif(btrim(x ->> 'nr_ordem'), '') is not null;

  select count(*) filter (where venda_id is not null)::int,
         coalesce(jsonb_agg(distinct nr_ordem) filter (where venda_id is null), '[]'::jsonb)
    into n_casaram, v_sem from public.nio_faturas_abertas where importacao_id = v_imp;
  update public.importacoes set resumo = resumo || jsonb_build_object('casaram', n_casaram, 'sem_venda', v_sem) where id = v_imp;
  return jsonb_build_object('importacao_id', v_imp, 'linhas', n_linhas, 'casaram', n_casaram, 'sem_venda', v_sem,
                            'cartoes_em_aberto', coalesce(v_abertas, 0));
end $$;
revoke all on function public.faturas_importar(text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.faturas_importar(text, jsonb, jsonb) to service_role;

-- 6. o que o n8n chama ---------------------------------------------------------------------------------------------------
create or replace function public.dashboard_config()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'regra', coalesce((select valor from public.config_regras where chave = 'dashboard_rotina'), '{}'::jsonb),
    'abas', coalesce((select jsonb_agg(jsonb_build_object('aba', aba, 'modo', modo, 'visual', visual, 'filtros', filtros) order by ordem)
                        from public.config_dashboard_abas where ativo and parceiro_id = 'dharma'), '[]'::jsonb));
$$;
revoke all on function public.dashboard_config() from public, anon, authenticated;
grant execute on function public.dashboard_config() to service_role;

create or replace function public.dashboard_rodada_registrar(p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; m jsonb;
begin
  insert into public.dashboard_rodadas (iniciada_em, terminada_em, origem, ok, erro, resumo)
  values (coalesce(nullif(p_dados ->> 'iniciada_em', '')::timestamptz, now()), now(),
          coalesce(nullif(p_dados ->> 'origem', ''), 'rotina'), coalesce((p_dados ->> 'ok')::boolean, false),
          left(nullif(p_dados ->> 'erro', ''), 500), coalesce(p_dados -> 'resumo', '{}'::jsonb))
  returning id into v_id;
  for m in select * from jsonb_array_elements(coalesce(p_dados -> 'mapa', '[]'::jsonb)) loop
    insert into public.dashboard_mapa (aba, visuais, lido_em) values (m ->> 'aba', coalesce(m -> 'visuais', '[]'::jsonb), now())
    on conflict (aba) do update set visuais = excluded.visuais, lido_em = excluded.lido_em;
  end loop;
  return jsonb_build_object('rodada', v_id);
end $$;
revoke all on function public.dashboard_rodada_registrar(jsonb) from public, anon, authenticated;
grant execute on function public.dashboard_rodada_registrar(jsonb) to service_role;

-- 7. ficha_venda ganha as faturas em aberto (mesma chamada) ------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.ficha_venda'::regproc);
begin
  if position('nio_faturas_abertas' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return r;\\r?\\nend') <> 1 then   -- r? = a função pode ter vindo de migration salva com CRLF
    raise exception '0407: ficha_venda mudou — refazer o bloco das faturas a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return r;\\r?\\nend', E'
  -- 0407: faturas em aberto da Nio (aba FPD SPD TPD do Dashboard), a mais atrasada primeiro
  begin
    select jsonb_agg(jsonb_build_object(''indicador'', f.indicador, ''nr_fatura'', f.nr_fatura, ''vencimento'', f.dt_vencimento,
             ''dias_atraso'', f.dias_atraso, ''faixa'', f.faixa, ''status'', f.status_pgto, ''lido_em'', f.lido_em)
             order by f.dias_atraso desc nulls last, f.dt_vencimento) into x
      from public.nio_faturas_abertas f where f.venda_id = p_venda;
    r := r || jsonb_build_object(''faturas'', x);
  exception when others then r := r || jsonb_build_object(''faturas'', null); end;

  return r;
end');
  execute d;
end $$;

-- 8. conferência: item 38 ------------------------------------------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('dashboard_rotina' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then   -- r? = a função pode ter vindo de migration salva com CRLF
    raise exception '0407: conferencia_itens mudou — refazer o item do Dashboard a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 38. 0407 — rotina do Dashboard (OSAB + Faturas): rodou nas últimas 26 h? instalada sem OSAB há > 3 dias? fatura vencida?
  select count(*)::int into n from public.dashboard_rodadas where ok and terminada_em > now() - interval ''26 hours'';
  select count(*)::int into n2 from public.vendas v
   where v.status in (''3_instalado'', ''4_ativo_provisorio'', ''5_comissao_firme'') and v.nio_osab_em is null
     and v.instalado_em < now() - interval ''3 days'' and coalesce(btrim(v.nio_pedido), '''') <> '''';
  select count(distinct venda_id)::int into v_tot from public.nio_faturas_abertas where coalesce(dias_atraso, 0) > 0 and venda_id is not null;
  it := it || jsonb_build_object(''codigo'', ''dashboard_rotina'', ''nome'', ''OSAB e faturas do Dashboard da Nio'',
    ''nivel'', case when coalesce((select (valor ->> ''ativo'')::boolean from public.config_regras where chave = ''dashboard_rotina''), false) and n = 0 then ''falha''
                    when n2 > 0 or v_tot > 0 then ''atencao'' else ''ok'' end,
    ''n'', (case when n = 0 then 1 else 0 end) + n2 + v_tot,
    ''texto'', concat_ws('' · '', case when n = 0 then ''a rotina do Dashboard não rodou com sucesso nas últimas 26 h'' else ''Dashboard lido nas últimas 26 h'' end,
                                  case when n2 > 0 then format(''%s instalada(s) há mais de 3 dias sem aparecer na OSAB'', n2) end,
                                  case when v_tot > 0 then format(''%s venda(s) com fatura vencida na Nio'', v_tot) end),
    ''fazer'', case when n = 0 then ''Avisar o Claude Code: a sessão do login de gestão pode ter expirado (refazer o login: python portal/dashboard_sessao.py).''
                    when v_tot > 0 then ''Ficha da venda › selo Fatura: falar com o cliente antes do D+5 (régua de pagamento).''
                    when n2 > 0 then ''Conferir a OS no portal: instalada no NIOGEN e ainda fora da OSAB.'' end);

  return it;
end');
  execute d;
end $$;

commit;
