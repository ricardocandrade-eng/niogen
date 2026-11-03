-- NIOGEN | supabase/migrations/0005_tabela_vigente_221026.sql | 03/11/2026
-- Tabela vigente da Nio (portfólio out/26 + Política Comercial PAP de 22/10/2026), fonte: docs/TABELA_VIGENTE_NIO_031126_1030.md.
-- Planos reais no lugar dos EXEMPLO, serviços adicionais, bônus, comissão calculada no banco (recalcular_comissao),
-- vencimento calculado a partir de instalado_em (deixa de ser digitado), área fixa em Juiz de Fora e os 38 municípios de MG da GDP.
--
-- Passo 0 (banco real em 03/11, antes desta migration): config_planos com 5 linhas "EXEMPLO …" (ids 1–5), 0 vendas,
-- config_area = só Juiz de Fora. Diferença do que o prompt supunha: config_planos.segmento era NOT NULL (liberado aqui);
-- v_alertas_contrato não usa comissão/plano/vencimento, mas depende de v_funil e por isso é recriada junto.

-- ============================================================================
-- config_planos — colunas novas (a tabela não é recriada)
-- ============================================================================

alter table public.config_planos
  alter column segmento drop not null,                                     -- deprecada: a escolha usa `segmentos`
  add column portfolio        text check (portfolio in ('varejo', 'empresas')),
  add column variante         text check (variante in ('regular', 'nfid', 'oferta50', 'oferta50_nfid')),  -- nfid = sem fidelidade, taxa à vista
  add column cluster          text check (cluster in ('regular', 'btu')),  -- qual tabela de comissão se aplica
  add column segmentos        text[],                                      -- varejo = {PF}; empresas = {MEI,NMEI}
  add column preco_cartao     numeric,                                     -- null = sem preço diferente no cartão
  add column taxa_habilitacao numeric default 540,
  add column isencao_meses    int,
  add column taxa_a_vista     boolean default false,
  add column velocidade_mb    int,
  add column wifi             text,
  add column internet_5g      text,
  add column inclusos         text[],
  add column codigo           text unique,
  add column observacao       text;

comment on column public.config_planos.preco    is 'Preço boleto/débito (R$/mês).';
comment on column public.config_planos.comissao is 'Comissão nominal da Dharma com biometria aprovada (Política Comercial PAP).';
comment on column public.config_planos.segmento is 'DEPRECADA desde 0005 — usar segmentos.';

-- EXEMPLO sai. Se alguma venda apontar para um deles, só desativa (e avisa).
do $$
begin
  if exists (select 1 from public.vendas v join public.config_planos p on p.id = v.plano_id where p.nome like 'EXEMPLO%') then
    update public.config_planos set ativo = false, vigencia_fim = date '2026-10-21' where nome like 'EXEMPLO%';
    raise notice 'Planos EXEMPLO referenciados por vendas: desativados, não apagados.';
  else
    delete from public.config_planos where nome like 'EXEMPLO%';
  end if;
end $$;

insert into public.config_planos
  (codigo, portfolio, variante, cluster, segmentos, nome, familia, velocidade, velocidade_mb, wifi, internet_5g, inclusos,
   preco, preco_cartao, comissao, taxa_habilitacao, isencao_meses, taxa_a_vista, forma_pagamento_permitida,
   vigencia_inicio, vigencia_fim, ativo, observacao)
select p.codigo, p.portfolio, p.variante, p.cluster, p.segmentos, p.nome, p.familia, p.velocidade, p.velocidade_mb, p.wifi, p.internet_5g, p.inclusos,
       p.preco, p.preco_cartao, p.comissao, 540, p.isencao_meses, p.taxa_a_vista, array['boleto', 'dacc', 'cartao'],
       date '2026-10-22', null, p.ativo, p.observacao
from (
  with base(sufixo, familia, velocidade, mb, wifi, g5, inclusos, preco, cartao, comissao, o50_preco, o50_comissao) as (values
    ('FIBRA', 'Fibra',     '600 Mega', 600,  'Wi-Fi 5',                       null::text,                               null::text[],                                               110, 95,  350, 55,  263),
    ('ESS',   'Essencial', '800 Mega', 800,  'Wi-Fi 6',                       '10 GB + chamadas ilimitadas',            null::text[],                                               140, 125, 450, 70,  338),
    ('SUP',   'Super',     '1 Giga',   1000, 'Wi-Fi 6',                       '20 GB + chamadas ilimitadas',            array['Globoplay Padrão com Anúncios 12 meses'],            170, 155, 500, 85,  375),
    ('ULT',   'Ultra',     '1 Giga',   1000, 'Wi-Fi 6 + 1 ponto extra Mesh',  '2 chips × 20 GB + chamadas ilimitadas',  array['1 ponto extra Mesh', 'Globoplay 12 meses'],          200, 185, 550, 100, 413)
  ),
  nomes(sufixo, nome) as (values
    ('FIBRA', 'Nio Fibra 600 Mega'), ('ESS', 'Nio Essencial 800 Mega + 10 GB'),
    ('SUP', 'Nio Super 1 Giga + 20 GB'), ('ULT', 'Nio Ultra 1 Giga + Mesh + 2×20 GB')
  )
  -- Varejo Regular
  select 'V-REG-' || b.sufixo as codigo, 'varejo' as portfolio, 'regular' as variante, 'regular' as cluster, array['PF'] as segmentos,
         n.nome, b.familia, b.velocidade, b.mb as velocidade_mb, b.wifi, b.g5 as internet_5g, b.inclusos,
         b.preco::numeric as preco, b.cartao::numeric as preco_cartao, b.comissao::numeric as comissao,
         12 as isencao_meses, false as taxa_a_vista, true as ativo, null::text as observacao
  from base b join nomes n using (sufixo)
  union all
  -- Varejo NFID (sem fidelidade): mesma tabela, taxa à vista, comissão Regular até a 1ª conciliação dizer outra coisa
  select 'V-NFID-' || b.sufixo, 'varejo', 'nfid', 'regular', array['PF'],
         n.nome || ' (sem fidelidade)', b.familia, b.velocidade, b.mb, b.wifi, b.g5, b.inclusos,
         b.preco, b.cartao, b.comissao, null, true, true,
         'Sem fidelidade: taxa de R$ 540 à vista na 1ª fatura. Só se o cliente pedir. Comissão a confirmar na 1ª conciliação (usa a Regular).'
  from base b join nomes n using (sufixo)
  union all
  -- Oferta 50%: desligada até o gerente confirmar (provável tabela BTU, comissão Especial). Sem desconto no cartão.
  select 'V-O50-' || b.sufixo, 'varejo', 'oferta50', 'btu', array['PF'],
         n.nome || ' (Oferta 50%)', b.familia, b.velocidade, b.mb, b.wifi, b.g5, null,
         b.o50_preco, null, b.o50_comissao, 12, false, false,
         'Desligado até o gerente confirmar se é a tabela BTU e paga comissão Especial. Serviços inclusos reduzidos (ver book).'
  from base b join nomes n using (sufixo)
  union all
  -- Empresas Regular (Juiz de Fora) — habilitação isenta após 24 meses
  select e.codigo, 'empresas', 'regular', 'regular', array['MEI', 'NMEI'],
         e.nome, e.familia, e.velocidade, e.mb, e.wifi, e.g5, array['Maquininha PagBank', 'McAfee'] || e.extra,
         e.preco, e.cartao, e.comissao, 24, false, true, null
  from (values
    ('E-REG-FIBRA', 'Nio Empresas Fibra 400 Mega',              'Fibra',     '400 Mega', 400,  'Wi-Fi 5', null::text,        array[]::text[],         70::numeric,  null::numeric, 120::numeric),
    ('E-REG-ESS',   'Nio Empresas Essencial 700 Mega + 10 GB',  'Essencial', '700 Mega', 700,  'Wi-Fi 6', '10 GB',           array['Revista Exame'],  110, 95,  350),
    ('E-REG-SUP',   'Nio Empresas Super 800 Mega + 20 GB',      'Super',     '800 Mega', 800,  'Wi-Fi 6', '20 GB',           array['Revista Exame'],  130, 115, 450),
    ('E-REG-ULT',   'Nio Empresas Ultra 1 Giga + 2×20 GB',      'Ultra',     '1 Giga',   1000, 'Wi-Fi 6', '2 chips × 20 GB', array['Revista Exame'],  180, 165, 500)
  ) as e(codigo, nome, familia, velocidade, mb, wifi, g5, extra, preco, cartao, comissao)
) p;

-- ============================================================================
-- Serviços adicionais
-- ============================================================================

create table public.config_adicionais (
  id               bigint generated always as identity primary key,
  codigo           text not null unique,
  nome             text not null,
  portfolio        text[] not null,
  preco            numeric,                       -- null = preço ao cliente não consta no book
  comissao         numeric not null,
  max_por_contrato int not null default 1,
  ativo            boolean not null default true,
  vigencia_inicio  date not null default date '2026-10-22'
);

insert into public.config_adicionais (codigo, nome, portfolio, preco, comissao, max_por_contrato, ativo) values
  ('FIXO',           'Telefone Fixo (ligações ilimitadas Brasil)', array['varejo', 'empresas'], 30,    30, 1, true),
  ('MESH',           'Wi-Fi Total – ponto extra Mesh',             array['varejo', 'empresas'], 30,    30, 3, true),
  ('GLOBO_ANUNCIOS', 'Globoplay Padrão com Anúncios',              array['varejo'],             22.90, 23, 1, true),
  ('GLOBO_PREMIUM',  'Globoplay Premium',                          array['varejo'],             39.90, 40, 1, true),
  ('MAX',            'Max',                                        array['varejo'],             null,  40, 1, false),
  ('PARAMOUNT',      'Paramount',                                  array['varejo'],             null,  28, 1, false);

create table public.venda_adicionais (
  id                bigint generated always as identity primary key,
  venda_id          uuid not null references public.vendas (id) on delete cascade,
  adicional_id      bigint not null references public.config_adicionais (id),
  qtd               int not null default 1 check (qtd between 1 and 3),
  comissao_prevista numeric,
  unique (venda_id, adicional_id)
);
create index venda_adicionais_venda_idx on public.venda_adicionais (venda_id);

-- ============================================================================
-- Bônus (Política Comercial PAP 22/10/2026, §4 da TABELA_VIGENTE)
-- ============================================================================

create table public.config_bonus (
  id           bigint generated always as identity primary key,
  tipo         text not null check (tipo in ('transicao', 'm10', 'nmei')),
  cluster      text not null check (cluster in ('regular', 'btu')),
  plano_codigo text,                               -- null = vale para todos os planos do cluster
  valor        numeric not null,
  valido_de    date not null,
  valido_ate   date,
  observacao   text
);

insert into public.config_bonus (tipo, cluster, plano_codigo, valor, valido_de, valido_ate, observacao) values
  ('transicao', 'regular', null, 30, date '2026-11-01', date '2027-01-31',
   'Faixa mínima dos meses 1–3 da operação; do 4º ao 10º mês a faixa depende do gross do bimestre (70/50/30) — cálculo fica para depois.'),
  ('transicao', 'btu',     null, 23, date '2026-11-01', date '2027-01-31',
   'Faixa mínima dos meses 1–3 da operação; do 4º ao 10º mês a faixa depende do gross do bimestre (53/38/23) — cálculo fica para depois.'),
  ('m10', 'regular', null, 150, date '2026-10-22', null, 'No 10º mês ativo, adimplente (nenhuma fatura > 15 dias em atraso) e sem downgrade. Só potencial: não entra na comissão prevista.'),
  ('m10', 'btu',     null, 113, date '2026-10-22', null, 'No 10º mês ativo, adimplente (nenhuma fatura > 15 dias em atraso) e sem downgrade. Só potencial: não entra na comissão prevista.'),
  ('nmei', 'regular', 'E-REG-FIBRA', 120, date '2026-10-22', null, 'PJ não-MEI. Safra a partir de jun/26; não acumula com outras ações de incentivo.'),
  ('nmei', 'regular', 'E-REG-ESS',   150, date '2026-10-22', null, 'PJ não-MEI. Safra a partir de jun/26; não acumula com outras ações de incentivo.'),
  ('nmei', 'regular', 'E-REG-SUP',   150, date '2026-10-22', null, 'PJ não-MEI. Safra a partir de jun/26; não acumula com outras ações de incentivo.'),
  ('nmei', 'regular', 'E-REG-ULT',   150, date '2026-10-22', null, 'PJ não-MEI. Safra a partir de jun/26; não acumula com outras ações de incentivo.'),
  ('nmei', 'btu',     'E-REG-ESS',   113, date '2026-10-22', null, 'PJ não-MEI, tabela Especial/BTU.'),
  ('nmei', 'btu',     'E-REG-SUP',   113, date '2026-10-22', null, 'PJ não-MEI, tabela Especial/BTU.'),
  ('nmei', 'btu',     'E-REG-ULT',   113, date '2026-10-22', null, 'PJ não-MEI, tabela Especial/BTU.');

-- ============================================================================
-- Área: só Juiz de Fora ativa até o gerente responder · municípios da GDP (referência, não autoriza venda)
-- ============================================================================

alter table public.config_area
  add column cluster text not null default 'regular' check (cluster in ('regular', 'btu'));

update public.config_area set ativo = false
where not (cidade = 'Juiz de Fora' and bairro is null and uf = 'MG');
insert into public.config_area (cidade, bairro, uf, ativo, cluster)
select 'Juiz de Fora', null, 'MG', true, 'regular'
where not exists (select 1 from public.config_area where cidade = 'Juiz de Fora' and bairro is null and uf = 'MG');
update public.config_area set ativo = true, cluster = 'regular'
where cidade = 'Juiz de Fora' and bairro is null and uf = 'MG';

create table public.nio_municipios (
  uf            text not null,
  municipio     text not null,
  cluster       text not null check (cluster in ('regular', 'btu')),
  cod_ibge      int,
  fonte         text not null default 'GDP 28/10/2026 · 20261029_B2B_GDPx 1.xlsx (aba Todos os Canais, PORTFOLIO_GDP_28_10)',
  atualizado_em timestamptz not null default now(),
  primary key (uf, municipio)
);
comment on table public.nio_municipios is
  'Municípios que a Nio atende (GDP). Só referência — "a Nio atende sua cidade, mas não pela Dharma". Não autoriza venda: quem autoriza é config_area.';

insert into public.nio_municipios (uf, municipio, cluster, cod_ibge) values
  ('MG', 'Araguari', 'btu', 3103504),
  ('MG', 'Belo Horizonte', 'regular', 3106200),
  ('MG', 'Betim', 'regular', 3106705),
  ('MG', 'Cataguases', 'regular', 3115300),
  ('MG', 'Caxambu', 'btu', 3115508),
  ('MG', 'Conselheiro Lafaiete', 'regular', 3118304),
  ('MG', 'Contagem', 'regular', 3118601),
  ('MG', 'Coronel Fabriciano', 'btu', 3119401),
  ('MG', 'Divinópolis', 'regular', 3122306),
  ('MG', 'Esmeraldas', 'regular', 3124104),
  ('MG', 'Governador Valadares', 'btu', 3127701),
  ('MG', 'Ibirité', 'regular', 3129806),
  ('MG', 'Ipatinga', 'btu', 3131307),
  ('MG', 'Itabira', 'btu', 3131703),
  ('MG', 'João Monlevade', 'btu', 3136207),
  ('MG', 'Juiz de Fora', 'regular', 3136702),
  ('MG', 'Justinópolis', 'regular', 3154606),
  ('MG', 'Lavras', 'btu', 3138203),
  ('MG', 'Leopoldina', 'regular', 3138401),
  ('MG', 'Montes Claros', 'btu', 3143302),
  ('MG', 'Muriaé', 'btu', 3143906),
  ('MG', 'Nova Lima', 'regular', 3144805),
  ('MG', 'Paracatu', 'btu', 3147006),
  ('MG', 'Patrocínio', 'btu', 3148103),
  ('MG', 'Poços de Caldas', 'btu', 3151800),
  ('MG', 'Pouso Alegre', 'regular', 3152501),
  ('MG', 'Ribeirão das Neves', 'regular', 3154606),
  ('MG', 'Sabará', 'btu', 3156700),
  ('MG', 'Santa Luzia', 'regular', 3157807),
  ('MG', 'Santa Rita do Sapucaí', 'regular', 3159605),
  ('MG', 'São Lourenço', 'regular', 3163706),
  ('MG', 'Serra del Rei', 'regular', 3162500),
  ('MG', 'Sete Lagoas', 'regular', 3167202),
  ('MG', 'Timóteo', 'btu', 3168705),
  ('MG', 'Ubá', 'regular', 3169901),
  ('MG', 'Varginha', 'regular', 3170701),
  ('MG', 'Venda Nova', 'regular', 3106200),
  ('MG', 'Vespasiano', 'regular', 3171204);

-- ============================================================================
-- vendas — valor mensal, partes da comissão, 1º vencimento
-- ============================================================================

alter table public.vendas
  add column valor_mensal             numeric,                 -- preço ou preço no cartão, conforme a forma (sem adicionais)
  add column comissao_nominal         numeric not null default 0,
  add column comissao_adicionais      numeric not null default 0,
  add column bonus_transicao_previsto numeric not null default 0,
  add column bonus_nmei_previsto      numeric not null default 0,
  add column bonus_m10_potencial      numeric not null default 0, -- só potencial; NÃO entra em comissao_prevista
  add column primeiro_vencimento      date;

comment on column public.vendas.comissao_prevista is
  'nominal + adicionais + transição + NMEI (calculada por recalcular_comissao). O M-10 fica fora: bonus_m10_potencial.';
comment on column public.vendas.vencimento_dia is
  'Calculado (vendas_calcula_vencimento): boleto/débito = dia de primeiro_vencimento, ou 26 se instalou em 29–31; cartão = dia da instalação.';

-- ============================================================================
-- Comissão calculada
-- ============================================================================

create or replace function public.recalcular_comissao(p_venda_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v       public.vendas%rowtype;
  p       public.config_planos%rowtype;
  d       date;
  v_valor numeric;
  n_nom   numeric := 0;
  n_adi   numeric := 0;
  n_tra   numeric := 0;
  n_nmei  numeric := 0;
  n_m10   numeric := 0;
begin
  select * into v from public.vendas where id = p_venda_id;
  if not found then
    return;
  end if;

  -- Bônus com validade usam a data da venda (ou hoje, se ainda não vendida).
  d := (coalesce(v.vendido_em, now()) at time zone 'America/Sao_Paulo')::date;

  select coalesce(sum(a.comissao_prevista), 0) into n_adi
  from public.venda_adicionais a where a.venda_id = p_venda_id;

  if v.plano_id is not null then
    select * into p from public.config_planos where id = v.plano_id;
    n_nom   := coalesce(p.comissao, 0);
    v_valor := case when v.forma_pagamento = 'cartao' then coalesce(p.preco_cartao, p.preco) else p.preco end;

    select coalesce((
      select b.valor from public.config_bonus b
      where b.tipo = 'transicao' and b.cluster = p.cluster
        and (b.plano_codigo is null or b.plano_codigo = p.codigo)
        and d >= b.valido_de and (b.valido_ate is null or d <= b.valido_ate)
      order by b.plano_codigo nulls last, b.valido_de desc limit 1), 0) into n_tra;

    if v.segmento = 'NMEI' and p.portfolio = 'empresas' then
      select coalesce((
        select b.valor from public.config_bonus b
        where b.tipo = 'nmei' and b.cluster = p.cluster
          and (b.plano_codigo is null or b.plano_codigo = p.codigo)
          and d >= b.valido_de and (b.valido_ate is null or d <= b.valido_ate)
        order by b.plano_codigo nulls last, b.valido_de desc limit 1), 0) into n_nmei;
    end if;

    select coalesce((
      select b.valor from public.config_bonus b
      where b.tipo = 'm10' and b.cluster = p.cluster
        and (b.plano_codigo is null or b.plano_codigo = p.codigo)
        and d >= b.valido_de and (b.valido_ate is null or d <= b.valido_ate)
      order by b.plano_codigo nulls last, b.valido_de desc limit 1), 0) into n_m10;
  end if;

  update public.vendas set
    valor_mensal             = v_valor,
    comissao_nominal         = n_nom,
    comissao_adicionais      = n_adi,
    bonus_transicao_previsto = n_tra,
    bonus_nmei_previsto      = n_nmei,
    bonus_m10_potencial      = n_m10,
    comissao_prevista        = n_nom + n_adi + n_tra + n_nmei
  where id = p_venda_id;
end;
$$;

create or replace function public.vendas_recalcula_comissao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recalcular_comissao(new.id);
  return null;
end;
$$;

-- status entra na lista porque o trigger de status grava vendido_em sem que a coluna esteja no SET.
-- O UPDATE de recalcular_comissao só mexe em colunas de comissão: não dispara este trigger de novo.
create trigger vendas_recalcula_comissao
  after insert or update of plano_id, segmento, forma_pagamento, vendido_em, status on public.vendas
  for each row execute function public.vendas_recalcula_comissao();

-- Adicional: comissão = comissão do serviço × quantidade; respeita máximo por contrato, ativo e portfólio do plano.
create or replace function public.venda_adicionais_antes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  a      public.config_adicionais%rowtype;
  v_port text;
begin
  select * into a from public.config_adicionais where id = new.adicional_id;
  if not a.ativo then
    raise exception 'Serviço adicional "%" não está disponível.', a.nome using errcode = 'P0001';
  end if;
  if new.qtd > a.max_por_contrato then
    raise exception '"%": no máximo % por contrato.', a.nome, a.max_por_contrato using errcode = 'P0001';
  end if;
  select p.portfolio into v_port
  from public.vendas v join public.config_planos p on p.id = v.plano_id
  where v.id = new.venda_id;
  if v_port is not null and not (v_port = any (a.portfolio)) then
    raise exception '"%" não é vendido no portfólio %.', a.nome, initcap(v_port) using errcode = 'P0001';
  end if;
  new.comissao_prevista := a.comissao * new.qtd;
  return new;
end;
$$;

create or replace function public.venda_adicionais_depois()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recalcular_comissao(coalesce(new.venda_id, old.venda_id));
  return null;
end;
$$;

create trigger venda_adicionais_antes
  before insert or update on public.venda_adicionais
  for each row execute function public.venda_adicionais_antes();
create trigger venda_adicionais_depois
  after insert or update or delete on public.venda_adicionais
  for each row execute function public.venda_adicionais_depois();

-- ============================================================================
-- Vencimento calculado (TABELA_VIGENTE §6)
-- Boleto/débito: 1º vencimento = instalação + 25 d; dia recorrente = dia do 1º vencimento, ou 26 se instalou em 29–31.
-- Cartão: cobra no dia da instalação, todo mês.
-- Nome escolhido para rodar DEPOIS de vendas_antes_status (BEFORE roda em ordem alfabética), que grava instalado_em no status 3.
-- ============================================================================

create or replace function public.vendas_calcula_vencimento()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  d date;
begin
  if tg_op = 'UPDATE'
     and new.instalado_em is not distinct from old.instalado_em
     and new.forma_pagamento is not distinct from old.forma_pagamento then
    return new;
  end if;

  if new.instalado_em is null then
    new.primeiro_vencimento := null;
    new.vencimento_dia := null;
  else
    d := (new.instalado_em at time zone 'America/Sao_Paulo')::date;
    if new.forma_pagamento = 'cartao' then
      new.primeiro_vencimento := d;
      new.vencimento_dia := extract(day from d)::int;
    else
      new.primeiro_vencimento := d + 25;
      new.vencimento_dia := case when extract(day from d) >= 29 then 26 else extract(day from d + 25)::int end;
    end if;
  end if;
  return new;
end;
$$;

create trigger vendas_calcula_vencimento
  before insert or update on public.vendas
  for each row execute function public.vendas_calcula_vencimento();

revoke execute on function public.recalcular_comissao(uuid)       from public, anon, authenticated;
revoke execute on function public.vendas_recalcula_comissao()     from public, anon, authenticated;
revoke execute on function public.venda_adicionais_antes()        from public, anon, authenticated;
revoke execute on function public.venda_adicionais_depois()       from public, anon, authenticated;
revoke execute on function public.vendas_calcula_vencimento()     from public, anon, authenticated;

-- ============================================================================
-- RLS das tabelas novas
-- ============================================================================

alter table public.config_adicionais enable row level security;
alter table public.venda_adicionais  enable row level security;
alter table public.config_bonus      enable row level security;
alter table public.nio_municipios    enable row level security;

create policy config_adicionais_ler on public.config_adicionais
  for select to authenticated using (public.meu_perfil() is not null);
create policy config_adicionais_admin on public.config_adicionais
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

create policy config_bonus_ler on public.config_bonus
  for select to authenticated using (public.meu_perfil() is not null);
create policy config_bonus_admin on public.config_bonus
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

create policy nio_municipios_ler on public.nio_municipios
  for select to authenticated using (public.meu_perfil() is not null);
create policy nio_municipios_admin on public.nio_municipios
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');

-- venda_adicionais: quem vê a venda vê e mexe nos adicionais dela (o subselect passa pelo RLS de vendas).
create policy venda_adicionais_admin on public.venda_adicionais
  for all to authenticated using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
create policy venda_adicionais_operar on public.venda_adicionais
  for all to authenticated
  using (public.meu_perfil() in ('backoffice', 'vendedor') and venda_id in (select id from public.vendas))
  with check (public.meu_perfil() in ('backoffice', 'vendedor') and venda_id in (select id from public.vendas));

-- ============================================================================
-- Views recriadas (v.* passa a trazer as colunas novas; v_funil expõe o plano completo;
-- v_painel_mes expõe as partes da comissão — o M-10 nunca entra em comissao_prevista)
-- ============================================================================

drop view public.v_painel_hoje;
drop view public.v_painel_mes;
drop view public.v_alertas_contrato;
drop view public.v_instalacoes;
drop view public.v_funil;

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

grant select on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje to authenticated;
revoke all on public.v_funil, public.v_instalacoes, public.v_alertas_contrato, public.v_painel_mes, public.v_painel_hoje from anon;
