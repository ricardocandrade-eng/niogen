-- NIOGEN | supabase/migrations/0011_dfv_nivel3.sql | 03/11/2026
-- DFV Nio — nível 3: a base HP/HC que a Nio entrega (CSV por município, só endereços viáveis) entra no Supabase
-- e o NIOGEN responde viabilidade e "endereço já tem Nio" sozinho, por CEP + número (+ complemento).
-- Fonte: docs/DFV_BASE_JF_dicionario_031126_1955.md (pasta do Drive). Prompt 05 pedia "0010"; a 0010 já foi usada
-- (acesso do DFV, v0.5.1), por isso esta é a 0011.
--
-- O dado é da Nio: o CSV nunca entra no repo. A carga é pelo CLI (staging nio_hp_stage → aplicar_dfv); a tela de
-- importação só faz a prévia por enquanto.
-- Fora do arquivo = sem viabilidade hoje (a Nio só exporta "Viável").
--
-- Passo 0 (banco real em 03/11): migrations 0001–0010, sem nio_hp, importacoes só com 'osab', 0 vendas.

-- ============================================================================
-- nio_hp: uma linha por fachada (número + complemento) da última partição de cada município
-- ============================================================================

create table if not exists public.nio_hp (
  cod_survey          text not null,
  numero              text not null,                 -- como veio (NO_FACHADA): "10", "12C", "SN"
  complemento1        text,
  complemento2        text,
  complemento3        text,
  cep                 text not null,
  logradouro          text,
  cod_logradouro      text,
  tipo_endereco       text,
  bairro              text,
  municipio           text not null,
  uf                  text not null,
  celula              text,
  estacao             text,
  cdo                 text,
  tipo_edificacao     text,
  viabilidade         text,
  id_viabilidade      int,
  hp_tot              int,
  hp_var              int,
  hp_emp              int,
  hp_livre            int,
  hc_tot              int,
  hc_var              int,
  hc_emp              int,
  classificacao       text,
  classe_social       text,
  faixa_credito       text,                          -- texto da Nio: "Maior que 70%", "Entre 50% e 70%", …
  pct_aprov_bairro    numeric,
  qt_propostas_bairro int,
  gross_6m            numeric,
  flag_gross_6m       int,
  hp_novo             int,
  lat                 double precision,
  lon                 double precision,
  particao            date not null,
  importacao_id       uuid references public.importacoes (id) on delete set null,
  -- Colunas do arquivo que o NIOGEN ainda não usa, só quando vierem preenchidas (hoje: vazias ou "Não informado").
  -- Guardar as 49 em toda linha custaria ~170 MB; assim nada se perde quando a Nio passar a preencher.
  bruto               jsonb not null default '{}'::jsonb,
  -- Chave: o Postgres não aceita coalesce() na PK, então o complemento vazio vira '' numa coluna gerada.
  complemento1_chave  text generated always as (coalesce(complemento1, '')) stored,
  -- Número só com dígitos, para casar "12" com o que o vendedor digitar.
  numero_dig          text generated always as (regexp_replace(numero, '\D', '', 'g')) stored,
  primary key (cod_survey, numero, complemento1_chave)
);

comment on table public.nio_hp is
  'Base DFV da Nio (HP/HC por fachada, só viáveis). Substituída inteira por município a cada carga (aplicar_dfv). Dado da Nio: não sai do Supabase.';

-- (cep, numero_dig) também atende a busca só por CEP (prefixo do índice).
create index if not exists nio_hp_cep_numero_idx on public.nio_hp (cep, numero_dig);
create index if not exists nio_hp_bairro_idx     on public.nio_hp (municipio, bairro);
create index if not exists nio_hp_celula_idx     on public.nio_hp (celula);
create index if not exists nio_hp_latlon_idx     on public.nio_hp (lat, lon);
create index if not exists nio_hp_importacao_idx on public.nio_hp (importacao_id);

-- Staging: o arquivo como veio (texto, nomes das colunas em minúsculas), uma linha por linha do CSV.
create table if not exists public.nio_hp_stage (
  importacao_id                    uuid not null references public.importacoes (id) on delete cascade,
  linha                            int  not null,
  uf text, municipio text, celula text, localidade text, codigo_logradouro text, logradouro text, no_fachada text,
  complemento1 text, complemento2 text, complemento3 text, cep text, bairro text, latitude text, longitude text,
  viabilidade_atual text, hp_livre text, sigla_estacao_abastecedora text, codigo_cdo text, tipo_edificacao text,
  tipo_endereco text, giro_medio_6m_cel text, vll_media_6m_cel text, gross_media_6m_cel text, flag_gross_6m_cel text,
  perc_hps_area_risco text, hc_emp text, classificacao text, chave text, cod_survey text, id_viabilidade text,
  hp_var text, hp_emp text, hp_tot text, hc_tot text, hc_var text, f_hp_novo text, dt_construcao_2025 text,
  projeto_hp_novo text, score_medio_cel text, pct_aprov_ind_loc_out_cel text, qt_propostas_bairro text,
  pct_aprovados_bairro text, pct_aprovados_cc_bairro text, pct_posse_cartao_bairro text, dt_dfv_particao text,
  ds_classe_social_dominante text, ds_faixa_aprovacao_credito_total text, ds_faixa_aprovacao_credito_local text,
  ds_faixa_posse_cartao text,
  primary key (importacao_id, linha)
);

alter table public.nio_hp       enable row level security;
alter table public.nio_hp_stage enable row level security;

-- Leitura para todo perfil logado (venda, Painel, Meta Ads); escrita só por aplicar_dfv (security definer).
drop policy if exists nio_hp_ler on public.nio_hp;
create policy nio_hp_ler on public.nio_hp
  for select to authenticated using (public.meu_perfil() is not null);
drop policy if exists nio_hp_stage_operar on public.nio_hp_stage;
create policy nio_hp_stage_operar on public.nio_hp_stage
  for all to authenticated using (public.meu_perfil() in ('admin', 'backoffice')) with check (public.meu_perfil() in ('admin', 'backoffice'));
revoke all on public.nio_hp, public.nio_hp_stage from anon;
grant select on public.nio_hp to authenticated, service_role;

-- ============================================================================
-- importacoes: tipo dfv_hp
-- ============================================================================

alter table public.importacoes drop constraint if exists importacoes_tipo_check;
alter table public.importacoes add constraint importacoes_tipo_check
  check (tipo in ('osab', 'fpd', 'churn', 'extrato', 'faturas', 'dfv_hp'));

-- ============================================================================
-- Conversões do arquivo (só pg_catalog)
-- ============================================================================

create or replace function public.dfv_txt(p text)
returns text
language sql
immutable
set search_path = ''
as $$ select nullif(btrim(p), '') $$;

create or replace function public.dfv_int(p text)
returns int
language sql
immutable
set search_path = ''
as $$ select case when btrim(p) ~ '^-?\d+$' then btrim(p)::int end $$;

create or replace function public.dfv_num(p text)
returns numeric
language sql
immutable
set search_path = ''
as $$ select case when btrim(p) ~ '^-?\d+(\.\d+)?$' then btrim(p)::numeric end $$;

-- Faixa de crédito da Nio → código do NIOGEN (o mesmo do seletor manual da venda).
create or replace function public.dfv_faixa_codigo(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p is null then null
    when p ilike 'maior%' then '>70'
    when p ilike 'entre%' then '50-70'
    when p ilike 'menor%' then '<50'
    else 'nao_informado'
  end
$$;

-- ============================================================================
-- aplicar_dfv: staging → nio_hp, substituindo a partição inteira do município (nunca merge)
-- ============================================================================

create or replace function public.aplicar_dfv(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  imp        public.importacoes%rowtype;
  v_part     date;
  n_parts    int;
  n_arquivo  int;
  n_ins      int;
  v_ant      jsonb;
  v_resumo   jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice aplicam importação.' using errcode = '42501';
  end if;

  select * into imp from public.importacoes where id = p_importacao_id for update;
  if not found then
    raise exception 'Importação % não encontrada.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.tipo <> 'dfv_hp' then
    raise exception 'Importação % não é base DFV.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.aplicado_em is not null then
    raise exception 'Esta importação já foi aplicada em %.', imp.aplicado_em using errcode = 'P0001';
  end if;

  select count(*), count(distinct dt_dfv_particao)
    into n_arquivo, n_parts
  from (select public.dfv_txt(dt_dfv_particao) as dt_dfv_particao from public.nio_hp_stage where importacao_id = p_importacao_id) s;
  if n_arquivo = 0 then
    raise exception 'Importação % sem linhas na staging.', p_importacao_id using errcode = 'P0001';
  end if;
  if n_parts <> 1 then
    raise exception 'O arquivo tem % partições (dt_dfv_particao); esperado 1.', n_parts using errcode = 'P0001';
  end if;
  -- epoch em ms (1793664000000 = 03/11/2026, meia-noite UTC).
  v_part := (to_timestamp((select public.dfv_txt(dt_dfv_particao)::bigint from public.nio_hp_stage
                           where importacao_id = p_importacao_id limit 1) / 1000.0) at time zone 'UTC')::date;

  -- Fotografia da partição que sai (para o "antes × depois" do resumo).
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_ant from (
    select h.uf, h.municipio, min(h.particao) as particao, count(*) as linhas,
           sum(h.hp_tot) as hp_tot, sum(h.hp_livre) as hp_livre, sum(h.hc_tot) as hc_tot
    from public.nio_hp h
    where (h.uf, h.municipio) in (select distinct public.dfv_txt(s.uf), public.dfv_txt(s.municipio)
                                  from public.nio_hp_stage s where s.importacao_id = p_importacao_id)
    group by h.uf, h.municipio) x;

  delete from public.nio_hp h
  where (h.uf, h.municipio) in (select distinct public.dfv_txt(s.uf), public.dfv_txt(s.municipio)
                                from public.nio_hp_stage s where s.importacao_id = p_importacao_id);

  -- Linha repetida no arquivo (mesma chave): fica a primeira.
  insert into public.nio_hp (
    cod_survey, numero, complemento1, complemento2, complemento3, cep, logradouro, cod_logradouro, tipo_endereco,
    bairro, municipio, uf, celula, estacao, cdo, tipo_edificacao, viabilidade, id_viabilidade,
    hp_tot, hp_var, hp_emp, hp_livre, hc_tot, hc_var, hc_emp, classificacao, classe_social, faixa_credito,
    pct_aprov_bairro, qt_propostas_bairro, gross_6m, flag_gross_6m, hp_novo, lat, lon, particao, importacao_id, bruto)
  select distinct on (cod_survey, numero, coalesce(complemento1, ''))
    cod_survey, numero, complemento1, complemento2, complemento3, cep, logradouro, cod_logradouro, tipo_endereco,
    bairro, municipio, uf, celula, estacao, cdo, tipo_edificacao, viabilidade, id_viabilidade,
    hp_tot, hp_var, hp_emp, hp_livre, hc_tot, hc_var, hc_emp, classificacao, classe_social, faixa_credito,
    pct_aprov_bairro, qt_propostas_bairro, gross_6m, flag_gross_6m, hp_novo, lat, lon, v_part, p_importacao_id, bruto
  from (
    select s.linha,
      public.dfv_txt(s.cod_survey) as cod_survey,
      upper(regexp_replace(coalesce(public.dfv_txt(s.no_fachada), 'SN'), '\s', '', 'g')) as numero,
      public.dfv_txt(s.complemento1) as complemento1, public.dfv_txt(s.complemento2) as complemento2,
      public.dfv_txt(s.complemento3) as complemento3,
      regexp_replace(coalesce(s.cep, ''), '\D', '', 'g') as cep,
      public.dfv_txt(s.logradouro) as logradouro, public.dfv_txt(s.codigo_logradouro) as cod_logradouro,
      public.dfv_txt(s.tipo_endereco) as tipo_endereco, public.dfv_txt(s.bairro) as bairro,
      public.dfv_txt(s.municipio) as municipio, public.dfv_txt(s.uf) as uf, public.dfv_txt(s.celula) as celula,
      public.dfv_txt(s.sigla_estacao_abastecedora) as estacao, public.dfv_txt(s.codigo_cdo) as cdo,
      public.dfv_txt(s.tipo_edificacao) as tipo_edificacao, public.dfv_txt(s.viabilidade_atual) as viabilidade,
      public.dfv_int(s.id_viabilidade) as id_viabilidade,
      public.dfv_int(s.hp_tot) as hp_tot, public.dfv_int(s.hp_var) as hp_var, public.dfv_int(s.hp_emp) as hp_emp,
      public.dfv_int(s.hp_livre) as hp_livre, public.dfv_int(s.hc_tot) as hc_tot, public.dfv_int(s.hc_var) as hc_var,
      public.dfv_int(s.hc_emp) as hc_emp, public.dfv_txt(s.classificacao) as classificacao,
      public.dfv_txt(s.ds_classe_social_dominante) as classe_social,
      public.dfv_txt(s.ds_faixa_aprovacao_credito_total) as faixa_credito,
      public.dfv_num(s.pct_aprovados_bairro) as pct_aprov_bairro, public.dfv_int(s.qt_propostas_bairro) as qt_propostas_bairro,
      public.dfv_num(s.gross_media_6m_cel) as gross_6m, public.dfv_int(s.flag_gross_6m_cel) as flag_gross_6m,
      public.dfv_int(s.f_hp_novo) as hp_novo,
      public.dfv_num(s.latitude)::double precision as lat, public.dfv_num(s.longitude)::double precision as lon,
      (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
         from jsonb_each_text(jsonb_build_object(
           'giro_medio_6m_cel', s.giro_medio_6m_cel, 'vll_media_6m_cel', s.vll_media_6m_cel,
           'perc_hps_area_risco', s.perc_hps_area_risco, 'dt_construcao_2025', s.dt_construcao_2025,
           'projeto_hp_novo', s.projeto_hp_novo, 'score_medio_cel', s.score_medio_cel,
           'pct_aprov_ind_loc_out_cel', s.pct_aprov_ind_loc_out_cel, 'pct_aprovados_cc_bairro', s.pct_aprovados_cc_bairro,
           'pct_posse_cartao_bairro', s.pct_posse_cartao_bairro,
           'ds_faixa_aprovacao_credito_local', s.ds_faixa_aprovacao_credito_local,
           'ds_faixa_posse_cartao', s.ds_faixa_posse_cartao)) e(k, v)
         where public.dfv_txt(v) is not null and v not ilike 'n_o informado') as bruto
    from public.nio_hp_stage s
    where s.importacao_id = p_importacao_id
  ) t
  where cod_survey is not null and cep <> '' and municipio is not null and uf is not null
  order by cod_survey, numero, coalesce(complemento1, ''), linha;
  get diagnostics n_ins = row_count;

  select jsonb_build_object(
      'particao', v_part, 'linhas_arquivo', n_arquivo, 'linhas', n_ins, 'descartadas', n_arquivo - n_ins,
      'hp_tot', sum(hp_tot), 'hp_livre', sum(hp_livre), 'hc_tot', sum(hc_tot),
      'casas_ocupadas', count(*) filter (where hp_tot = 1 and hc_tot >= 1),
      'bairros', count(distinct bairro), 'ceps', count(distinct cep),
      'municipios', jsonb_agg(distinct municipio), 'anterior', v_ant)
    into v_resumo
  from public.nio_hp where importacao_id = p_importacao_id;

  delete from public.nio_hp_stage where importacao_id = p_importacao_id;

  update public.importacoes set
    dt_ref      = v_part,
    linhas      = n_arquivo,
    aplicadas   = n_ins,
    ignoradas   = n_arquivo - n_ins,
    resumo      = coalesce(imp.resumo, '{}'::jsonb) || v_resumo,
    aplicado_em = now()
  where id = p_importacao_id;

  return v_resumo;
end;
$$;

revoke execute on function public.aplicar_dfv(uuid) from public, anon;
grant execute on function public.aplicar_dfv(uuid) to authenticated;

-- ============================================================================
-- dfv_consultar: CEP + número (+ complemento) → viabilidade
-- ============================================================================

-- Complemento comparável: só letras e dígitos, maiúsculo ("Apto 101" = "APTO101").
create or replace function public.dfv_comp_norm(p text)
returns text
language sql
immutable
set search_path = ''
as $$ select nullif(upper(regexp_replace(coalesce(p, ''), '[^[:alnum:]]', '', 'g')), '') $$;

create or replace function public.dfv_consultar(p_cep text, p_numero text, p_complemento text default null)
returns table (
  resultado       text,       -- viavel · viavel_predio · endereco_ocupado · sem_porta_livre · nao_encontrado · precisa_numero
  hp_livre        int,
  hc_tot          int,
  hp_tot          int,
  tipo_edificacao text,
  faixa_credito   text,
  classificacao   text,
  classe_social   text,
  bairro          text,
  celula          text,
  cod_survey      text,
  particao        date,
  opcoes          jsonb       -- viavel_predio: [{complemento, numero, hp_livre, hc_tot, hp_tot}] para escolher a unidade
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_cep  text := regexp_replace(coalesce(p_cep, ''), '\D', '', 'g');
  v_txt  text := upper(regexp_replace(coalesce(p_numero, ''), '\s', '', 'g'));
  v_dig  text := regexp_replace(coalesce(p_numero, ''), '\D', '', 'g');
  v_comp text := public.dfv_comp_norm(p_complemento);
  v_cdig text := regexp_replace(coalesce(p_complemento, ''), '\D', '', 'g');
  cand   public.nio_hp[];
  sel    public.nio_hp[];
  v_part date;
  r      public.nio_hp;
begin
  select max(h.particao), min(h.bairro) into v_part, bairro from public.nio_hp h where h.cep = v_cep;
  particao := v_part;

  -- Sem número (vazio, "s/n", "SN"): só diz se o CEP está na base e pede o número.
  if v_dig = '' then
    resultado := case when v_part is null then 'nao_encontrado' else 'precisa_numero' end;
    return next;
    return;
  end if;

  -- Candidatas: o número exatamente como digitado ("12C"); se não houver, pelos dígitos ("12" casa 12, 12A…).
  select array_agg(h order by h.numero, h.complemento1 nulls first, h.complemento2) into cand
    from public.nio_hp h where h.cep = v_cep and h.numero = v_txt;
  if cand is null then
    select array_agg(h order by h.numero, h.complemento1 nulls first, h.complemento2) into cand
      from public.nio_hp h where h.cep = v_cep and h.numero_dig = v_dig;
  end if;

  if cand is null then
    resultado := 'nao_encontrado';
    return next;
    return;
  end if;

  -- Várias linhas (prédio / casas A, B…): o complemento escolhe a unidade (igual em letras+dígitos, ou só nos dígitos).
  if cardinality(cand) > 1 and v_comp is not null then
    select array_agg(c) into sel from unnest(cand) c
      where public.dfv_comp_norm(concat(c.complemento1, c.complemento2, c.complemento3)) = v_comp;
    if coalesce(cardinality(sel), 0) <> 1 and v_cdig <> '' then
      select array_agg(c) into sel from unnest(cand) c
        where regexp_replace(concat(c.complemento1, c.complemento2, c.complemento3), '\D', '', 'g') = v_cdig;
    end if;
    if cardinality(sel) = 1 then
      cand := sel;
    end if;
  end if;

  if cardinality(cand) = 1 then
    r := cand[1];
    resultado := case
      when r.hp_tot = 1 and coalesce(r.hc_tot, 0) >= 1 then 'endereco_ocupado'   -- trava do contrato: já tem Nio
      when coalesce(r.hp_livre, 0) >= 1 then 'viavel'
      else 'sem_porta_livre'
    end;
    hp_livre := r.hp_livre; hc_tot := r.hc_tot; hp_tot := r.hp_tot; tipo_edificacao := r.tipo_edificacao;
    faixa_credito := r.faixa_credito; classificacao := r.classificacao; classe_social := r.classe_social;
    bairro := r.bairro; celula := r.celula; cod_survey := r.cod_survey; particao := r.particao;
    return next;
    return;
  end if;

  -- Prédio sem unidade escolhida: soma e lista as unidades.
  select case when sum(c.hp_livre) >= 1 then 'viavel_predio' else 'sem_porta_livre' end,
         sum(c.hp_livre)::int, sum(c.hc_tot)::int, sum(c.hp_tot)::int,
         case when count(distinct c.tipo_edificacao) = 1 then min(c.tipo_edificacao) else 'VERTICAL' end,
         mode() within group (order by c.faixa_credito), mode() within group (order by c.classificacao),
         mode() within group (order by c.classe_social), min(c.bairro), min(c.celula), max(c.particao),
         jsonb_agg(jsonb_build_object(
           'complemento', nullif(concat_ws(' ', c.complemento1, c.complemento2, c.complemento3), ''),
           'numero', c.numero, 'hp_livre', c.hp_livre, 'hc_tot', c.hc_tot, 'hp_tot', c.hp_tot))
    into resultado, hp_livre, hc_tot, hp_tot, tipo_edificacao, faixa_credito, classificacao, classe_social,
         bairro, celula, particao, opcoes
  from unnest(cand) c;
  cod_survey := null;
  return next;
end;
$$;

comment on function public.dfv_consultar(text, text, text) is
  'Viabilidade pela base DFV (nio_hp). Usada pelo NIOGEN (trigger da venda e bloco Cobertura) e pela Mari via RPC (n8n, service role).';

revoke execute on function public.dfv_consultar(text, text, text) from public, anon;
grant execute on function public.dfv_consultar(text, text, text) to authenticated, service_role;

-- ============================================================================
-- vendas: consulta automática ao gravar o endereço (status 0)
-- ============================================================================

alter table public.vendas
  add column if not exists dfv_origem    text check (dfv_origem in ('manual', 'auto')),
  add column if not exists dfv_resultado text,     -- resposta crua de dfv_consultar (ex.: endereco_ocupado)
  add column if not exists dfv_particao  date;     -- partição da base usada na consulta automática

comment on column public.vendas.dfv_origem is
  'auto = preenchido por dfv_consultar (base nio_hp) · manual = escolhido na tela (nível 1, fallback).';

-- Roda antes de vendas_antes_dfv (BEFORE dispara em ordem alfabética: "cobertura" < "dfv"), que carimba quem e quando.
create or replace function public.vendas_antes_cobertura()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  c        record;
  v_mapa   text;
  end_mudou boolean;
  dfv_mexido boolean;
begin
  -- Escolha manual na tela: vale como veio.
  if new.dfv_origem = 'manual' and (tg_op = 'INSERT' or old.dfv_origem is distinct from 'manual'
                                    or new.dfv_viabilidade is distinct from old.dfv_viabilidade) then
    new.dfv_resultado := null;
    new.dfv_particao := null;
    return new;
  end if;

  if new.status <> '0_qualificado' or coalesce(btrim(new.cep), '') = '' or coalesce(btrim(new.numero), '') = '' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- O front já consultou e mandou o resultado: não repete.
    if new.dfv_viabilidade <> 'nao_consultado' then return new; end if;
  else
    end_mudou := row(new.cep, new.numero, new.complemento) is distinct from row(old.cep, old.numero, old.complemento);
    dfv_mexido := row(new.dfv_viabilidade, new.dfv_origem) is distinct from row(old.dfv_viabilidade, old.dfv_origem);
    if not end_mudou or dfv_mexido then return new; end if;
    -- Consulta manual mais nova que a base: fica a manual.
    if old.dfv_origem = 'manual' and old.dfv_consultado_em >=
       (select (max(h.particao)::timestamp at time zone 'America/Sao_Paulo') from public.nio_hp h
         where h.cep = regexp_replace(new.cep, '\D', '', 'g')) then
      return new;
    end if;
  end if;

  select * into c from public.dfv_consultar(new.cep, new.numero, new.complemento);
  if c.resultado is null or c.resultado = 'precisa_numero' then
    return new;
  end if;

  v_mapa := case c.resultado
    when 'viavel'           then 'viavel'
    when 'viavel_predio'    then 'viavel_predio'
    when 'endereco_ocupado' then 'sem_viabilidade'
    when 'sem_porta_livre'  then 'sem_viabilidade'
    else 'nao_encontrado'
  end;

  new.dfv_viabilidade   := v_mapa;
  new.dfv_resultado     := c.resultado;
  new.dfv_hp_livre      := c.hp_livre;
  new.dfv_hcs           := c.hc_tot;
  new.dfv_faixa_credito := public.dfv_faixa_codigo(c.faixa_credito);
  new.dfv_classificacao := case when c.classificacao in ('ALTO', 'MEDIO', 'BAIXO') then c.classificacao end;
  new.dfv_particao      := c.particao;
  new.dfv_consultado_em := now();
  new.dfv_origem        := 'auto';
  return new;
end;
$$;

drop trigger if exists vendas_antes_cobertura on public.vendas;
create trigger vendas_antes_cobertura
  before insert or update on public.vendas
  for each row execute function public.vendas_antes_cobertura();

-- Evento de toda gravação do DFV (agora com a origem) + "DFV: endereço já tem Nio".
create or replace function public.vendas_registra_dfv()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.dfv_viabilidade <> 'nao_consultado' then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (new.id, 'dfv_consulta', jsonb_strip_nulls(jsonb_build_object(
        'viabilidade', new.dfv_viabilidade, 'consultado_em', new.dfv_consultado_em, 'faixa_credito', new.dfv_faixa_credito,
        'classificacao', new.dfv_classificacao, 'hp_livre', new.dfv_hp_livre, 'hcs', new.dfv_hcs,
        'origem', new.dfv_origem, 'resultado', new.dfv_resultado, 'particao', new.dfv_particao)), auth.uid());
    end if;
  elsif row(new.dfv_viabilidade, new.dfv_consultado_em, new.dfv_faixa_credito, new.dfv_classificacao, new.dfv_hp_livre, new.dfv_hcs)
        is distinct from row(old.dfv_viabilidade, old.dfv_consultado_em, old.dfv_faixa_credito, old.dfv_classificacao, old.dfv_hp_livre, old.dfv_hcs) then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'dfv_consulta', jsonb_strip_nulls(jsonb_build_object(
      'viabilidade', new.dfv_viabilidade, 'de', old.dfv_viabilidade, 'consultado_em', new.dfv_consultado_em,
      'faixa_credito', new.dfv_faixa_credito, 'classificacao', new.dfv_classificacao, 'hp_livre', new.dfv_hp_livre, 'hcs', new.dfv_hcs,
      'origem', new.dfv_origem, 'resultado', new.dfv_resultado, 'particao', new.dfv_particao)), auth.uid());
  end if;

  if new.dfv_resultado = 'endereco_ocupado' and (tg_op = 'INSERT' or old.dfv_resultado is distinct from 'endereco_ocupado') then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'dfv_endereco_ocupado', jsonb_build_object(
      'mensagem', 'DFV: endereço já tem Nio', 'cep', new.cep, 'numero', new.numero, 'complemento', new.complemento,
      'particao', new.dfv_particao), auth.uid());
  end if;

  if new.dfv_dispensado and (tg_op = 'INSERT' or not old.dfv_dispensado) then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'dfv_dispensa', jsonb_build_object('motivo', new.dfv_dispensa_motivo), auth.uid());
  end if;
  return null;
end;
$$;

drop trigger if exists vendas_registra_dfv on public.vendas;
create trigger vendas_registra_dfv
  after insert or update of dfv_viabilidade, dfv_consultado_em, dfv_faixa_credito, dfv_classificacao, dfv_hp_livre, dfv_hcs,
                            dfv_dispensado, dfv_resultado
  on public.vendas
  for each row execute function public.vendas_registra_dfv();

revoke execute on function public.vendas_antes_cobertura() from public, anon, authenticated;
revoke execute on function public.vendas_registra_dfv()    from public, anon, authenticated;

-- ============================================================================
-- Views do funil recriadas: v.* congela as colunas na criação; assim passam a trazer dfv_origem/dfv_resultado/dfv_particao.
-- Corpo idêntico ao da 0009.
-- ============================================================================

drop view if exists public.v_placar_dfv;
drop view if exists public.v_painel_hoje;
drop view if exists public.v_painel_mes;
drop view if exists public.v_alertas_contrato;
drop view if exists public.v_instalacoes;
drop view if exists public.v_funil;

create view public.v_funil
with (security_invoker = true) as
select
  v.*,
  p.nome          as plano_nome,
  p.familia       as plano_familia,
  p.velocidade    as plano_velocidade,
  p.preco         as plano_preco,
  p.codigo        as plano_codigo,
  p.portfolio     as plano_portfolio,
  p.variante      as plano_variante,
  p.cluster       as plano_cluster,
  p.preco_cartao  as plano_preco_cartao,
  p.taxa_a_vista  as plano_taxa_a_vista,
  p.isencao_meses as plano_isencao_meses,
  u.nome          as vendedor_nome,
  case
    when v.status = '1_vendido' and v.agendamento_registrado_em is null and v.vendido_em is not null
      then round((extract(epoch from now() - v.vendido_em) / 3600)::numeric, 2)
  end as horas_sem_agendamento,
  case
    when v.status = '0_qualificado' and v.biometria_status is distinct from 'aprovada'
      then round((extract(epoch from now() - v.criado_em) / 86400)::numeric, 2)
  end as dias_esperando_biometria,
  (v.instalado_em + interval '15 days')  as docs_prazo_em,
  (v.instalado_em + interval '180 days') as firme_em,
  -- DFV: consulta viável e com menos de 7 dias (a mesma regra da trava em vendas_antes_status)
  (v.dfv_viabilidade in ('viavel', 'viavel_predio') and v.dfv_consultado_em >= now() - interval '7 days') as dfv_ok,
  case when v.dfv_consultado_em is not null then floor(extract(epoch from now() - v.dfv_consultado_em) / 86400)::int end as dfv_dias
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
  and f.status in ('3_instalado', '4_ativo_provisorio')
union all
select f.id, f.cliente_nome, 'dfv_nao_consultado', 'warn',
       'DFV não consultado · ' || case when f.biometria_status = 'agendada' then 'biometria marcada' else 'visita marcada' end,
       'venda.html?id=' || f.id, coalesce(f.biometria_em, f.instalacao_agendada_para, f.criado_em), null
from public.v_funil f
where f.status = '0_qualificado' and f.dfv_viabilidade = 'nao_consultado' and not f.dfv_dispensado
  and (f.biometria_status = 'agendada' or f.biometria_em is not null or f.instalacao_agendada_para is not null)
union all
select f.id, f.cliente_nome, 'dfv_sem_cobertura', 'bad',
       'DFV: ' || case when f.dfv_viabilidade = 'sem_viabilidade' then 'endereço sem viabilidade' else 'endereço não encontrado' end || ' · não vender',
       'venda.html?id=' || f.id, f.dfv_consultado_em, null
from public.v_funil f
where f.dfv_viabilidade in ('sem_viabilidade', 'nao_encontrado') and f.status <> 'saida';

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
  (select coalesce(sum(comissao_nominal), 0) from vend where mes_venda = m.mes)         as comissao_nominal,
  (select coalesce(sum(comissao_adicionais), 0) from vend where mes_venda = m.mes)      as comissao_adicionais,
  (select coalesce(sum(bonus_transicao_previsto), 0) from vend where mes_venda = m.mes) as bonus_transicao,
  (select coalesce(sum(bonus_nmei_previsto), 0) from vend where mes_venda = m.mes)      as bonus_nmei,
  (select coalesce(sum(bonus_m10_potencial), 0) from vend where mes_venda = m.mes)      as bonus_m10_potencial,
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

-- Placar do DFV: qualificadas que entraram no mês, quantas tiveram o DFV consultado e quantas deram viável.
create view public.v_placar_dfv
with (security_invoker = true) as
select
  date_trunc('month', v.criado_em at time zone 'America/Sao_Paulo')::date                         as mes,
  count(*)::int                                                                                   as qualificadas,
  count(*) filter (where v.dfv_viabilidade <> 'nao_consultado')::int                              as dfv_consultadas,
  count(*) filter (where v.dfv_viabilidade in ('viavel', 'viavel_predio'))::int                   as dfv_viaveis,
  count(*) filter (where v.dfv_viabilidade in ('sem_viabilidade', 'nao_encontrado'))::int         as dfv_sem_cobertura,
  count(*) filter (where v.dfv_dispensado)::int                                                   as dfv_dispensadas,
  round(100.0 * count(*) filter (where v.dfv_viabilidade in ('viavel', 'viavel_predio'))
        / nullif(count(*) filter (where v.dfv_viabilidade <> 'nao_consultado'), 0), 1)            as pct_viavel_consultadas,
  round(100.0 * count(*) filter (where v.dfv_viabilidade in ('viavel', 'viavel_predio')) / nullif(count(*), 0), 1) as pct_viavel_qualificadas
from public.vendas v
group by 1;

grant select on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje, public.v_placar_dfv to authenticated;
revoke all on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje, public.v_placar_dfv from anon;

-- ============================================================================
-- Views: ranking de bairros (Meta Ads / rota PAP) e resumo da base
-- ============================================================================

drop view if exists public.v_dfv_bairros;
drop view if exists public.v_dfv_resumo;

-- score = HP livre × % aprovação do bairro (mediana quando não informada) × (0,5 + 0,5 × % fachadas ALTO/MÉDIO).
-- raio_km = 1,5 × dispersão (distância quadrática média das fachadas ao centro).
create view public.v_dfv_bairros
with (security_invoker = true) as
with b as (
  select h.uf, h.municipio, h.bairro,
         count(*)::int                                                         as fachadas,
         sum(h.hp_tot)::int                                                    as hp_tot,
         sum(h.hp_livre)::int                                                  as hp_livre,
         sum(h.hc_tot)::int                                                    as hc_tot,
         sum(h.hp_emp)::int                                                    as hp_emp,
         max(h.pct_aprov_bairro)                                               as pct_aprov_bairro,
         max(h.qt_propostas_bairro)                                            as qt_propostas_bairro,
         avg(case when h.classificacao in ('ALTO', 'MEDIO') then 1.0 else 0 end) as pct_alto_medio,
         avg(case when h.classe_social in ('A/B', 'C') then 1.0 else 0 end)    as pct_ab_c,
         avg(h.lat)                                                            as lat_centro,
         avg(h.lon)                                                            as lon_centro,
         sqrt(coalesce(var_pop(h.lat * 111.32), 0)
              + coalesce(var_pop(h.lon * 111.32 * cos(radians(h.lat))), 0))  as dispersao_km,
         max(h.particao)                                                       as particao
  from public.nio_hp h
  group by h.uf, h.municipio, h.bairro
),
m as (
  select b.uf, b.municipio, percentile_cont(0.5) within group (order by b.pct_aprov_bairro) as mediana
  from b where b.pct_aprov_bairro is not null group by b.uf, b.municipio
)
select b.uf, b.municipio, b.bairro, b.fachadas, b.hp_tot, b.hp_livre,
       round(b.hp_livre::numeric / nullif(b.hp_tot, 0), 4)                    as pct_livre,
       b.hc_tot, b.hp_emp, b.pct_aprov_bairro, b.qt_propostas_bairro,
       (b.pct_aprov_bairro is null)                                           as aprov_estimada,
       round(b.pct_alto_medio, 4)                                             as pct_alto_medio,
       round(b.pct_ab_c, 4)                                                   as pct_ab_c,
       round(b.lat_centro::numeric, 6)                                        as lat_centro,
       round(b.lon_centro::numeric, 6)                                        as lon_centro,
       round((1.5 * b.dispersao_km)::numeric, 1)                              as raio_km,
       round((b.hp_livre * coalesce(b.pct_aprov_bairro, m.mediana::numeric, 0.5) * (0.5 + 0.5 * b.pct_alto_medio))::numeric, 0) as score,
       b.particao
from b
left join m on m.uf = b.uf and m.municipio = b.municipio
order by score desc nulls last, b.hp_livre desc;

create view public.v_dfv_resumo
with (security_invoker = true) as
select h.uf, h.municipio, max(h.particao) as particao,
       count(*)::int                                                     as fachadas,
       sum(h.hp_tot)::int                                                as hp_tot,
       sum(h.hp_livre)::int                                              as hp_livre,
       sum(h.hc_tot)::int                                                as hc_tot,
       round(sum(h.hc_tot)::numeric / nullif(sum(h.hp_tot), 0), 4)       as pct_ocupacao,
       count(*) filter (where h.hp_tot = 1 and h.hc_tot >= 1)::int       as casas_ocupadas,
       count(*) filter (where h.tipo_edificacao = 'VERTICAL')::int       as predios,
       count(distinct h.bairro)::int                                     as bairros,
       count(distinct h.cep)::int                                        as ceps,
       (select i.aplicado_em from public.importacoes i
         where i.tipo = 'dfv_hp' and i.aplicado_em is not null order by i.aplicado_em desc limit 1) as aplicado_em
from public.nio_hp h
group by h.uf, h.municipio;

grant select on public.v_dfv_bairros, public.v_dfv_resumo to authenticated;
revoke all on public.v_dfv_bairros, public.v_dfv_resumo from anon;
