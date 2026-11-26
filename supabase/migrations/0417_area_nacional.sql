-- NIOGEN | 0417_area_nacional.sql | 26/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (26/11/2026 12h20): "A Dharma está autorizada a vender em todos os estados". Prompt:
--   docs/Prompt_area_nacional_niogen_mari_261126_1126.md, Parte A (seções 1, 2, 3, 4, 6, 7). Meta Ads e textos da Mari ficam fora.
-- O que faz:
--   1. config_area ganha os dados da GDP (origem gdp|conurbada, cidade_polo, cod_ibge, ddd, portfolio_gdp, gdp_versao, municipio_gdp)
--      e passa a ter as 345 cidades da carteira (GDP 28/10/2026). As 38 de MG ficam como estavam (conferido 1:1 no fim).
--   2. public.area_norm(texto): sem acento, maiúsculas, hífen vira espaço. cluster_da_area compara por ela (mesma assinatura):
--      "Divinopolis" e "Divinópolis" são a mesma cidade, e um nome do ViaCEP casa com o texto da GDP.
--   3. Carga repetível: public.area_carregar_gdp(json, data) (só admin/CLI). Atualiza os dados da Nio, cria a cidade nova DESLIGADA,
--      nunca mexe em ativo nem no cluster de cidade que já existe. O mesmo para nio_municipios (espelho de referência).
--   4. Liga/desliga com histórico: area_ativar_uf(uf, ativa, motivo) e area_ativar_cidade(id, ativa, motivo), só admin;
--      cada cidade que muda vira uma linha em area_ativa_hist (de/para, motivo, quem, quando).
--   5. Ativas: as 320 cidades das 21 UFs de fuso −3. Desligadas: as 25 de AC, AM, RR, RO, MT e MS — motivo "fuso_pendente"
--      (os toques 9h–21h são calculados em America/Sao_Paulo; o fuso por UF é decisão do Ricardo, PENDENCIAS).
--   6. conferencia_itens ganha o item 41: cidade ativa cujo cluster difere do portfólio da GDP vigente.
--   6b. O texto da Saída "Cidade não atendida" (config_mari_textos, com e sem indicação) para de dizer "cidades de Minas".
--      Os textos do prompt/base da Mari ficam para a Parte A2 (portão da Mari parado até 01/12).
-- Regra 20: (1) nada muda no ciclo do lead — a área só decide se ele entra; (2) e (3) nenhuma gravação de estado de lead:
--   area_ativar_* mexe em configuração; a carga não toca em vendas nem em mari_conversas; (4) a área vem da GDP da Nio
--   (gdp_versao carimba qual); (5) item 41 na conferência.
-- Fila Vero (seção 2 do prompt): a fila_vero_filtrar() das "38 cidades" não existe mais (apagada na 0286, 18/11). O único que
--   marca "apto" é fila_vero_filtrar_jf (só Juiz de Fora), e nenhuma função da Fila Vero lê config_area — esta carga não libera
--   disparo nenhum. A Fila Vero segue desligada.
begin;

-- 0. Retrato das 38 antes -----------------------------------------------------------------------------------------------------
create temp table _area_antes on commit drop as
  select id, uf, cidade, cluster, ativo, bairro from public.config_area;
do $$
begin
  if (select count(*) from _area_antes) <> 38
     or exists (select 1 from _area_antes where uf <> 'MG' or not ativo or bairro is not null) then
    raise exception '0417: config_area não é mais a das 38 de MG ativas (% linhas) — parar e conferir antes de carregar',
      (select count(*) from _area_antes);
  end if;
end $$;

-- 1. Normalização e colunas da GDP --------------------------------------------------------------------------------------------
create or replace function public.area_norm(p text)
returns text language sql immutable parallel safe set search_path to '' as $$
  select nullif(btrim(regexp_replace(
           replace(replace(replace(upper(translate(coalesce(p, ''),
             'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
             'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '''', ''), '´', ''), '`', ''),
           '[^A-Z0-9]+', ' ', 'g')), '')
$$;
comment on function public.area_norm(text) is '0417: nome de cidade sem acento, em maiúsculas, hífen e pontuação viram espaço — a chave de comparação da área.';

alter table public.config_area
  add column if not exists origem        text check (origem in ('gdp', 'conurbada')),
  add column if not exists cidade_polo   text,
  add column if not exists cod_ibge      integer,
  add column if not exists ddd           integer,
  add column if not exists portfolio_gdp text,
  add column if not exists gdp_versao    date,
  add column if not exists municipio_gdp text;
comment on column public.config_area.municipio_gdp is '0417: o nome do município como a GDP da Nio escreve (sem acento) — chave da carga repetível.';
comment on column public.config_area.portfolio_gdp is '0417: portfólio da GDP vigente (REGULAR MÓVEL | BTU MÓVEL); a conferência compara com cluster.';

create unique index if not exists config_area_uf_cidade_norm on public.config_area (upper(uf), public.area_norm(cidade)) where bairro is null;
create unique index if not exists config_area_uf_municipio_gdp on public.config_area (uf, municipio_gdp) where municipio_gdp is not null;

-- 2. cluster_da_area: mesma assinatura, compara pelo nome normalizado (continua só cidade ativa) ----------------------------------
create or replace function public.cluster_da_area(p_cidade text, p_uf text, p_bairro text default null)
returns text language sql stable set search_path to 'public' as $$
  select a.cluster
  from public.config_area a
  where a.ativo
    and upper(a.uf) = upper(btrim(coalesce(p_uf, 'MG')))
    and public.area_norm(a.cidade) = public.area_norm(p_cidade)
    and (a.bairro is null or public.area_norm(a.bairro) = public.area_norm(p_bairro))
  order by a.bairro nulls last
  limit 1
$$;
create index if not exists config_area_busca on public.config_area (upper(uf), public.area_norm(cidade));

-- 3. Histórico e liga/desliga --------------------------------------------------------------------------------------------------
create table if not exists public.area_ativa_hist (
  id          bigint generated always as identity primary key,
  parceiro_id text not null default 'dharma',
  area_id     bigint not null,
  uf          text not null,
  cidade      text not null,
  de          boolean,
  para        boolean not null,
  motivo      text not null,
  autor       text not null,
  em          timestamptz not null default now()
);
alter table public.area_ativa_hist enable row level security;
drop policy if exists area_ativa_hist_admin on public.area_ativa_hist;
create policy area_ativa_hist_admin on public.area_ativa_hist for select to authenticated
  using ((select public.meu_perfil()) = 'admin');
revoke all on public.area_ativa_hist from anon;

create or replace function public._area_ativar(p_uf text, p_area_id bigint, p_ativa boolean, p_motivo text, p_autor text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if p_ativa is null or coalesce(btrim(p_motivo), '') = '' then
    raise exception 'Diga se liga ou desliga e o motivo.' using errcode = 'P0001';
  end if;
  with alvo as (
    select a.id, a.uf, a.cidade, a.ativo from public.config_area a
     where (p_area_id is not null and a.id = p_area_id)
        or (p_area_id is null and upper(a.uf) = upper(btrim(p_uf)))
     for update),
  muda as (
    update public.config_area a set ativo = p_ativa from alvo
     where a.id = alvo.id and a.ativo is distinct from p_ativa
     returning a.id, a.uf, a.cidade, alvo.ativo as de)
  insert into public.area_ativa_hist (area_id, uf, cidade, de, para, motivo, autor)
  select id, uf, cidade, de, p_ativa, btrim(p_motivo), p_autor from muda;
  get diagnostics n = row_count;
  return jsonb_build_object('mudaram', n,
    'ativas_na_uf', (select count(*) from public.config_area a
                      where a.ativo and upper(a.uf) = upper(coalesce(btrim(p_uf), (select uf from public.config_area where id = p_area_id)))));
end $$;
revoke all on function public._area_ativar(text, bigint, boolean, text, text) from public, anon, authenticated;

create or replace function public.area_ativar_uf(p_uf text, p_ativa boolean, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' and session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'Só admin liga ou desliga área.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.config_area where upper(uf) = upper(btrim(p_uf))) then
    raise exception 'A UF % não tem cidade na carteira da Nio (config_area).', p_uf using errcode = 'P0001';
  end if;
  return public._area_ativar(p_uf, null, p_ativa, p_motivo,
    coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), session_user::text));
end $$;
revoke all on function public.area_ativar_uf(text, boolean, text) from public, anon;
grant execute on function public.area_ativar_uf(text, boolean, text) to authenticated;

create or replace function public.area_ativar_cidade(p_area_id bigint, p_ativa boolean, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' and session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'Só admin liga ou desliga área.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.config_area where id = p_area_id) then
    raise exception 'Cidade % não está em config_area.', p_area_id using errcode = 'P0001';
  end if;
  return public._area_ativar(null, p_area_id, p_ativa, p_motivo,
    coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), session_user::text));
end $$;
revoke all on function public.area_ativar_cidade(bigint, boolean, text) from public, anon;
grant execute on function public.area_ativar_cidade(bigint, boolean, text) to authenticated;

-- 4. Carga repetível da GDP ----------------------------------------------------------------------------------------------------
create or replace function public.area_carregar_gdp(p_linhas jsonb, p_versao date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  x jsonb; v_id bigint; v_cl text; v_cluster_atual text; v_nome text;
  n_novas int := 0; n_atu int := 0; n_dif int := 0; novas text[] := '{}';
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' and session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'Só admin carrega a GDP.' using errcode = '42501';
  end if;
  if p_versao is null or jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) = 0 then
    raise exception 'Carga vazia ou sem a data da GDP.' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_array_elements(p_linhas) loop
    v_cl := case x ->> 'portfolio' when 'REGULAR MÓVEL' then 'regular' when 'BTU MÓVEL' then 'btu' end;
    if v_cl is null or coalesce(x ->> 'uf', '') = '' or coalesce(x ->> 'municipio_gdp', '') = '' or coalesce(x ->> 'cidade', '') = '' then
      raise exception 'Linha da GDP inválida (portfólio, UF, município ou nome): %', x using errcode = 'P0001';
    end if;
    v_id := null;
    select a.id, a.cluster, a.cidade into v_id, v_cluster_atual, v_nome from public.config_area a
     where a.bairro is null and upper(a.uf) = upper(x ->> 'uf')
       and (a.municipio_gdp = x ->> 'municipio_gdp'
            or (a.municipio_gdp is null and public.area_norm(a.cidade) = public.area_norm(x ->> 'municipio_gdp')))
     order by (a.municipio_gdp is not null) desc limit 1;
    if v_id is null then
      insert into public.config_area (cidade, uf, ativo, cluster, origem, cidade_polo, cod_ibge, ddd, portfolio_gdp, gdp_versao, municipio_gdp)
      values (x ->> 'cidade', upper(x ->> 'uf'), false, v_cl, x ->> 'origem', nullif(x ->> 'cidade_polo', ''),
              (x ->> 'cod_ibge')::int, (x ->> 'ddd')::int, x ->> 'portfolio', p_versao, x ->> 'municipio_gdp');
      v_nome := x ->> 'cidade';
      n_novas := n_novas + 1; novas := novas || (upper(x ->> 'uf') || ' ' || v_nome);
    else
      update public.config_area set origem = x ->> 'origem', cidade_polo = nullif(x ->> 'cidade_polo', ''),
             cod_ibge = (x ->> 'cod_ibge')::int, ddd = (x ->> 'ddd')::int, portfolio_gdp = x ->> 'portfolio',
             gdp_versao = p_versao, municipio_gdp = x ->> 'municipio_gdp'
       where id = v_id;
      n_atu := n_atu + 1;
      if v_cluster_atual is distinct from v_cl then n_dif := n_dif + 1; end if;
    end if;
    insert into public.nio_municipios (uf, municipio, cluster, cod_ibge, fonte, atualizado_em)
    values (upper(x ->> 'uf'), v_nome, v_cl, (x ->> 'cod_ibge')::int,
            format('GDP %s · carga area_carregar_gdp (0417)', to_char(p_versao, 'DD/MM/YYYY')), now())
    on conflict (uf, municipio) do update set cluster = excluded.cluster, cod_ibge = excluded.cod_ibge,
           fonte = excluded.fonte, atualizado_em = excluded.atualizado_em;
  end loop;
  return jsonb_build_object('versao', p_versao, 'linhas', jsonb_array_length(p_linhas), 'novas_desligadas', n_novas,
                            'atualizadas', n_atu, 'cluster_diferente_da_gdp', n_dif,
                            'novas', to_jsonb(novas[1:20]));
end $$;
revoke all on function public.area_carregar_gdp(jsonb, date) from public, anon;
grant execute on function public.area_carregar_gdp(jsonb, date) to authenticated;

-- 5. A carga de 28/10/2026 e a ativação ----------------------------------------------------------------------------------------
select public.area_carregar_gdp($gdp$[
{"uf":"AC","municipio_gdp":"RIO BRANCO","cidade":"Rio Branco","origem":"gdp","cidade_polo":null,"cod_ibge":1200401,"ddd":68,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"AL","municipio_gdp":"ARAPIRACA","cidade":"Arapiraca","origem":"gdp","cidade_polo":null,"cod_ibge":2700300,"ddd":82,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"AL","municipio_gdp":"MACEIO","cidade":"Maceió","origem":"gdp","cidade_polo":null,"cod_ibge":2704302,"ddd":82,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"AL","municipio_gdp":"MARECHAL DEODORO","cidade":"Marechal Deodoro","origem":"gdp","cidade_polo":null,"cod_ibge":2704708,"ddd":82,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"AM","municipio_gdp":"MANAUS","cidade":"Manaus","origem":"gdp","cidade_polo":null,"cod_ibge":1302603,"ddd":92,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"AP","municipio_gdp":"MACAPA","cidade":"Macapá","origem":"gdp","cidade_polo":null,"cod_ibge":1600303,"ddd":96,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"BA","municipio_gdp":"BARREIRAS","cidade":"Barreiras","origem":"gdp","cidade_polo":null,"cod_ibge":2903201,"ddd":77,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"BA","municipio_gdp":"EUNAPOLIS","cidade":"Eunápolis","origem":"gdp","cidade_polo":null,"cod_ibge":2910727,"ddd":73,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"FEIRA DE SANTANA","cidade":"Feira de Santana","origem":"gdp","cidade_polo":null,"cod_ibge":2910800,"ddd":75,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"ILHEUS","cidade":"Ilhéus","origem":"gdp","cidade_polo":null,"cod_ibge":2913606,"ddd":73,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"ITABUNA","cidade":"Itabuna","origem":"gdp","cidade_polo":null,"cod_ibge":2914802,"ddd":73,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"JACOBINA","cidade":"Jacobina","origem":"gdp","cidade_polo":null,"cod_ibge":2917508,"ddd":74,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"BA","municipio_gdp":"JEQUIE","cidade":"Jequié","origem":"gdp","cidade_polo":null,"cod_ibge":2918001,"ddd":73,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"JUAZEIRO","cidade":"Juazeiro","origem":"gdp","cidade_polo":null,"cod_ibge":2918407,"ddd":74,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"BA","municipio_gdp":"LAURO DE FREITAS","cidade":"Lauro de Freitas","origem":"gdp","cidade_polo":null,"cod_ibge":2919207,"ddd":71,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"LUIS EDUARDO MAGALHAES","cidade":"Luís Eduardo Magalhães","origem":"gdp","cidade_polo":null,"cod_ibge":2919553,"ddd":77,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"PAULO AFONSO","cidade":"Paulo Afonso","origem":"gdp","cidade_polo":null,"cod_ibge":2924009,"ddd":75,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"PORTO SEGURO","cidade":"Porto Seguro","origem":"gdp","cidade_polo":null,"cod_ibge":2925303,"ddd":73,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"SALVADOR","cidade":"Salvador","origem":"gdp","cidade_polo":null,"cod_ibge":2927408,"ddd":71,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"BA","municipio_gdp":"SIMOES FILHO","cidade":"Simões Filho","origem":"gdp","cidade_polo":null,"cod_ibge":2930709,"ddd":71,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"BA","municipio_gdp":"TEIXEIRA DE FREITAS","cidade":"Teixeira de Freitas","origem":"gdp","cidade_polo":null,"cod_ibge":2931350,"ddd":73,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"BA","municipio_gdp":"VITORIA DA CONQUISTA","cidade":"Vitória da Conquista","origem":"gdp","cidade_polo":null,"cod_ibge":2933307,"ddd":77,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"CE","municipio_gdp":"FORTALEZA","cidade":"Fortaleza","origem":"gdp","cidade_polo":null,"cod_ibge":2304400,"ddd":85,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"CE","municipio_gdp":"IGUATU","cidade":"Iguatu","origem":"gdp","cidade_polo":null,"cod_ibge":2305506,"ddd":88,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"CE","municipio_gdp":"JUAZEIRO DO NORTE","cidade":"Juazeiro do Norte","origem":"gdp","cidade_polo":null,"cod_ibge":2307304,"ddd":88,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"CE","municipio_gdp":"SOBRAL","cidade":"Sobral","origem":"gdp","cidade_polo":null,"cod_ibge":2312908,"ddd":88,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"BRASILIA","cidade":"Brasília","origem":"gdp","cidade_polo":null,"cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"CACHOEIRO DE ITAPEMIRIM","cidade":"Cachoeiro de Itapemirim","origem":"gdp","cidade_polo":null,"cod_ibge":3201209,"ddd":28,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"ES","municipio_gdp":"CARIACICA","cidade":"Cariacica","origem":"gdp","cidade_polo":null,"cod_ibge":3201308,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"NOVA VENECIA","cidade":"Nova Venécia","origem":"gdp","cidade_polo":null,"cod_ibge":3203908,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"SAO GABRIEL DA PALHA","cidade":"São Gabriel da Palha","origem":"gdp","cidade_polo":null,"cod_ibge":3204708,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"SERRA","cidade":"Serra","origem":"gdp","cidade_polo":null,"cod_ibge":3205002,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"VIANA","cidade":"Viana","origem":"gdp","cidade_polo":null,"cod_ibge":3205101,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"VILA VELHA","cidade":"Vila Velha","origem":"gdp","cidade_polo":null,"cod_ibge":3205200,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"VITORIA","cidade":"Vitória","origem":"gdp","cidade_polo":null,"cod_ibge":3205309,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"AGUAS LINDAS DE GOIAS","cidade":"Águas Lindas de Goiás","origem":"gdp","cidade_polo":null,"cod_ibge":5200258,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"ANAPOLIS","cidade":"Anápolis","origem":"gdp","cidade_polo":null,"cod_ibge":5201108,"ddd":62,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"GO","municipio_gdp":"APARECIDA DE GOIANIA","cidade":"Aparecida de Goiânia","origem":"gdp","cidade_polo":null,"cod_ibge":5201405,"ddd":62,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"CATALAO","cidade":"Catalão","origem":"gdp","cidade_polo":null,"cod_ibge":5205109,"ddd":64,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"GO","municipio_gdp":"CIDADE OCIDENTAL","cidade":"Cidade Ocidental","origem":"gdp","cidade_polo":null,"cod_ibge":5205497,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"FORMOSA","cidade":"Formosa","origem":"gdp","cidade_polo":null,"cod_ibge":5208004,"ddd":61,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"GO","municipio_gdp":"GOIANIA","cidade":"Goiânia","origem":"gdp","cidade_polo":null,"cod_ibge":5208707,"ddd":62,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"JATAI","cidade":"Jataí","origem":"gdp","cidade_polo":null,"cod_ibge":5211909,"ddd":64,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"LUZIANIA","cidade":"Luziânia","origem":"gdp","cidade_polo":null,"cod_ibge":5212501,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"MORRINHOS","cidade":"Morrinhos","origem":"gdp","cidade_polo":null,"cod_ibge":5213806,"ddd":64,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"GO","municipio_gdp":"NOVO GAMA","cidade":"Novo Gama","origem":"gdp","cidade_polo":null,"cod_ibge":5215231,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"PLANALTINA","cidade":"Planaltina","origem":"gdp","cidade_polo":null,"cod_ibge":5217609,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"RIO VERDE","cidade":"Rio Verde","origem":"gdp","cidade_polo":null,"cod_ibge":5218805,"ddd":64,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"SANTO ANTONIO DO DESCOBERTO","cidade":"Santo Antônio do Descoberto","origem":"gdp","cidade_polo":null,"cod_ibge":5219753,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"TRINDADE","cidade":"Trindade","origem":"gdp","cidade_polo":null,"cod_ibge":5221403,"ddd":62,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"GO","municipio_gdp":"VALPARAISO DE GOIAS","cidade":"Valparaíso de Goiás","origem":"gdp","cidade_polo":null,"cod_ibge":5221858,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MA","municipio_gdp":"IMPERATRIZ","cidade":"Imperatriz","origem":"gdp","cidade_polo":null,"cod_ibge":2105302,"ddd":99,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MA","municipio_gdp":"SANTA INES","cidade":"Santa Inês","origem":"gdp","cidade_polo":null,"cod_ibge":2109908,"ddd":98,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MA","municipio_gdp":"SAO LUIS","cidade":"São Luís","origem":"gdp","cidade_polo":null,"cod_ibge":2111300,"ddd":98,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MA","municipio_gdp":"TIMON","cidade":"Timon","origem":"gdp","cidade_polo":null,"cod_ibge":2112209,"ddd":99,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"ARAGUARI","cidade":"Araguari","origem":"gdp","cidade_polo":null,"cod_ibge":3103504,"ddd":34,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"BELO HORIZONTE","cidade":"Belo Horizonte","origem":"gdp","cidade_polo":null,"cod_ibge":3106200,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"BETIM","cidade":"Betim","origem":"gdp","cidade_polo":null,"cod_ibge":3106705,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"CATAGUASES","cidade":"Cataguases","origem":"gdp","cidade_polo":null,"cod_ibge":3115300,"ddd":32,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"CAXAMBU","cidade":"Caxambu","origem":"gdp","cidade_polo":null,"cod_ibge":3115508,"ddd":35,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"CONTAGEM","cidade":"Contagem","origem":"gdp","cidade_polo":null,"cod_ibge":3118601,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"CORONEL FABRICIANO","cidade":"Coronel Fabriciano","origem":"gdp","cidade_polo":null,"cod_ibge":3119401,"ddd":31,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"DIVINOPOLIS","cidade":"Divinópolis","origem":"gdp","cidade_polo":null,"cod_ibge":3122306,"ddd":37,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"GOVERNADOR VALADARES","cidade":"Governador Valadares","origem":"gdp","cidade_polo":null,"cod_ibge":3127701,"ddd":33,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"IPATINGA","cidade":"Ipatinga","origem":"gdp","cidade_polo":null,"cod_ibge":3131307,"ddd":31,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"ITABIRA","cidade":"Itabira","origem":"gdp","cidade_polo":null,"cod_ibge":3131703,"ddd":31,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"JOAO MONLEVADE","cidade":"João Monlevade","origem":"gdp","cidade_polo":null,"cod_ibge":3136207,"ddd":31,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"JUIZ DE FORA","cidade":"Juiz de Fora","origem":"gdp","cidade_polo":null,"cod_ibge":3136702,"ddd":32,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"LAVRAS","cidade":"Lavras","origem":"gdp","cidade_polo":null,"cod_ibge":3138203,"ddd":35,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"LEOPOLDINA","cidade":"Leopoldina","origem":"gdp","cidade_polo":null,"cod_ibge":3138401,"ddd":32,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"MONTES CLAROS","cidade":"Montes Claros","origem":"gdp","cidade_polo":null,"cod_ibge":3143302,"ddd":38,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"MURIAE","cidade":"Muriaé","origem":"gdp","cidade_polo":null,"cod_ibge":3143906,"ddd":32,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"NOVA LIMA","cidade":"Nova Lima","origem":"gdp","cidade_polo":null,"cod_ibge":3144805,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"PARACATU","cidade":"Paracatu","origem":"gdp","cidade_polo":null,"cod_ibge":3147006,"ddd":38,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"PATROCINIO","cidade":"Patrocínio","origem":"gdp","cidade_polo":null,"cod_ibge":3148103,"ddd":34,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"POCOS DE CALDAS","cidade":"Poços de Caldas","origem":"gdp","cidade_polo":null,"cod_ibge":3151800,"ddd":35,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"POUSO ALEGRE","cidade":"Pouso Alegre","origem":"gdp","cidade_polo":null,"cod_ibge":3152501,"ddd":35,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"RIBEIRAO DAS NEVES","cidade":"Ribeirão das Neves","origem":"gdp","cidade_polo":null,"cod_ibge":3154606,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"SANTA LUZIA","cidade":"Santa Luzia","origem":"gdp","cidade_polo":null,"cod_ibge":3157807,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"SANTA RITA DO SAPUCAI","cidade":"Santa Rita do Sapucaí","origem":"gdp","cidade_polo":null,"cod_ibge":3159605,"ddd":35,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"SAO LOURENCO","cidade":"São Lourenço","origem":"gdp","cidade_polo":null,"cod_ibge":3163706,"ddd":35,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"SETE LAGOAS","cidade":"Sete Lagoas","origem":"gdp","cidade_polo":null,"cod_ibge":3167202,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"TIMOTEO","cidade":"Timóteo","origem":"gdp","cidade_polo":null,"cod_ibge":3168705,"ddd":31,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"UBA","cidade":"Ubá","origem":"gdp","cidade_polo":null,"cod_ibge":3169901,"ddd":32,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"VARGINHA","cidade":"Varginha","origem":"gdp","cidade_polo":null,"cod_ibge":3170701,"ddd":35,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"VESPASIANO","cidade":"Vespasiano","origem":"gdp","cidade_polo":null,"cod_ibge":3171204,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MS","municipio_gdp":"CAMPO GRANDE","cidade":"Campo Grande","origem":"gdp","cidade_polo":null,"cod_ibge":5002704,"ddd":67,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MS","municipio_gdp":"CORUMBA","cidade":"Corumbá","origem":"gdp","cidade_polo":null,"cod_ibge":5003207,"ddd":67,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MS","municipio_gdp":"DOURADOS","cidade":"Dourados","origem":"gdp","cidade_polo":null,"cod_ibge":5003702,"ddd":67,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MS","municipio_gdp":"MARACAJU","cidade":"Maracaju","origem":"gdp","cidade_polo":null,"cod_ibge":5005400,"ddd":67,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MT","municipio_gdp":"BARRA DO GARCAS","cidade":"Barra do Garças","origem":"gdp","cidade_polo":null,"cod_ibge":5101803,"ddd":66,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MT","municipio_gdp":"CACERES","cidade":"Cáceres","origem":"gdp","cidade_polo":null,"cod_ibge":5102504,"ddd":65,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MT","municipio_gdp":"CUIABA","cidade":"Cuiabá","origem":"gdp","cidade_polo":null,"cod_ibge":5103403,"ddd":65,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MT","municipio_gdp":"JUINA","cidade":"Juína","origem":"gdp","cidade_polo":null,"cod_ibge":5105150,"ddd":66,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MT","municipio_gdp":"PONTES E LACERDA","cidade":"Pontes e Lacerda","origem":"gdp","cidade_polo":null,"cod_ibge":5106752,"ddd":65,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MT","municipio_gdp":"PRIMAVERA DO LESTE","cidade":"Primavera do Leste","origem":"gdp","cidade_polo":null,"cod_ibge":5107040,"ddd":66,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MT","municipio_gdp":"RONDONOPOLIS","cidade":"Rondonópolis","origem":"gdp","cidade_polo":null,"cod_ibge":5107602,"ddd":66,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MT","municipio_gdp":"SINOP","cidade":"Sinop","origem":"gdp","cidade_polo":null,"cod_ibge":5107909,"ddd":66,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MT","municipio_gdp":"TANGARA DA SERRA","cidade":"Tangará da Serra","origem":"gdp","cidade_polo":null,"cod_ibge":5107958,"ddd":65,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MT","municipio_gdp":"VARZEA GRANDE","cidade":"Várzea Grande","origem":"gdp","cidade_polo":null,"cod_ibge":5108402,"ddd":65,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PA","municipio_gdp":"ANANINDEUA","cidade":"Ananindeua","origem":"gdp","cidade_polo":null,"cod_ibge":1500800,"ddd":91,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PA","municipio_gdp":"BELEM","cidade":"Belém","origem":"gdp","cidade_polo":null,"cod_ibge":1501402,"ddd":91,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PA","municipio_gdp":"CASTANHAL","cidade":"Castanhal","origem":"gdp","cidade_polo":null,"cod_ibge":1502400,"ddd":91,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PA","municipio_gdp":"MARABA","cidade":"Marabá","origem":"gdp","cidade_polo":null,"cod_ibge":1504208,"ddd":94,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PB","municipio_gdp":"CAMPINA GRANDE","cidade":"Campina Grande","origem":"gdp","cidade_polo":null,"cod_ibge":2504009,"ddd":83,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PB","municipio_gdp":"JOAO PESSOA","cidade":"João Pessoa","origem":"gdp","cidade_polo":null,"cod_ibge":2507507,"ddd":83,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PB","municipio_gdp":"SANTA LUZIA","cidade":"Santa Luzia","origem":"gdp","cidade_polo":null,"cod_ibge":2513406,"ddd":83,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PE","municipio_gdp":"CABO DE SANTO AGOSTINHO","cidade":"Cabo de Santo Agostinho","origem":"gdp","cidade_polo":null,"cod_ibge":2602902,"ddd":81,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PE","municipio_gdp":"CARUARU","cidade":"Caruaru","origem":"gdp","cidade_polo":null,"cod_ibge":2604106,"ddd":81,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PE","municipio_gdp":"GOIANA","cidade":"Goiana","origem":"gdp","cidade_polo":null,"cod_ibge":2606200,"ddd":81,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PE","municipio_gdp":"OLINDA","cidade":"Olinda","origem":"gdp","cidade_polo":null,"cod_ibge":2609600,"ddd":81,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PE","municipio_gdp":"PETROLINA","cidade":"Petrolina","origem":"gdp","cidade_polo":null,"cod_ibge":2611101,"ddd":87,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PE","municipio_gdp":"RECIFE","cidade":"Recife","origem":"gdp","cidade_polo":null,"cod_ibge":2611606,"ddd":81,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PI","municipio_gdp":"FLORIANO","cidade":"Floriano","origem":"gdp","cidade_polo":null,"cod_ibge":2203909,"ddd":89,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PI","municipio_gdp":"PARNAIBA","cidade":"Parnaíba","origem":"gdp","cidade_polo":null,"cod_ibge":2207702,"ddd":86,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PI","municipio_gdp":"PIRIPIRI","cidade":"Piripiri","origem":"gdp","cidade_polo":null,"cod_ibge":2208403,"ddd":86,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PI","municipio_gdp":"TERESINA","cidade":"Teresina","origem":"gdp","cidade_polo":null,"cod_ibge":2211001,"ddd":86,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"ALMIRANTE TAMANDARE","cidade":"Almirante Tamandaré","origem":"gdp","cidade_polo":null,"cod_ibge":4100400,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"ANDIRA","cidade":"Andirá","origem":"gdp","cidade_polo":null,"cod_ibge":4101101,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"APUCARANA","cidade":"Apucarana","origem":"gdp","cidade_polo":null,"cod_ibge":4101408,"ddd":43,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"ARAPONGAS","cidade":"Arapongas","origem":"gdp","cidade_polo":null,"cod_ibge":4101507,"ddd":43,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"ARAUCARIA","cidade":"Araucária","origem":"gdp","cidade_polo":null,"cod_ibge":4101804,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"ASTORGA","cidade":"Astorga","origem":"gdp","cidade_polo":null,"cod_ibge":4102109,"ddd":44,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"CAMBE","cidade":"Cambé","origem":"gdp","cidade_polo":null,"cod_ibge":4103701,"ddd":43,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"CAMPINA GRANDE DO SUL","cidade":"Campina Grande do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4104006,"ddd":41,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"CAMPO LARGO","cidade":"Campo Largo","origem":"gdp","cidade_polo":null,"cod_ibge":4104204,"ddd":41,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"CAMPO MOURAO","cidade":"Campo Mourão","origem":"gdp","cidade_polo":null,"cod_ibge":4104303,"ddd":44,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"CASCAVEL","cidade":"Cascavel","origem":"gdp","cidade_polo":null,"cod_ibge":4104808,"ddd":45,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"CASTRO","cidade":"Castro","origem":"gdp","cidade_polo":null,"cod_ibge":4104907,"ddd":42,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"CIANORTE","cidade":"Cianorte","origem":"gdp","cidade_polo":null,"cod_ibge":4105508,"ddd":44,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"COLOMBO","cidade":"Colombo","origem":"gdp","cidade_polo":null,"cod_ibge":4105805,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"COLORADO","cidade":"Colorado","origem":"gdp","cidade_polo":null,"cod_ibge":4105904,"ddd":44,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"CORNELIO PROCOPIO","cidade":"Cornélio Procópio","origem":"gdp","cidade_polo":null,"cod_ibge":4106407,"ddd":43,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"CURITIBA","cidade":"Curitiba","origem":"gdp","cidade_polo":null,"cod_ibge":4106902,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"FAZENDA RIO GRANDE","cidade":"Fazenda Rio Grande","origem":"gdp","cidade_polo":null,"cod_ibge":4107652,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"FLORESTA","cidade":"Floresta","origem":"gdp","cidade_polo":null,"cod_ibge":4107900,"ddd":44,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"FOZ DO IGUACU","cidade":"Foz do Iguaçu","origem":"gdp","cidade_polo":null,"cod_ibge":4108304,"ddd":45,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"FRANCISCO BELTRAO","cidade":"Francisco Beltrão","origem":"gdp","cidade_polo":null,"cod_ibge":4108403,"ddd":46,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"GUARAPUAVA","cidade":"Guarapuava","origem":"gdp","cidade_polo":null,"cod_ibge":4109401,"ddd":42,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"GUARATUBA","cidade":"Guaratuba","origem":"gdp","cidade_polo":null,"cod_ibge":4109609,"ddd":41,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"IBIPORA","cidade":"Ibiporã","origem":"gdp","cidade_polo":null,"cod_ibge":4109807,"ddd":43,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"IRATI","cidade":"Irati","origem":"gdp","cidade_polo":null,"cod_ibge":4110706,"ddd":42,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"JANDAIA DO SUL","cidade":"Jandaia do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4112108,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"LONDRINA","cidade":"Londrina","origem":"gdp","cidade_polo":null,"cod_ibge":4113700,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"MARECHAL CANDIDO RONDON","cidade":"Marechal Cândido Rondon","origem":"gdp","cidade_polo":null,"cod_ibge":4114609,"ddd":45,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"MARINGA","cidade":"Maringá","origem":"gdp","cidade_polo":null,"cod_ibge":4115200,"ddd":44,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"MATINHOS","cidade":"Matinhos","origem":"gdp","cidade_polo":null,"cod_ibge":4115705,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"MEDIANEIRA","cidade":"Medianeira","origem":"gdp","cidade_polo":null,"cod_ibge":4115804,"ddd":45,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"PAICANDU","cidade":"Paiçandu","origem":"gdp","cidade_polo":null,"cod_ibge":4117503,"ddd":44,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"PALMAS","cidade":"Palmas","origem":"gdp","cidade_polo":null,"cod_ibge":4117602,"ddd":46,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"PARANAGUA","cidade":"Paranaguá","origem":"gdp","cidade_polo":null,"cod_ibge":4118204,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"PATO BRANCO","cidade":"Pato Branco","origem":"gdp","cidade_polo":null,"cod_ibge":4118501,"ddd":46,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"PINHAIS","cidade":"Pinhais","origem":"gdp","cidade_polo":null,"cod_ibge":4119152,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"PIRAQUARA","cidade":"Piraquara","origem":"gdp","cidade_polo":null,"cod_ibge":4119509,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"PONTA GROSSA","cidade":"Ponta Grossa","origem":"gdp","cidade_polo":null,"cod_ibge":4119905,"ddd":42,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"QUATRO BARRAS","cidade":"Quatro Barras","origem":"gdp","cidade_polo":null,"cod_ibge":4120804,"ddd":41,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"RIBEIRAO DO PINHAL","cidade":"Ribeirão do Pinhal","origem":"gdp","cidade_polo":null,"cod_ibge":4121901,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"SANTO ANTONIO DA PLATINA","cidade":"Santo Antônio da Platina","origem":"gdp","cidade_polo":null,"cod_ibge":4124103,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"SAO JOSE DOS PINHAIS","cidade":"São José dos Pinhais","origem":"gdp","cidade_polo":null,"cod_ibge":4125506,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"SAO PEDRO DO IVAI","cidade":"São Pedro do Ivaí","origem":"gdp","cidade_polo":null,"cod_ibge":4125803,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"SAO SEBASTIAO DA AMOREIRA","cidade":"São Sebastião da Amoreira","origem":"gdp","cidade_polo":null,"cod_ibge":4126009,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"SARANDI","cidade":"Sarandi","origem":"conurbada","cidade_polo":null,"cod_ibge":4126256,"ddd":44,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"TELEMACO BORBA","cidade":"Telêmaco Borba","origem":"gdp","cidade_polo":null,"cod_ibge":4127106,"ddd":42,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"TOLEDO","cidade":"Toledo","origem":"gdp","cidade_polo":null,"cod_ibge":4127700,"ddd":45,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"UMUARAMA","cidade":"Umuarama","origem":"gdp","cidade_polo":null,"cod_ibge":4128104,"ddd":44,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"UNIAO DA VITORIA","cidade":"União da Vitória","origem":"gdp","cidade_polo":null,"cod_ibge":4128203,"ddd":42,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"PR","municipio_gdp":"WENCESLAU BRAZ","cidade":"Wenceslau Braz","origem":"gdp","cidade_polo":null,"cod_ibge":4128500,"ddd":43,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"ANGRA DOS REIS","cidade":"Angra dos Reis","origem":"gdp","cidade_polo":null,"cod_ibge":3300100,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"ARARUAMA","cidade":"Araruama","origem":"gdp","cidade_polo":null,"cod_ibge":3300209,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"ARMACAO DOS BUZIOS","cidade":"Armação dos Búzios","origem":"gdp","cidade_polo":null,"cod_ibge":3300233,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"BARRA DO PIRAI","cidade":"Barra do Piraí","origem":"gdp","cidade_polo":null,"cod_ibge":3300308,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"BARRA MANSA","cidade":"Barra Mansa","origem":"gdp","cidade_polo":null,"cod_ibge":3300407,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"BELFORD ROXO","cidade":"Belford Roxo","origem":"gdp","cidade_polo":null,"cod_ibge":3300456,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"CABO FRIO","cidade":"Cabo Frio","origem":"gdp","cidade_polo":null,"cod_ibge":3300704,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"CAMPOS DOS GOYTACAZES","cidade":"Campos dos Goytacazes","origem":"gdp","cidade_polo":null,"cod_ibge":3301009,"ddd":22,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RJ","municipio_gdp":"CASIMIRO DE ABREU","cidade":"Casimiro de Abreu","origem":"gdp","cidade_polo":null,"cod_ibge":3301306,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"DUQUE DE CAXIAS","cidade":"Duque de Caxias","origem":"gdp","cidade_polo":null,"cod_ibge":3301702,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"ITAGUAI","cidade":"Itaguaí","origem":"gdp","cidade_polo":null,"cod_ibge":3302007,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"MANGARATIBA","cidade":"Mangaratiba","origem":"gdp","cidade_polo":null,"cod_ibge":3302601,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"MARICA","cidade":"Maricá","origem":"gdp","cidade_polo":null,"cod_ibge":3302700,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"NILOPOLIS","cidade":"Nilópolis","origem":"gdp","cidade_polo":null,"cod_ibge":3303203,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"NITEROI","cidade":"Niterói","origem":"gdp","cidade_polo":null,"cod_ibge":3303302,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"NOVA FRIBURGO","cidade":"Nova Friburgo","origem":"gdp","cidade_polo":null,"cod_ibge":3303401,"ddd":22,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RJ","municipio_gdp":"NOVA IGUACU","cidade":"Nova Iguaçu","origem":"gdp","cidade_polo":null,"cod_ibge":3303500,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"PARACAMBI","cidade":"Paracambi","origem":"gdp","cidade_polo":null,"cod_ibge":3303609,"ddd":21,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RJ","municipio_gdp":"PETROPOLIS","cidade":"Petrópolis","origem":"gdp","cidade_polo":null,"cod_ibge":3303906,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"PINHEIRAL","cidade":"Pinheiral","origem":"gdp","cidade_polo":null,"cod_ibge":3303955,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"QUEIMADOS","cidade":"Queimados","origem":"gdp","cidade_polo":null,"cod_ibge":3304144,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"RESENDE","cidade":"Resende","origem":"gdp","cidade_polo":null,"cod_ibge":3304201,"ddd":24,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RJ","municipio_gdp":"RIO DE JANEIRO","cidade":"Rio de Janeiro","origem":"gdp","cidade_polo":null,"cod_ibge":3304557,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"SAO GONCALO","cidade":"São Gonçalo","origem":"gdp","cidade_polo":null,"cod_ibge":3304904,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"SAO JOAO DE MERITI","cidade":"São João de Meriti","origem":"gdp","cidade_polo":null,"cod_ibge":3305109,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"SAO PEDRO DA ALDEIA","cidade":"São Pedro da Aldeia","origem":"gdp","cidade_polo":null,"cod_ibge":3305208,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"SAQUAREMA","cidade":"Saquarema","origem":"gdp","cidade_polo":null,"cod_ibge":3305505,"ddd":22,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RJ","municipio_gdp":"TERESOPOLIS","cidade":"Teresópolis","origem":"gdp","cidade_polo":null,"cod_ibge":3305802,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"VALENCA","cidade":"Valença","origem":"gdp","cidade_polo":null,"cod_ibge":3306107,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"VOLTA REDONDA","cidade":"Volta Redonda","origem":"gdp","cidade_polo":null,"cod_ibge":3306305,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RN","municipio_gdp":"MOSSORO","cidade":"Mossoró","origem":"gdp","cidade_polo":null,"cod_ibge":2408003,"ddd":84,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RN","municipio_gdp":"NATAL","cidade":"Natal","origem":"gdp","cidade_polo":null,"cod_ibge":2408102,"ddd":84,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RN","municipio_gdp":"SAO GONCALO DO AMARANTE","cidade":"São Gonçalo do Amarante","origem":"conurbada","cidade_polo":null,"cod_ibge":2412005,"ddd":81,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RO","municipio_gdp":"CACOAL","cidade":"Cacoal","origem":"gdp","cidade_polo":null,"cod_ibge":1100049,"ddd":69,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RO","municipio_gdp":"JARU","cidade":"Jaru","origem":"gdp","cidade_polo":null,"cod_ibge":1100114,"ddd":69,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RO","municipio_gdp":"JI PARANA","cidade":"Ji-Paraná","origem":"gdp","cidade_polo":null,"cod_ibge":1100122,"ddd":69,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RO","municipio_gdp":"OURO PRETO DO OESTE","cidade":"Ouro Preto do Oeste","origem":"gdp","cidade_polo":null,"cod_ibge":1100155,"ddd":69,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RO","municipio_gdp":"PIMENTA BUENO","cidade":"Pimenta Bueno","origem":"gdp","cidade_polo":null,"cod_ibge":1100189,"ddd":69,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RO","municipio_gdp":"PORTO VELHO","cidade":"Porto Velho","origem":"gdp","cidade_polo":null,"cod_ibge":1100205,"ddd":69,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RO","municipio_gdp":"ROLIM DE MOURA","cidade":"Rolim de Moura","origem":"gdp","cidade_polo":null,"cod_ibge":1100288,"ddd":69,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RO","municipio_gdp":"VILHENA","cidade":"Vilhena","origem":"gdp","cidade_polo":null,"cod_ibge":1100304,"ddd":69,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RR","municipio_gdp":"BOA VISTA","cidade":"Boa Vista","origem":"gdp","cidade_polo":null,"cod_ibge":1400100,"ddd":95,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"ALEGRETE","cidade":"Alegrete","origem":"gdp","cidade_polo":null,"cod_ibge":4300406,"ddd":55,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"ALVORADA","cidade":"Alvorada","origem":"gdp","cidade_polo":null,"cod_ibge":4300604,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"BAGE","cidade":"Bagé","origem":"gdp","cidade_polo":null,"cod_ibge":4301602,"ddd":53,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"BENTO GONCALVES","cidade":"Bento Gonçalves","origem":"gdp","cidade_polo":null,"cod_ibge":4302105,"ddd":54,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"CACHOEIRINHA","cidade":"Cachoeirinha","origem":"gdp","cidade_polo":null,"cod_ibge":4303103,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"CAMAQUA","cidade":"Camaquã","origem":"gdp","cidade_polo":null,"cod_ibge":4303509,"ddd":51,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"CAMPO BOM","cidade":"Campo Bom","origem":"gdp","cidade_polo":null,"cod_ibge":4303905,"ddd":51,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"CANOAS","cidade":"Canoas","origem":"gdp","cidade_polo":null,"cod_ibge":4304606,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"CARAZINHO","cidade":"Carazinho","origem":"gdp","cidade_polo":null,"cod_ibge":4304705,"ddd":54,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"CAXIAS DO SUL","cidade":"Caxias do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4305108,"ddd":54,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"ELDORADO DO SUL","cidade":"Eldorado do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4306767,"ddd":51,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"ERECHIM","cidade":"Erechim","origem":"gdp","cidade_polo":null,"cod_ibge":4307005,"ddd":54,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"ESTEIO","cidade":"Esteio","origem":"gdp","cidade_polo":null,"cod_ibge":4307708,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"FARROUPILHA","cidade":"Farroupilha","origem":"gdp","cidade_polo":null,"cod_ibge":4307906,"ddd":54,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"FLORES DA CUNHA","cidade":"Flores da Cunha","origem":"gdp","cidade_polo":null,"cod_ibge":4308201,"ddd":54,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"GARIBALDI","cidade":"Garibaldi","origem":"gdp","cidade_polo":null,"cod_ibge":4308607,"ddd":54,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"GRAVATAI","cidade":"Gravataí","origem":"gdp","cidade_polo":null,"cod_ibge":4309209,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"GUAIBA","cidade":"Guaíba","origem":"gdp","cidade_polo":null,"cod_ibge":4309308,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"IJUI","cidade":"Ijuí","origem":"gdp","cidade_polo":null,"cod_ibge":4310207,"ddd":55,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"LAJEADO","cidade":"Lajeado","origem":"gdp","cidade_polo":null,"cod_ibge":4311403,"ddd":51,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"MARAU","cidade":"Marau","origem":"gdp","cidade_polo":null,"cod_ibge":4311809,"ddd":54,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"MONTENEGRO","cidade":"Montenegro","origem":"gdp","cidade_polo":null,"cod_ibge":4312401,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"NOVO HAMBURGO","cidade":"Novo Hamburgo","origem":"gdp","cidade_polo":null,"cod_ibge":4313409,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"PASSO FUNDO","cidade":"Passo Fundo","origem":"gdp","cidade_polo":null,"cod_ibge":4314100,"ddd":54,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"PELOTAS","cidade":"Pelotas","origem":"gdp","cidade_polo":null,"cod_ibge":4314407,"ddd":53,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"PORTO ALEGRE","cidade":"Porto Alegre","origem":"gdp","cidade_polo":null,"cod_ibge":4314902,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"RIO GRANDE","cidade":"Rio Grande","origem":"gdp","cidade_polo":null,"cod_ibge":4315602,"ddd":53,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"ROSARIO DO SUL","cidade":"Rosário do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4316402,"ddd":55,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"SANTA CRUZ DO SUL","cidade":"Santa Cruz do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4316808,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"SANTA MARIA","cidade":"Santa Maria","origem":"gdp","cidade_polo":null,"cod_ibge":4316907,"ddd":55,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"SANTIAGO","cidade":"Santiago","origem":"gdp","cidade_polo":null,"cod_ibge":4317400,"ddd":55,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"SANTO ANGELO","cidade":"Santo Ângelo","origem":"gdp","cidade_polo":null,"cod_ibge":4317509,"ddd":55,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"SAO LEOPOLDO","cidade":"São Leopoldo","origem":"gdp","cidade_polo":null,"cod_ibge":4318705,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"SAO LOURENCO DO SUL","cidade":"São Lourenço do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4318804,"ddd":53,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"SAPUCAIA DO SUL","cidade":"Sapucaia do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4320008,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"TAQUARA","cidade":"Taquara","origem":"gdp","cidade_polo":null,"cod_ibge":4321204,"ddd":51,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"URUGUAIANA","cidade":"Uruguaiana","origem":"gdp","cidade_polo":null,"cod_ibge":4322400,"ddd":55,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"VENANCIO AIRES","cidade":"Venâncio Aires","origem":"gdp","cidade_polo":null,"cod_ibge":4322608,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"VIAMAO","cidade":"Viamão","origem":"gdp","cidade_polo":null,"cod_ibge":4323002,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"BALNEARIO CAMBORIU","cidade":"Balneário Camboriú","origem":"gdp","cidade_polo":null,"cod_ibge":4202008,"ddd":47,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"BLUMENAU","cidade":"Blumenau","origem":"gdp","cidade_polo":null,"cod_ibge":4202404,"ddd":47,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"BRUSQUE","cidade":"Brusque","origem":"gdp","cidade_polo":null,"cod_ibge":4202909,"ddd":47,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"CHAPECO","cidade":"Chapecó","origem":"gdp","cidade_polo":null,"cod_ibge":4204202,"ddd":49,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"CRICIUMA","cidade":"Criciúma","origem":"gdp","cidade_polo":null,"cod_ibge":4204608,"ddd":48,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"FLORIANOPOLIS","cidade":"Florianópolis","origem":"gdp","cidade_polo":null,"cod_ibge":4205407,"ddd":48,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"GAROPABA","cidade":"Garopaba","origem":"gdp","cidade_polo":null,"cod_ibge":4205704,"ddd":48,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"GUABIRUBA","cidade":"Guabiruba","origem":"gdp","cidade_polo":null,"cod_ibge":4206306,"ddd":47,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"ICARA","cidade":"Içara","origem":"gdp","cidade_polo":null,"cod_ibge":4207007,"ddd":48,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"INDAIAL","cidade":"Indaial","origem":"gdp","cidade_polo":null,"cod_ibge":4207502,"ddd":47,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"ITAJAI","cidade":"Itajaí","origem":"gdp","cidade_polo":null,"cod_ibge":4208203,"ddd":47,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"ITUPORANGA","cidade":"Ituporanga","origem":"gdp","cidade_polo":null,"cod_ibge":4208500,"ddd":47,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"JOINVILLE","cidade":"Joinville","origem":"gdp","cidade_polo":null,"cod_ibge":4209102,"ddd":47,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"LAGES","cidade":"Lages","origem":"gdp","cidade_polo":null,"cod_ibge":4209300,"ddd":49,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"NAVEGANTES","cidade":"Navegantes","origem":"gdp","cidade_polo":null,"cod_ibge":4211306,"ddd":47,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"PALHOCA","cidade":"Palhoça","origem":"gdp","cidade_polo":null,"cod_ibge":4211900,"ddd":48,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"RIO DO SUL","cidade":"Rio do Sul","origem":"gdp","cidade_polo":null,"cod_ibge":4214805,"ddd":47,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SC","municipio_gdp":"TUBARAO","cidade":"Tubarão","origem":"gdp","cidade_polo":null,"cod_ibge":4218707,"ddd":48,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SE","municipio_gdp":"ARACAJU","cidade":"Aracaju","origem":"gdp","cidade_polo":null,"cod_ibge":2800308,"ddd":79,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SE","municipio_gdp":"ITABAIANA","cidade":"Itabaiana","origem":"gdp","cidade_polo":null,"cod_ibge":2802908,"ddd":79,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"CAMPINAS","cidade":"Campinas","origem":"gdp","cidade_polo":null,"cod_ibge":3509502,"ddd":19,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"GUARULHOS","cidade":"Guarulhos","origem":"gdp","cidade_polo":null,"cod_ibge":3518800,"ddd":11,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"JUNDIAI","cidade":"Jundiaí","origem":"gdp","cidade_polo":null,"cod_ibge":3525904,"ddd":11,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"MOGI DAS CRUZES","cidade":"Mogi das Cruzes","origem":"gdp","cidade_polo":null,"cod_ibge":3530607,"ddd":11,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"SAO JOSE DOS CAMPOS","cidade":"São José dos Campos","origem":"gdp","cidade_polo":null,"cod_ibge":3549904,"ddd":12,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"SAO PAULO","cidade":"São Paulo","origem":"gdp","cidade_polo":null,"cod_ibge":3550308,"ddd":11,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SP","municipio_gdp":"SOROCABA","cidade":"Sorocaba","origem":"gdp","cidade_polo":null,"cod_ibge":3552205,"ddd":15,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"VOTORANTIM","cidade":"Votorantim","origem":"conurbada","cidade_polo":null,"cod_ibge":3557006,"ddd":15,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"TO","municipio_gdp":"GURUPI","cidade":"Gurupi","origem":"gdp","cidade_polo":null,"cod_ibge":1709500,"ddd":63,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"TO","municipio_gdp":"PALMAS","cidade":"Palmas","origem":"gdp","cidade_polo":null,"cod_ibge":1721000,"ddd":63,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"TO","municipio_gdp":"PARAISO DO TOCANTINS","cidade":"Paraíso do Tocantins","origem":"gdp","cidade_polo":null,"cod_ibge":1716109,"ddd":63,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"TO","municipio_gdp":"PORTO NACIONAL","cidade":"Porto Nacional","origem":"gdp","cidade_polo":null,"cod_ibge":1718204,"ddd":63,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"CE","municipio_gdp":"MARACANAU","cidade":"Maracanaú","origem":"conurbada","cidade_polo":null,"cod_ibge":2307650,"ddd":85,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"AGUAS LINDAS DE GOIAS","cidade":"Águas Lindas de Goiás","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5200258,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"CEILANDIA","cidade":"Ceilândia","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"CIDADE OCIDENTAL","cidade":"Cidade Ocidental","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5205497,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"CRUZEIRO","cidade":"Cruzeiro","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"GAMA","cidade":"Gama","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"GUARA","cidade":"Guará","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"NOVO GAMA","cidade":"Novo Gama","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5215231,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"NUCLEO BANDEIRANTE","cidade":"Núcleo Bandeirante","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"PARANOA","cidade":"Paranoá","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"PLANALTINA","cidade":"Planaltina","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5217609,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"RECANTO DAS EMAS","cidade":"Recanto das Emas","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"RIACHO FUNDO","cidade":"Riacho Fundo","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"SAMAMBAIA","cidade":"Samambaia","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"SANTA MARIA","cidade":"Santa Maria","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"SANTO ANTONIO DO DESCOBERTO","cidade":"Santo Antônio do Descoberto","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5219753,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"SOBRADINHO","cidade":"Sobradinho","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"TAGUATINGA","cidade":"Taguatinga","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":1720903,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"CARAPINA","cidade":"Carapina","origem":"conurbada","cidade_polo":"Serra","cod_ibge":3205002,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"ES","municipio_gdp":"ITAQUARI","cidade":"Itaquari","origem":"conurbada","cidade_polo":"Cariacica","cod_ibge":3201308,"ddd":27,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"GO","municipio_gdp":"SENADOR CANEDO","cidade":"Senador Canedo","origem":"conurbada","cidade_polo":null,"cod_ibge":5220454,"ddd":62,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MA","municipio_gdp":"PACO DO LUMIAR","cidade":"Paço do Lumiar","origem":"conurbada","cidade_polo":null,"cod_ibge":2107506,"ddd":98,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MA","municipio_gdp":"SAO JOSE DE RIBAMAR","cidade":"São José de Ribamar","origem":"conurbada","cidade_polo":null,"cod_ibge":2111201,"ddd":98,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"CONSELHEIRO LAFAIETE","cidade":"Conselheiro Lafaiete","origem":"conurbada","cidade_polo":null,"cod_ibge":3118304,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"ESMERALDAS","cidade":"Esmeraldas","origem":"conurbada","cidade_polo":null,"cod_ibge":3124104,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"IBIRITE","cidade":"Ibirité","origem":"conurbada","cidade_polo":null,"cod_ibge":3129806,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"JUSTINOPOLIS","cidade":"Justinópolis","origem":"conurbada","cidade_polo":"Ribeirão das Neves","cod_ibge":3154606,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"SABARA","cidade":"Sabará","origem":"conurbada","cidade_polo":null,"cod_ibge":3156700,"ddd":31,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"MG","municipio_gdp":"SERRA DEL REI","cidade":"Serra del Rei","origem":"conurbada","cidade_polo":"Nova Lima","cod_ibge":3162500,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"MG","municipio_gdp":"VENDA NOVA","cidade":"Venda Nova","origem":"conurbada","cidade_polo":"Belo Horizonte","cod_ibge":3106200,"ddd":31,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PB","municipio_gdp":"CABEDELO","cidade":"Cabedelo","origem":"conurbada","cidade_polo":null,"cod_ibge":2503209,"ddd":83,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PE","municipio_gdp":"ARCOVERDE","cidade":"Arcoverde","origem":"conurbada","cidade_polo":null,"cod_ibge":2601201,"ddd":87,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PE","municipio_gdp":"JABOATAO DOS GUARARAPES","cidade":"Jaboatão dos Guararapes","origem":"conurbada","cidade_polo":null,"cod_ibge":2607901,"ddd":81,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PE","municipio_gdp":"PAULISTA","cidade":"Paulista","origem":"conurbada","cidade_polo":null,"cod_ibge":2610707,"ddd":81,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"CAMPO MAGRO","cidade":"Campo Magro","origem":"conurbada","cidade_polo":null,"cod_ibge":4104253,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"COLONIA FARIA","cidade":"Colônia Faria","origem":"conurbada","cidade_polo":"Colombo","cod_ibge":4105805,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"MARACANA","cidade":"Maracanã","origem":"conurbada","cidade_polo":"Colombo","cod_ibge":1504307,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"ROCA GRANDE","cidade":"Roça Grande","origem":"conurbada","cidade_polo":"Colombo","cod_ibge":4105805,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"PR","municipio_gdp":"SANTA RITA","cidade":"Santa Rita","origem":"conurbada","cidade_polo":"Colombo","cod_ibge":2513703,"ddd":41,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"CAMINHO DE BUZIOS","cidade":"Caminho de Búzios","origem":"conurbada","cidade_polo":"Cabo Frio","cod_ibge":3300233,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"CORREIAS","cidade":"Correias","origem":"conurbada","cidade_polo":"Petrópolis","cod_ibge":3303906,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"ITABORAI","cidade":"Itaboraí","origem":"conurbada","cidade_polo":null,"cod_ibge":3301900,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"ITAIPAVA","cidade":"Itaipava","origem":"conurbada","cidade_polo":"Petrópolis","cod_ibge":3303906,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"ITAIPUACU","cidade":"Itaipuaçu","origem":"conurbada","cidade_polo":"Maricá","cod_ibge":3302700,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"JACUECANGA","cidade":"Jacuecanga","origem":"conurbada","cidade_polo":"Angra dos Reis","cod_ibge":3300100,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"JARDIM ARARAS","cidade":"Jardim Araras","origem":"conurbada","cidade_polo":"Petrópolis","cod_ibge":3303906,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"MAMBUCABA","cidade":"Mambucaba","origem":"conurbada","cidade_polo":"Angra dos Reis","cod_ibge":3300100,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"MARAMBAIA","cidade":"Marambaia","origem":"conurbada","cidade_polo":"Itaboraí","cod_ibge":3304557,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"MARINA PORTO BUZIOS","cidade":"Marina Porto Búzios","origem":"conurbada","cidade_polo":"Armação dos Búzios","cod_ibge":3300233,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"MESQUITA","cidade":"Mesquita","origem":"conurbada","cidade_polo":null,"cod_ibge":3302858,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"PEDRO DO RIO","cidade":"Pedro do Rio","origem":"conurbada","cidade_polo":"Petrópolis","cod_ibge":3303906,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"PIRAI","cidade":"Piraí","origem":"conurbada","cidade_polo":null,"cod_ibge":3304003,"ddd":24,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"PORTO BELO","cidade":"Porto Belo","origem":"conurbada","cidade_polo":"Mangaratiba","cod_ibge":3300233,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"UNAMAR","cidade":"Unamar","origem":"conurbada","cidade_polo":"Cabo Frio","cod_ibge":3300704,"ddd":22,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"VILAR DOS TELES","cidade":"Vilar dos Teles","origem":"conurbada","cidade_polo":"São João de Meriti","cod_ibge":3305109,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"VILA ELZA","cidade":"Vila Elza","origem":"conurbada","cidade_polo":"Viamão","cod_ibge":4323002,"ddd":51,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SC","municipio_gdp":"SAO JOSE","cidade":"São José","origem":"gdp","cidade_polo":null,"cod_ibge":4216602,"ddd":48,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"SP","municipio_gdp":"CAJAMAR","cidade":"Cajamar","origem":"conurbada","cidade_polo":null,"cod_ibge":3509205,"ddd":11,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"SP","municipio_gdp":"HORTOLANDIA","cidade":"Hortolândia","origem":"conurbada","cidade_polo":null,"cod_ibge":3519071,"ddd":19,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"BRAZILANDIA","cidade":"Brazlândia","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":5300108,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"DF","municipio_gdp":"SAO SEBASTIAO","cidade":"São Sebastião","origem":"conurbada","cidade_polo":"Brasília","cod_ibge":3550704,"ddd":61,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RJ","municipio_gdp":"PEDRO DE ALCANTARA","cidade":"Pedro de Alcântara","origem":"conurbada","cidade_polo":"São Gonçalo","cod_ibge":4217253,"ddd":21,"portfolio":"REGULAR MÓVEL","cluster":"regular"},
{"uf":"RS","municipio_gdp":"ESTANCIA VELHA","cidade":"Estância Velha","origem":"gdp","cidade_polo":null,"cod_ibge":4307609,"ddd":51,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"GO","municipio_gdp":"INHUMAS","cidade":"Inhumas","origem":"gdp","cidade_polo":null,"cod_ibge":5210000,"ddd":62,"portfolio":"BTU MÓVEL","cluster":"btu"},
{"uf":"RS","municipio_gdp":"RIO PARDO","cidade":"Rio Pardo","origem":"gdp","cidade_polo":null,"cod_ibge":4315701,"ddd":51,"portfolio":"BTU MÓVEL","cluster":"btu"}
]$gdp$::jsonb, date '2026-10-28');

select public._area_ativar(u, null, true,
         'Área nacional: a Dharma está autorizada a vender em todos os estados (Ricardo, 26/11/2026 12h20) — UF de fuso −3', 'migration:0417')
  from unnest(array['AL', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'PA', 'PB', 'PE', 'PI', 'PR', 'RJ', 'RN', 'RS', 'SC', 'SE', 'SP', 'TO']) u;

-- as 25 de fuso diferente ficam desligadas: o motivo fica no histórico (não é "fora da área")
insert into public.area_ativa_hist (area_id, uf, cidade, de, para, motivo, autor)
select a.id, a.uf, a.cidade, null, false,
       'fuso_pendente: toques 9h–21h são de contrato e hoje são calculados em America/Sao_Paulo — liga com area_ativar_uf depois de resolver o fuso',
       'migration:0417'
  from public.config_area a where a.uf in ('AC', 'AM', 'RR', 'RO', 'MT', 'MS') and not a.ativo;

-- 6. Conferência: item 41 ------------------------------------------------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('''area_cluster_gdp''' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0417: conferencia_itens mudou — refazer o item da área a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 41. 0417 — Área: cidade ativa com cluster diferente do portfólio da GDP vigente (venderia o preço da tabela errada)
  select count(*)::int, string_agg(a.uf || '' '' || a.cidade || '' ('' || a.cluster || '' × '' || coalesce(a.portfolio_gdp, ''sem GDP'') || '')'', '', '' order by a.uf, a.cidade)
    into n, ex
    from public.config_area a
   where a.ativo
     and (a.portfolio_gdp is null
          or a.cluster is distinct from case a.portfolio_gdp when ''REGULAR MÓVEL'' then ''regular'' when ''BTU MÓVEL'' then ''btu'' end);
  it := it || jsonb_build_object(''codigo'', ''area_cluster_gdp'', ''nome'', ''Área: cluster de cada cidade ativa = portfólio da GDP'',
    ''nivel'', case when n = 0 then ''ok'' else ''falha'' end, ''n'', n,
    ''texto'', case when n = 0 then format(''%s cidades ativas, todas com o cluster da GDP de %s'',
                                          (select count(*) from public.config_area where ativo),
                                          coalesce((select to_char(max(gdp_versao), ''DD/MM/YYYY'') from public.config_area), ''?''))
                    else format(''%s cidade(s) ativa(s) fora da GDP: %s'', n, left(ex, 300)) end,
    ''fazer'', case when n = 0 then null
                    else ''Avisar o Claude Code: corrigir o cluster da cidade (ou desligá-la com area_ativar_cidade) — plano do cluster errado é recusado e vira pedido errado no portal.'' end);

  return it;
end');
  execute d;
end $$;

-- 6b. Texto da Saída "Cidade não atendida" (vai ao cliente; não passa pelo portão da Mari) -----------------------------------
-- Dizia "a Nio atende só algumas cidades de Minas" — com a área nacional, isso é falso e afasta quem está noutro estado.
-- O novo não amarra estado e vale também para as cidades desligadas pelo fuso (a Nio chega lá, a gente ainda não vende).
update public.config_mari_textos set texto =
  'Oi, {nome}! Por enquanto a gente atende só algumas das cidades onde a Nio tem fibra, e {cidade} ainda não está entre elas 😕 Por isso não conseguimos abrir o pedido. Se você tiver um endereço em outra cidade, me manda o CEP e o número que a gente confere.'
 where chave = 'saida_cidade_nao_atendida';
update public.config_mari_textos set texto =
  'Oi, {nome}! Por enquanto a gente atende só algumas das cidades onde a Nio tem fibra, e {cidade} ainda não está entre elas 😕 Por isso não conseguimos abrir o pedido. Se você tiver um endereço em outra cidade, me manda o CEP e o número que a gente confere.'
  || E'\n\n' || 'E se você conhece alguém numa cidade onde a Nio já chega (um parente, um amigo, um colega), me passa o nome e o WhatsApp da pessoa. Se ela instalar a Nio, você ganha R$ 100 no Pix 😉'
 where chave = 'saida_cidade_nao_atendida_indicacao';
do $$
begin
  if exists (select 1 from public.config_mari_textos where chave like 'saida_cidade_nao_atendida%' and texto ilike '%minas%')
     or (select count(*) from public.config_mari_textos where chave in ('saida_cidade_nao_atendida', 'saida_cidade_nao_atendida_indicacao')) <> 2 then
    raise exception '0417: os textos da Saída "Cidade não atendida" não foram trocados';
  end if;
end $$;

-- 7. Conferência final: as 38 de MG intactas, 345 na carteira, 320 ativas ------------------------------------------------------
do $$
declare v_div int; v_tot int; v_at int; v_in int; v_ruim int;
begin
  select count(*) into v_div from _area_antes b
   where not exists (select 1 from public.config_area a
                      where a.id = b.id and a.uf = b.uf and a.cidade = b.cidade and a.cluster = b.cluster and a.ativo);
  select count(*), count(*) filter (where ativo), count(*) filter (where not ativo) into v_tot, v_at, v_in from public.config_area;
  select count(*) into v_ruim from public.config_area
   where (ativo and uf in ('AC', 'AM', 'RR', 'RO', 'MT', 'MS')) or (not ativo and uf not in ('AC', 'AM', 'RR', 'RO', 'MT', 'MS'))
      or portfolio_gdp is null or municipio_gdp is null;
  if v_div <> 0 or v_tot <> 345 or v_at <> 320 or v_in <> 25 or v_ruim <> 0
     or (select count(*) from public.config_area a join public.nio_municipios m on m.uf = a.uf and m.municipio = a.cidade) <> 345 then
    raise exception '0417: conferência falhou — 38 divergentes %, total %, ativas %, inativas %, fora da regra %, espelho nio_municipios %',
      v_div, v_tot, v_at, v_in, v_ruim,
      (select count(*) from public.config_area a join public.nio_municipios m on m.uf = a.uf and m.municipio = a.cidade);
  end if;
end $$;

commit;
