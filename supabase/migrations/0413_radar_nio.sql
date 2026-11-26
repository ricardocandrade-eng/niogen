-- NIOGEN | supabase/migrations/0413_radar_nio.sql | 26/11/2026 — Claude Code / Opus 5.5
-- Resumo: RADAR NIO — todos os indicadores do Dashboard da Nio (Performance em Foco) numa tela só, com a qualidade no topo e
-- filtro de datas (Ricardo, 25-26/11: "Talvez uma tela chamada Radar Nio, com todos esses indicadores" · "Regra 5 liberada" ·
-- "uma tela só, com dados bem organizados e a qualidade no topo, para chegarmos no alvo" · "Tudo com filtro de datas").
-- Absorve a tela Qualidade do docs/PLANO_qualidade_bko_191126_1115.md (Drive), etapa 1: a régua do BKO com o número da Nio e o nosso.
--   1. config_dashboard_abas ganha o modo "radar": o operador exporta os DADOS RESUMIDOS de cada gráfico (o número que o gráfico
--      mostra; "Dados subjacentes" continua proibido). Gráfico sem exportação (o autor desligou) = o texto que a tela mostra.
--   2. dashboard_config(p_rotina): 'diaria' (15h, OSAB + Faturas; as abas do radar só são listadas) | 'radar' (05h30, só o radar)
--      — rodadas separadas para a do radar (~5 min) não segurar crédito e viabilidade da Mari no meio do dia.
--   3. config_regras.radar_rotina — horário e ligado.
--   4. nio_radar_leituras — uma linha por gráfico por dia (o histórico que dá o filtro de datas).
--   5. config_radar_indicadores — quais números a tela destaca, de que gráfico, peso no BKO, direção, alarme (regra 15).
--   6. radar_importar() (n8n) e radar_resumo(p_de, p_ate) (tela, uma chamada só — regra 19).
--   7. conferencia_itens ganha o item 39 (radar lido nas últimas 26 h · alarme de estorno: VI, VE, recompra).
-- Só leitura de dados da Nio: nada aqui mexe em venda, comissão, estorno, régua de pagamento, Live ou Chatwoot.
begin;

-- 1. modo radar ----------------------------------------------------------------------------------------------------------
alter table public.config_dashboard_abas drop constraint if exists config_dashboard_abas_modo_check;
alter table public.config_dashboard_abas add constraint config_dashboard_abas_modo_check check (modo in ('importar', 'listar', 'radar'));
update public.config_dashboard_abas set modo = 'radar'
 where aba in ('Geral', 'Atuação de Campo', 'Operacional Vendas', 'Produtividade Vendedor', 'Eficácia', 'Indicadores Qualidade')
   and modo = 'listar';

-- 2. config por rotina ---------------------------------------------------------------------------------------------------
drop function if exists public.dashboard_config();
create or replace function public.dashboard_config(p_rotina text default 'diaria')
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'rotina', coalesce(nullif(p_rotina, ''), 'diaria'),
    'regra', coalesce((select valor from public.config_regras
                        where chave = case when p_rotina = 'radar' then 'radar_rotina' else 'dashboard_rotina' end), '{}'::jsonb),
    'abas', coalesce((select jsonb_agg(jsonb_build_object(
                         'aba', aba,
                         'modo', case when p_rotina = 'radar' then modo when modo = 'radar' then 'listar' else modo end,
                         'visual', visual, 'filtros', filtros) order by ordem)
                        from public.config_dashboard_abas
                       where ativo and parceiro_id = 'dharma' and (p_rotina is distinct from 'radar' or modo = 'radar')), '[]'::jsonb));
$$;
revoke all on function public.dashboard_config(text) from public, anon, authenticated;
grant execute on function public.dashboard_config(text) to service_role;

-- 3. regra de horário ----------------------------------------------------------------------------------------------------
insert into public.config_regras (chave, valor, descricao)
values ('radar_rotina', '{"hora": "05:30", "ativo": true}'::jsonb,
        '0413: rodada diária do Radar Nio (dados resumidos de cada gráfico do Dashboard da Nio). hora = Brasília, antes do expediente da Mari.')
on conflict (chave) do nothing;

-- 4. leituras ------------------------------------------------------------------------------------------------------------
create table if not exists public.nio_radar_leituras (
  id          bigserial primary key,
  dia         date not null default (now() at time zone 'America/Sao_Paulo')::date,
  aba         text not null,
  visual      text not null,
  ordem       int  not null default 0,
  tipo        text,
  colunas     jsonb,                 -- cabeçalho do "Dados resumidos"
  linhas      jsonb,                 -- linhas do "Dados resumidos" (no máx. 300)
  texto       text,                  -- gráfico sem exportação: o texto que a tela mostra
  erro        text,
  lido_em     timestamptz not null default now(),
  parceiro_id text not null default 'dharma',
  unique (parceiro_id, dia, aba, visual, ordem)
);
create index if not exists nio_radar_leituras_dia on public.nio_radar_leituras (parceiro_id, dia desc);
alter table public.nio_radar_leituras enable row level security;
drop policy if exists nio_radar_leituras_le on public.nio_radar_leituras;
create policy nio_radar_leituras_le on public.nio_radar_leituras for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));

-- 5. indicadores em destaque ---------------------------------------------------------------------------------------------
create table if not exists public.config_radar_indicadores (
  chave       text primary key,
  grupo       text not null check (grupo in ('bko', 'estorno', 'm10', 'funil', 'operacao')),
  nome        text not null,
  aba         text not null,
  visual      text not null,
  coluna      text,                  -- coluna do "Dados resumidos" (série por ANOMES)
  padrao      text,                  -- OU regex com 1 grupo sobre o texto do gráfico (série pelos dias de leitura)
  fator       numeric not null default 1,   -- texto "100%" → 0,01 para ficar em fração como o xlsx
  formato     text not null default 'num' check (formato in ('pct', 'num', 'dec')),
  direcao     text check (direcao in ('menor', 'maior')),
  peso_bko    int,
  alarme      boolean not null default false,   -- > 0 no mês = conferência em atenção (estorno/multa pelo contrato)
  ordem       int not null default 0,
  ajuda       text,
  ativo       boolean not null default true,
  parceiro_id text not null default 'dharma'
);
alter table public.config_radar_indicadores enable row level security;
drop policy if exists config_radar_indicadores_le on public.config_radar_indicadores;
create policy config_radar_indicadores_le on public.config_radar_indicadores for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
drop policy if exists config_radar_indicadores_admin on public.config_radar_indicadores;
create policy config_radar_indicadores_admin on public.config_radar_indicadores for all to authenticated
  using ((select public.meu_perfil()) = 'admin') with check ((select public.meu_perfil()) = 'admin');

insert into public.config_radar_indicadores (chave, grupo, nome, aba, visual, coluna, padrao, fator, formato, direcao, peso_bko, alarme, ordem, ajuda) values
  -- a régua do BKO (Guia de Qualidade do Parceiro): pesos 35 · 20 · 20 · 15 · 10
  ('spd',            'bko', 'SPD — 2ª fatura não paga', 'Indicadores Qualidade', 'SPD VENCIMENTO', '% SPD', null, 1, 'pct', 'menor', 35, false, 1, 'Cliente que não pagou a 2ª fatura (safra pelo vencimento). Peso 35 no BKO.'),
  ('fpd',            'bko', 'FPD — 1ª fatura não paga', 'Indicadores Qualidade', 'FPD VENCIMENTO', '% FPD', null, 1, 'pct', 'menor', 20, false, 2, 'Cliente que não pagou a 1ª fatura. Peso 20.'),
  ('match_serasa',   'bko', 'Match Serasa',             'Indicadores Qualidade', 'MATCH SERASA',   'Macth Serasa', null, 1, 'pct', 'maior', 20, false, 3, 'Dados digitados que batem com o Serasa. Peso 20.'),
  ('aproveitamento', 'bko', 'Aproveitamento',           'Operacional Vendas',    '% Aproveitamento', null, '\d{6} ([\d.,]+)%', 0.01, 'pct', 'maior', 15, false, 4, 'Venda que virou instalação. Peso 15.'),
  ('churn_m3',       'bko', 'Churn M3',                 'Indicadores Qualidade', 'CHURN M3',       'Churn M3', null, 1, 'pct', 'menor', 10, false, 5, 'Saiu da base em até 3 meses. Peso 10.'),
  -- o que vira estorno ou multa pelo contrato
  ('vi',             'estorno', 'Venda não reconhecida (VI)', 'Indicadores Qualidade', 'Venda Não Reconhecida Cliente', 'VI', null, 1, 'num', 'menor', null, true, 10, 'Cliente diz que não comprou: estorno.'),
  ('ve',             'estorno', 'Cadastro errado (VE)',       'Indicadores Qualidade', 'Venda Com Cadastro Errado', 'VE', null, 1, 'num', 'menor', null, true, 11, 'Venda com dado errado: estorno ou multa.'),
  ('recompra_penal', 'estorno', 'Recompra — churn penal',     'Indicadores Qualidade', 'Recompra - Churn', '% Recompra Churn Penal', null, 1, 'pct', 'menor', null, true, 12, 'Cliente que saiu e voltou por outro canal.'),
  ('tpd',            'estorno', 'TPD — 3ª fatura não paga',   'Indicadores Qualidade', 'TPD VENCIMENTO', '% TPD', null, 1, 'pct', 'menor', null, false, 13, null),
  -- o M-10 (R$ 150 por cliente no 10º mês)
  ('churn_m6',       'm10', 'Churn M6',  'Indicadores Qualidade', 'CHURN M6',  'Churn M6',  null, 1, 'pct', 'menor', null, false, 20, null),
  ('churn_m10',      'm10', 'Churn M10', 'Indicadores Qualidade', 'CHURN M10', 'Churn M10', null, 1, 'pct', 'menor', null, false, 21, 'Saiu antes do 10º mês: o bônus M-10 morre.'),
  ('aasd_m10',       'm10', 'AASD M10',  'Indicadores Qualidade', 'AASD M10',  'AASD',      null, 1, 'pct', 'maior', null, false, 22, 'Safras fechadas. Indicador da Nio sobre o 10º mês.'),
  -- o funil do mês (aba Geral): a Nio conta as consultas do robô da Mari no login da Joysse
  ('funil_viab',     'funil', 'Consultas de viabilidade', 'Geral', 'Funil de Vendas', null, 'Instalação ([\d.]+)', 1, 'num', null, null, false, 30, null),
  ('funil_viavel',   'funil', 'Viáveis',                  'Geral', 'Funil de Vendas', null, 'Instalação (?:[\d.]+(?: \(\d+%\))? ){1}([\d.]+)', 1, 'num', null, null, false, 31, null),
  ('funil_credito',  'funil', 'Consultas de crédito',     'Geral', 'Funil de Vendas', null, 'Instalação (?:[\d.]+(?: \(\d+%\))? ){2}([\d.]+)', 1, 'num', null, null, false, 32, null),
  ('funil_plano',    'funil', 'Plano aprovado',           'Geral', 'Funil de Vendas', null, 'Instalação (?:[\d.]+(?: \(\d+%\))? ){3}([\d.]+)', 1, 'num', null, null, false, 33, null),
  ('funil_pedido',   'funil', 'Pedidos gerados',          'Geral', 'Funil de Vendas', null, 'Instalação (?:[\d.]+(?: \(\d+%\))? ){4}([\d.]+)', 1, 'num', null, null, false, 34, null),
  ('funil_vb',       'funil', 'Venda bruta',              'Geral', 'Funil de Vendas', null, 'Instalação (?:[\d.]+(?: \(\d+%\))? ){5}([\d.]+)', 1, 'num', null, null, false, 35, null),
  ('funil_inst',     'funil', 'Instalações',              'Geral', 'Funil de Vendas', null, 'Instalação (?:[\d.]+(?: \(\d+%\))? ){6}([\d.]+)', 1, 'num', null, null, false, 36, null),
  ('conversao',      'funil', 'Conversão consulta → instalação', 'Geral', 'Instalação X Conversão Instalação', '% Conversão', null, 1, 'pct', 'maior', null, false, 37, null),
  -- operação
  ('eficacia',       'operacao', 'Eficácia (BA OK na 1ª visita)', 'Eficácia', '% Eficácia', null, '([\d.,]+)%', 0.01, 'pct', 'maior', null, false, 40, 'Instalação resolvida sem pendência.'),
  ('vb',             'operacao', 'VB no mês',            'Operacional Vendas', 'VB - Mensal', null, '\d{6} ([\d.]+)', 1, 'num', 'maior', null, false, 41, null),
  ('gross',          'operacao', 'GROSS no mês',         'Operacional Vendas', 'GROSS - Mensal', null, '\d{6} ([\d.]+)', 1, 'num', 'maior', null, false, 42, null),
  ('cartao',         'operacao', '% cartão de crédito',  'Operacional Vendas', '% Cartão de Crédito (VB)', null, '\d{6} ([\d.,]+)%', 0.01, 'pct', 'maior', null, false, 43, null),
  ('presenca',       'operacao', 'Vendedores logados',   'Geral', 'Presença de Campo (Logados) X Capilaridade Real', 'Presença de Campo', null, 1, 'num', 'maior', null, false, 44, null),
  ('du_pedido',      'operacao', 'Pedidos por dia útil', 'Geral', 'Pedidos Gerados', 'du Pedido', null, 1, 'dec', 'maior', null, false, 45, null)
on conflict (chave) do nothing;

-- 6a. o que o n8n chama --------------------------------------------------------------------------------------------------
create or replace function public.radar_importar(p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_dia date := coalesce(nullif(p_dados ->> 'dia', '')::date, (now() at time zone 'America/Sao_Paulo')::date);
  a jsonb; g jsonb; n_ok int := 0; n_txt int := 0; n_err int := 0;
begin
  if jsonb_typeof(p_dados -> 'radar') is distinct from 'array' then
    raise exception 'radar_importar: p_dados.radar precisa ser uma lista.' using errcode = 'P0001';
  end if;
  for a in select * from jsonb_array_elements(p_dados -> 'radar') loop
    for g in select * from jsonb_array_elements(coalesce(a -> 'visuais', '[]'::jsonb)) loop
      continue when nullif(btrim(g ->> 'visual'), '') is null;
      insert into public.nio_radar_leituras (dia, aba, visual, ordem, tipo, colunas, linhas, texto, erro, lido_em)
      values (v_dia, left(a ->> 'aba', 80), left(btrim(g ->> 'visual'), 120), coalesce((g ->> 'ordem')::int, 0), left(g ->> 'tipo', 60),
              g -> 'colunas', g -> 'linhas', left(g ->> 'texto', 2000), left(g ->> 'erro', 300), now())
      on conflict (parceiro_id, dia, aba, visual, ordem) do update
        set tipo = excluded.tipo, colunas = excluded.colunas, linhas = excluded.linhas, texto = excluded.texto,
            erro = excluded.erro, lido_em = excluded.lido_em;
      if g ? 'erro' then n_err := n_err + 1; elsif g ? 'linhas' then n_ok := n_ok + 1; else n_txt := n_txt + 1; end if;
    end loop;
  end loop;
  return jsonb_build_object('dia', v_dia, 'exportados', n_ok, 'texto', n_txt, 'erros', n_err);
end $$;
revoke all on function public.radar_importar(jsonb) from public, anon, authenticated;
grant execute on function public.radar_importar(jsonb) to service_role;

-- 6b. valor de um texto pelo padrão (pt-BR: 1.234,5) ----------------------------------------------------------------------
create or replace function public._radar_num(p_txt text)
returns numeric language sql immutable as $$
  select case when p_txt ~ '^[\d.,]+$' then replace(replace(p_txt, '.', ''), ',', '.')::numeric end;
$$;

-- 6c. os indicadores em destaque (sem checar perfil: a conferência das 7h10 também lê) -----------------------------------
create or replace function public._radar_indicadores(p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_de date := p_de; v_ate date := p_ate; m_de text := to_char(p_de, 'YYYYMM'); m_ate text := to_char(p_ate, 'YYYYMM'); v_ind jsonb;
begin
  -- série por ANOMES: série por ANOMES (dentro do período) ou pelos dias de leitura (texto)
  select coalesce(jsonb_agg(x order by (x ->> 'ordem')::int), '[]'::jsonb) into v_ind from (
    select jsonb_build_object('chave', c.chave, 'grupo', c.grupo, 'nome', c.nome, 'formato', c.formato, 'direcao', c.direcao,
             'peso_bko', c.peso_bko, 'alarme', c.alarme, 'ordem', c.ordem, 'ajuda', c.ajuda, 'aba', c.aba, 'visual', c.visual,
             'serie', s.serie, 'valor', s.serie -> -1 -> 'v', 'ref', s.serie -> -1 -> 'x', 'lido', s.lido) as x
      from public.config_radar_indicadores c
      cross join lateral (
        select case when c.coluna is not null then (
                 select jsonb_build_object('lido', u.dia, 'serie', coalesce((
                          select jsonb_agg(jsonb_build_object('x', l ->> im, 'v', (l ->> iv)::numeric) order by l ->> im)
                            from jsonb_array_elements(u.linhas) l
                           where (l ->> iv) ~ '^-?[\d.eE+-]+$'
                             and (im is null or (l ->> im) between m_de and m_ate)), '[]'::jsonb))
                   from (select r.dia, r.linhas,
                                (select (o - 1)::int from jsonb_array_elements_text(r.colunas) with ordinality k(v, o) where k.v = 'ANOMES') as im,
                                (select (o - 1)::int from jsonb_array_elements_text(r.colunas) with ordinality k(v, o) where k.v = c.coluna) as iv
                           from public.nio_radar_leituras r
                          where r.parceiro_id = 'dharma' and r.aba = c.aba and (r.visual = c.visual or r.visual like c.visual || ' %') and r.dia <= v_ate and r.erro is null
                          order by r.dia desc limit 1) u
                  where u.iv is not null)
               else (
                 select jsonb_build_object('lido', max(r.dia), 'serie', coalesce(jsonb_agg(jsonb_build_object('x', to_char(r.dia, 'YYYY-MM-DD'),
                          'v', public._radar_num(substring(r.texto from c.padrao)) * c.fator) order by r.dia)
                          filter (where public._radar_num(substring(r.texto from c.padrao)) is not null), '[]'::jsonb))
                   from public.nio_radar_leituras r
                  where r.parceiro_id = 'dharma' and r.aba = c.aba and (r.visual = c.visual or r.visual like c.visual || ' %') and r.dia between v_de and v_ate and r.erro is null)
               end as j) jj
      cross join lateral (select jj.j -> 'serie' as serie, jj.j -> 'lido' as lido) s
     where c.ativo and c.parceiro_id = 'dharma') q;

  return v_ind;
end $$;
revoke all on function public._radar_indicadores(date, date) from public, anon, authenticated;

-- 6d. a tela -------------------------------------------------------------------------------------------------------------
create or replace function public.radar_resumo(p_de date default null, p_ate date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ate date := coalesce(p_ate, (now() at time zone 'America/Sao_Paulo')::date);
  v_de  date := coalesce(p_de, date_trunc('month', v_ate)::date);
  m_de text; m_ate text; v_ind jsonb; v_vis jsonb; v_nosso jsonb; v_rod jsonb; v_dia date;
begin
  if coalesce((select public.meu_perfil()), '') not in ('admin', 'backoffice') then
    raise exception 'O Radar Nio é do admin e do backoffice.' using errcode = '42501';
  end if;
  if v_de > v_ate then v_de := v_ate; end if;
  m_de := to_char(v_de, 'YYYYMM'); m_ate := to_char(v_ate, 'YYYYMM');
  select max(dia) into v_dia from public.nio_radar_leituras where parceiro_id = 'dharma' and dia <= v_ate;

  -- a leitura mais recente de cada gráfico até a data final
  with ult as (
    select distinct on (aba, visual, ordem) * from public.nio_radar_leituras
     where parceiro_id = 'dharma' and dia <= v_ate and erro is null
     order by aba, visual, ordem, dia desc)
  select coalesce(jsonb_agg(jsonb_build_object('aba', aba, 'visual', visual, 'tipo', tipo, 'dia', dia,
                                               'colunas', colunas, 'linhas', linhas, 'texto', texto) order by aba, ordem), '[]'::jsonb)
    into v_vis from ult;

  v_ind := public._radar_indicadores(v_de, v_ate);

  -- o nosso número no mesmo período (vendas pela data da OS, como o Placar)
  select jsonb_build_object(
           'os_geradas', count(*) filter (where v.nio_os_em is not null),
           'instaladas', count(*) filter (where v.nio_os_em is not null and v.instalado_em is not null),
           'canceladas_apos_instalar', count(*) filter (where v.cancelada_apos_instalar_em is not null),
           'aproveitamento', round(count(*) filter (where v.nio_os_em is not null and v.instalado_em is not null)::numeric
                                   / nullif(count(*) filter (where v.nio_os_em is not null), 0), 4))
    into v_nosso
    from public.vendas v
   where (v.nio_os_em at time zone 'America/Sao_Paulo')::date between v_de and v_ate;
  v_nosso := v_nosso || jsonb_build_object(
    'faturas_a_vencer', (select count(*) from public.nio_faturas_abertas where coalesce(dias_atraso, 0) <= 0),
    'faturas_vencidas', (select count(*) from public.nio_faturas_abertas where coalesce(dias_atraso, 0) > 0),
    'faturas_lidas_em', (select max(lido_em) from public.nio_faturas_abertas));

  select jsonb_build_object('em', terminada_em, 'ok', ok, 'erro', erro) into v_rod
    from public.dashboard_rodadas where origem in ('radar', 'radar-teste') order by id desc limit 1;

  return jsonb_build_object('de', v_de, 'ate', v_ate, 'dia_ref', v_dia,
    'primeiro_dia', (select min(dia) from public.nio_radar_leituras where parceiro_id = 'dharma'),
    'indicadores', v_ind, 'visuais', v_vis, 'nosso', v_nosso, 'rodada', v_rod,
    'regua_canal_local', null);   -- o Canal Local (a régua do BKO) ainda não chegou da Nio: sem ele a faixa não é calculada
end $$;
revoke all on function public.radar_resumo(date, date) from public, anon;
grant execute on function public.radar_resumo(date, date) to authenticated, service_role;

-- 7. conferência: item 39 ------------------------------------------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('radar_rotina' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0413: conferencia_itens mudou — refazer o item do Radar a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 39. 0413 — Radar Nio: lido nas últimas 26 h? algum indicador de estorno (VI, VE, recompra) acima de zero no mês?
  select count(*)::int into n from public.nio_radar_leituras where parceiro_id = ''dharma'' and lido_em > now() - interval ''26 hours'';
  select count(*)::int into n2 from (select i from jsonb_array_elements(coalesce(public._radar_indicadores(date_trunc(''month'', now() at time zone ''America/Sao_Paulo'')::date, (now() at time zone ''America/Sao_Paulo'')::date), ''[]''::jsonb)) i
                                      where (i ->> ''alarme'')::boolean and coalesce((i ->> ''valor'')::numeric, 0) > 0) z;
  it := it || jsonb_build_object(''codigo'', ''radar_rotina'', ''nome'', ''Radar Nio (indicadores do Dashboard)'',
    ''nivel'', case when coalesce((select (valor ->> ''ativo'')::boolean from public.config_regras where chave = ''radar_rotina''), false) and n = 0 then ''falha''
                    when n2 > 0 then ''atencao'' else ''ok'' end,
    ''n'', (case when n = 0 then 1 else 0 end) + n2,
    ''texto'', concat_ws('' · '', case when n = 0 then ''o Radar não leu o Dashboard nas últimas 26 h'' else ''Radar lido nas últimas 26 h'' end,
                                  case when n2 > 0 then format(''%s indicador(es) de estorno acima de zero no mês (VI, VE ou recompra)'', n2) end),
    ''fazer'', case when n = 0 then ''Avisar o Claude Code: a rodada das 05h30 falhou (sessão do login de gestão?).''
                    when n2 > 0 then ''Radar Nio › Estorno e multa: ver qual venda é e falar com o Rogério antes do fechamento.'' end);

  return it;
end');
  execute d;
end $$;

commit;
