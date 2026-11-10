-- NIOGEN | supabase/migrations/0105_andamento_portal_ged360.sql | 10/11/2026 — Claude Code
-- Prompt docs/Prompt_status_portal_extensao_101126_1106.md (Cowork, rev. 12:45) — andamento do pedido no NIOGEN:
--   A · status do portal PAP lido pela extensão 0.4 no Histórico de Pedidos  → portal_pedidos + portal_status_registrar(p_lote)
--   A2 · status da biometria lido pelo robô do GED360 / BrPronto (n8n)      → nio_biometria  + ged360_registrar(p_linhas, p_erro)
-- Regras:
--   · Nada fixo no código: o que cada status faz está em config_portal_status e config_biometria_resultado (por parceiro, regra 15).
--   · Leitura nunca regride etapa. Mudança de status = evento na linha do tempo (portal_status / biometria_ged360).
--   · Casar pedido × venda só pelo nº (portal) ou pelo CPF (GED360). Por nome, nunca sozinho: pendência "casar pedido" com
--     sugestões e clique do BKO (portal_pedido_casar).
--   · Alertas (Não Venda, Sem contato, risco, link expirado, reprovado, Gross sem OS…) entram na v_jornada (Minha vez) até mudar o
--     status ou o BKO marcar "visto" (andamento_alerta_visto).
--   · v_jornada: a definição atual vira v_jornada_base (copiada do banco com pg_get_viewdef) e a v_jornada ganha uma camada por
--     cima com as mesmas colunas + portal_status, portal_status_desde, biometria_ged, biometria_ged_desde no fim.
--     Próxima migration que precisar reescrever a jornada: reescreva a v_jornada_base (as colunas da base) e mantenha esta camada.

-- ───────────────────────── utilitários ─────────────────────────
create or replace function public._so_digitos(p text)
returns text language sql immutable set search_path = public as $$
  select nullif(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '')
$$;

create or replace function public._nome_norm(p text)
returns text language sql immutable set search_path = public as $$
  select nullif(btrim(regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ', 'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')),
    '[^a-z ]+', ' ', 'g')), '')
$$;

-- "10/11/2026 - 08:52", "10/11/2026 08:52:13", "10/11/2026" → timestamptz (São Paulo). Texto que não for data → nulo.
create or replace function public._br_ts(p text)
returns timestamptz language plpgsql immutable set search_path = public as $$
declare s text := btrim(regexp_replace(coalesce(p, ''), '\s+-\s+', ' '));
begin
  if s !~ '^\d{2}/\d{2}/\d{4}' then return null; end if;
  if s ~ '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}' then return to_timestamp(left(s, 19), 'DD/MM/YYYY HH24:MI:SS')::timestamp at time zone 'America/Sao_Paulo'; end if;
  if s ~ '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}' then return to_timestamp(left(s, 16), 'DD/MM/YYYY HH24:MI')::timestamp at time zone 'America/Sao_Paulo'; end if;
  return to_timestamp(left(s, 10), 'DD/MM/YYYY')::timestamp at time zone 'America/Sao_Paulo';
exception when others then return null;
end;
$$;

-- ───────────────────────── config (regra 15: nada fixo no código) ─────────────────────────
create table if not exists public.config_portal_status (
  parceiro_id  text not null default 'dharma',
  status       text not null,                 -- como o portal escreve, em maiúsculas (coluna STATUS do Histórico)
  acao         text not null check (acao in ('pedido', 'biometria_validada', 'instalada', 'alerta', 'etiqueta')),
  nivel        text check (nivel in ('agora', 'hoje')),
  texto        text,                          -- o que aparece na Minha vez / ficha
  rotulo       text not null,                 -- etiqueta curta das telas
  ordem        int not null default 0,
  primary key (parceiro_id, status)
);
insert into public.config_portal_status (status, acao, nivel, texto, rotulo, ordem) values
  ('AGUARDANDO TRATAMENTO', 'etiqueta', null, null, 'Aguardando tratamento', 10),
  ('CONTATO AGENDADO', 'etiqueta', null, null, 'Contato agendado', 20),
  ('PEDIDO GERADO', 'pedido', null, null, 'Pedido gerado', 30),
  ('SEM CONTATO COM O CLIENTE', 'alerta', 'hoje', 'Portal: a Nio não achou o cliente · ligar para ele', 'Sem contato', 40),
  ('NÃO VENDA', 'alerta', 'agora', 'Portal: Não venda · ver o motivo no portal e corrigir/reenviar', 'Não venda', 50),
  ('VENDA', 'biometria_validada', null, null, 'Venda (sem instalação)', 60),
  ('GROSS', 'instalada', null, null, 'Gross (instalada)', 70)
on conflict (parceiro_id, status) do nothing;
alter table public.config_portal_status enable row level security;
drop policy if exists config_portal_status_ler on public.config_portal_status;
create policy config_portal_status_ler on public.config_portal_status for select to authenticated using (true);
grant select on public.config_portal_status to authenticated;
grant all on public.config_portal_status to service_role;

create table if not exists public.config_biometria_resultado (
  parceiro_id  text not null default 'dharma',
  resultado    text not null,                 -- como o GED360 escreve, em maiúsculas (Resultado da Análise)
  acao         text not null check (acao in ('aprovada', 'risco', 'alerta', 'espera')),
  nivel        text check (nivel in ('agora', 'hoje')),
  texto        text,
  rotulo       text not null,
  primary key (parceiro_id, resultado)
);
insert into public.config_biometria_resultado (resultado, acao, nivel, texto, rotulo) values
  ('DOC. APTO PARA VENDA', 'aprovada', null, null, 'Apta para venda'),
  ('APROVADO', 'aprovada', null, null, 'Aprovada'),
  ('ALERTA DE RISCO', 'risco', 'agora', 'Biometria com ALERTA DE RISCO · falar com o cliente agora', 'Alerta de risco'),
  ('LINK EXPIRADO', 'alerta', 'agora', 'Link da biometria expirou · pedir novo link à Nio e avisar o cliente', 'Link expirado'),
  ('REPROVADO', 'alerta', 'agora', 'Biometria reprovada · ver o motivo no GED360/portal', 'Reprovada'),
  ('EM ANÁLISE', 'espera', null, 'aguardando a Nio conferir', 'Em análise'),
  ('EM REANÁLISE', 'espera', null, 'aguardando a Nio conferir', 'Em reanálise'),
  ('CONCLUÍDO', 'espera', null, 'aguardando a Nio conferir', 'Concluído')
on conflict (parceiro_id, resultado) do nothing;
alter table public.config_biometria_resultado enable row level security;
drop policy if exists config_biometria_resultado_ler on public.config_biometria_resultado;
create policy config_biometria_resultado_ler on public.config_biometria_resultado for select to authenticated using (true);
grant select on public.config_biometria_resultado to authenticated;
grant all on public.config_biometria_resultado to service_role;

-- ───────────────────────── tabelas ─────────────────────────
create table if not exists public.portal_pedidos (
  id               bigserial primary key,
  parceiro_id      text not null default 'dharma',
  pedido_nio       text not null,
  tipo             text,                       -- VENDA · PRÉ-VENDA · INTERESSE
  status           text,                       -- como o portal escreve (maiúsculas)
  data_pedido      timestamptz,
  pdv              text,
  vendedor         text,
  cliente_nome     text,
  segmento         text,
  oferta           text,
  venda_id         uuid references public.vendas(id) on delete set null,   -- null = sem venda no NIOGEN
  status_desde     timestamptz not null default now(),
  primeira_leitura timestamptz not null default now(),
  ultima_leitura   timestamptz not null default now(),
  lido_por         uuid,
  alerta           text,                       -- alerta vivo (Minha vez) até mudar o status ou alguém marcar visto
  alerta_nivel     text,
  alerta_em        timestamptz,
  alerta_visto_em  timestamptz,
  alerta_visto_por uuid,
  unique (parceiro_id, pedido_nio)
);
create index if not exists portal_pedidos_venda_idx on public.portal_pedidos (venda_id);
alter table public.portal_pedidos enable row level security;
drop policy if exists portal_pedidos_ler on public.portal_pedidos;
create policy portal_pedidos_ler on public.portal_pedidos for select to authenticated
  using (public.meu_perfil() = any (array['admin', 'backoffice']));
revoke all on public.portal_pedidos from anon;
grant select on public.portal_pedidos to authenticated;
grant all on public.portal_pedidos to service_role;
grant usage, select on sequence public.portal_pedidos_id_seq to service_role;

-- Cada rodada da extensão (ok ou com erro): base do "portal: última leitura há X h" do Painel.
create table if not exists public.portal_leituras (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  lida_em     timestamptz not null default now(),
  lido_por    uuid,
  pedidos     int not null default 0,
  mudancas    int not null default 0,
  sem_venda   int not null default 0,
  alertas     int not null default 0,
  completa    boolean not null default true,     -- false = parou no meio (erro/portal lento): mostra onde parou
  parou_em    text,
  periodo     text
);
alter table public.portal_leituras enable row level security;
drop policy if exists portal_leituras_ler on public.portal_leituras;
create policy portal_leituras_ler on public.portal_leituras for select to authenticated
  using (public.meu_perfil() = any (array['admin', 'backoffice']));
revoke all on public.portal_leituras from anon;
grant select on public.portal_leituras to authenticated;
grant all on public.portal_leituras to service_role;

create table if not exists public.nio_biometria (
  id               bigserial primary key,
  parceiro_id      text not null default 'dharma',
  protocolo        text not null,
  cpf_cnpj         text,                       -- só dígitos
  data_envio       timestamptz,
  data_conferencia timestamptz,
  tipo_servico     text,
  resultado        text,                       -- como o GED360 escreve (maiúsculas)
  resultado_desde  timestamptz not null default now(),
  primeira_leitura timestamptz not null default now(),
  ultima_leitura   timestamptz not null default now(),
  venda_id         uuid references public.vendas(id) on delete set null,
  desconhecido     boolean not null default false,   -- texto fora do mapa: guarda, avisa o admin, não mexe na venda
  alerta           text,
  alerta_nivel     text,
  alerta_em        timestamptz,
  alerta_visto_em  timestamptz,
  alerta_visto_por uuid,
  unique (parceiro_id, protocolo)
);
create index if not exists nio_biometria_cpf_idx on public.nio_biometria (cpf_cnpj);
create index if not exists nio_biometria_venda_idx on public.nio_biometria (venda_id);
alter table public.nio_biometria enable row level security;
drop policy if exists nio_biometria_ler on public.nio_biometria;
create policy nio_biometria_ler on public.nio_biometria for select to authenticated
  using (public.meu_perfil() = any (array['admin', 'backoffice']));
revoke all on public.nio_biometria from anon;
grant select on public.nio_biometria to authenticated;
grant all on public.nio_biometria to service_role;
grant usage, select on sequence public.nio_biometria_id_seq to service_role;

-- Cada rodada do robô (ok ou falha): base do "GED360 sem leitura desde HH:MM".
create table if not exists public.ged360_leituras (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  lida_em     timestamptz not null default now(),
  ok          boolean not null,
  linhas      int not null default 0,
  mudancas    int not null default 0,
  erro        text
);
alter table public.ged360_leituras enable row level security;
drop policy if exists ged360_leituras_ler on public.ged360_leituras;
create policy ged360_leituras_ler on public.ged360_leituras for select to authenticated
  using (public.meu_perfil() = any (array['admin', 'backoffice']));
revoke all on public.ged360_leituras from anon;
grant select on public.ged360_leituras to authenticated;
grant all on public.ged360_leituras to service_role;
grant usage, select on sequence public.ged360_leituras_id_seq to service_role;

-- ───────────────────────── portal: aplicar o mapa numa venda ─────────────────────────
-- Devolve {alerta, nivel, feito}. Nunca regride. Chamada só de dentro das RPCs (SECURITY DEFINER).
create or replace function public._portal_aplicar(p_pp public.portal_pedidos, p_quem uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg   public.config_portal_status;
  v     public.vendas;
  feito text := null;
  al    text := null;
  niv   text := null;
begin
  select * into cfg from public.config_portal_status where parceiro_id = p_pp.parceiro_id and status = p_pp.status;
  if not found then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'status sem regra (só etiqueta)');
  end if;
  if cfg.acao = 'alerta' then
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', 'alerta');
  end if;
  if p_pp.venda_id is null or cfg.acao = 'etiqueta' then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
  end if;
  select * into v from public.vendas where id = p_pp.venda_id for update;
  if not found or v.status = 'saida' then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'venda em Saída: nada muda');
  end if;

  -- Pedido Gerado (e todo status adiante): venda sem nº ou com nº provisório ganha o nº do portal.
  if cfg.acao in ('pedido', 'biometria_validada', 'instalada')
     and (coalesce(btrim(v.nio_pedido), '') = '' or v.nio_pedido ilike 'PROV-%') then
    update public.vendas set nio_pedido = p_pp.pedido_nio where id = v.id returning * into v;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'pedido_aberto_portal', jsonb_build_object('origem', 'portal_historico', 'pedido', p_pp.pedido_nio), p_quem);
    feito := 'nº do pedido gravado';
  end if;

  -- Venda (contrato ativo, sem instalação) e Gross: a biometria foi aprovada na Nio.
  if cfg.acao in ('biometria_validada', 'instalada') and v.biometria_status is distinct from 'validada' then
    update public.vendas set biometria_status = 'validada' where id = v.id returning * into v;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'biometria_validada', jsonb_build_object('origem', 'portal', 'status_portal', p_pp.status), p_quem);
    feito := concat_ws(' · ', feito, 'biometria validada (portal)');
  end if;

  -- Gross: instalada e apta à comissão = o mesmo status da importação OSAB para "Concluído e válido" (4_ativo_provisorio).
  if cfg.acao = 'instalada' and v.status not in ('4_ativo_provisorio', '5_comissao_firme') then
    begin
      update public.vendas set status = '4_ativo_provisorio', instalado_em = coalesce(instalado_em, now()) where id = v.id returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'instalada_portal', jsonb_build_object('origem', 'portal', 'status_portal', p_pp.status), p_quem);
      feito := concat_ws(' · ', feito, 'Instalada (Gross)');
    exception when others then
      -- A trava da venda recusou (falta OS, viabilidade…): não força; avisa o que falta.
      al := 'Portal: Gross (instalada) · o NIOGEN não conseguiu marcar Instalada — ' || sqlerrm;
      niv := 'hoje';
    end;
  end if;
  return jsonb_build_object('alerta', al, 'nivel', niv, 'feito', feito);
end;
$$;
revoke all on function public._portal_aplicar(public.portal_pedidos, uuid) from public, anon, authenticated;

-- ───────────────────────── portal: RPC da extensão ─────────────────────────
-- p_lote = { pedidos: [{tipo,status,pedido,data,pdv,vendedor,cliente,segmento,oferta}], completa: bool, parou_em: text, periodo: text }
create or replace function public.portal_status_registrar(p_lote jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r        jsonb;
  ped      text;
  st       text;
  ant      public.portal_pedidos;
  pp       public.portal_pedidos;
  vid      uuid;
  res      jsonb;
  n        int := 0;
  mud      int := 0;
  semv     int := 0;
  nal      int := 0;
  quem     uuid := auth.uid();
  novo     boolean;
  mudou    boolean;
  detalhes jsonb := '[]'::jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice atualiza o status do portal.' using errcode = '42501';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_lote -> 'pedidos', '[]'::jsonb)) loop
    ped := btrim(coalesce(r ->> 'pedido', ''));
    st := upper(btrim(coalesce(r ->> 'status', '')));
    if ped !~ '^[A-Za-z0-9._/-]{4,40}$' or st = '' then continue; end if;
    n := n + 1;
    select * into ant from public.portal_pedidos where parceiro_id = 'dharma' and pedido_nio = ped for update;
    novo := not found;
    -- casa pelo nº (nunca pelo nome)
    vid := case when novo then null else ant.venda_id end;
    if vid is null then
      select id into vid from public.vendas where btrim(nio_pedido) = ped and status <> 'saida' order by criado_em desc limit 1;
    end if;
    mudou := novo or ant.status is distinct from st or (ant.venda_id is null and vid is not null);
    insert into public.portal_pedidos as t (pedido_nio, tipo, status, data_pedido, pdv, vendedor, cliente_nome, segmento, oferta,
                                            venda_id, status_desde, lido_por)
    values (ped, upper(nullif(btrim(r ->> 'tipo'), '')), st, public._br_ts(r ->> 'data'), nullif(btrim(r ->> 'pdv'), ''),
            nullif(btrim(r ->> 'vendedor'), ''), nullif(btrim(r ->> 'cliente'), ''), nullif(btrim(r ->> 'segmento'), ''),
            nullif(btrim(r ->> 'oferta'), ''), vid, now(), quem)
    on conflict (parceiro_id, pedido_nio) do update set
      tipo = excluded.tipo, data_pedido = coalesce(excluded.data_pedido, t.data_pedido), pdv = excluded.pdv,
      vendedor = excluded.vendedor, cliente_nome = excluded.cliente_nome, segmento = excluded.segmento, oferta = excluded.oferta,
      venda_id = coalesce(t.venda_id, excluded.venda_id),
      status_desde = case when t.status is distinct from excluded.status then now() else t.status_desde end,
      status = excluded.status, ultima_leitura = now(), lido_por = excluded.lido_por
    returning * into pp;

    if not mudou then continue; end if;
    mud := mud + 1;
    if pp.venda_id is not null then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (pp.venda_id, 'portal_status', jsonb_build_object('de', case when novo then null else ant.status end, 'para', st,
              'pedido', ped, 'lido_em', now()), quem);
    elsif coalesce(pp.tipo, '') = 'VENDA' then
      semv := semv + 1;
    end if;
    res := public._portal_aplicar(pp, quem);
    update public.portal_pedidos set
      alerta = res ->> 'alerta', alerta_nivel = res ->> 'nivel',
      alerta_em = case when res ->> 'alerta' is null then null else now() end,
      alerta_visto_em = null, alerta_visto_por = null
    where id = pp.id;
    if res ->> 'alerta' is not null then nal := nal + 1; end if;
    detalhes := detalhes || jsonb_build_object('pedido', ped, 'status', st, 'venda', pp.venda_id is not null,
                                               'feito', res ->> 'feito', 'alerta', res ->> 'alerta');
  end loop;
  -- Pedidos de Venda ainda sem venda no NIOGEN (todos, não só os novos desta rodada).
  select count(*) into semv from public.portal_pedidos where parceiro_id = 'dharma' and venda_id is null and tipo = 'VENDA';
  insert into public.portal_leituras (lido_por, pedidos, mudancas, sem_venda, alertas, completa, parou_em, periodo)
  values (quem, n, mud, semv, nal, coalesce((p_lote ->> 'completa')::boolean, true), nullif(p_lote ->> 'parou_em', ''),
          nullif(p_lote ->> 'periodo', ''));
  return jsonb_build_object('ok', true, 'pedidos', n, 'mudancas', mud, 'sem_venda', semv, 'alertas', nal, 'detalhes', detalhes,
    'resumo', n || ' pedidos · ' || mud || ' mudanças · ' || semv || ' sem venda no NIOGEN · ' || nal || ' alertas');
end;
$$;
revoke all on function public.portal_status_registrar(jsonb) from public, anon;
grant execute on function public.portal_status_registrar(jsonb) to authenticated;

-- ───────────────────────── portal: casar pedido × venda (clique do BKO) ─────────────────────────
create or replace function public.portal_pedido_casar(p_pedido text, p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  pp  public.portal_pedidos;
  v   public.vendas;
  res jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice casa pedido com venda.' using errcode = '42501';
  end if;
  select * into pp from public.portal_pedidos where parceiro_id = 'dharma' and pedido_nio = btrim(p_pedido) for update;
  if not found then raise exception 'Pedido % não está na leitura do portal.', p_pedido; end if;
  if pp.venda_id is not null then raise exception 'Este pedido já está casado com uma venda.'; end if;
  select * into v from public.vendas where id = p_venda;
  if not found then raise exception 'Venda não encontrada.'; end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída; reabra antes.'; end if;
  if exists (select 1 from public.portal_pedidos x where x.venda_id = p_venda and x.tipo = 'VENDA' and x.id <> pp.id) then
    raise exception 'Esta venda já está casada com outro pedido do portal.';
  end if;
  -- 10/11 (ensaio com a Mirian): o nº gravado na venda pode ser outro número do portal (ex.: 8 dígitos) e o Histórico mostra o
  -- ID de 18 dígitos. Casar só LIGA os dois (portal_pedidos.venda_id) e guarda os dois números no evento; o nº da venda só é
  -- trocado quando está vazio ou é provisório (PROV-), pelo _portal_aplicar.
  update public.portal_pedidos set venda_id = p_venda where id = pp.id returning * into pp;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'portal_pedido_casado', jsonb_build_object('pedido', pp.pedido_nio, 'status', pp.status,
          'pedido_na_venda', nullif(btrim(coalesce(v.nio_pedido, '')), '')), auth.uid());
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'portal_status', jsonb_build_object('de', null, 'para', pp.status, 'pedido', pp.pedido_nio, 'lido_em', pp.ultima_leitura), auth.uid());
  res := public._portal_aplicar(pp, auth.uid());
  update public.portal_pedidos set alerta = res ->> 'alerta', alerta_nivel = res ->> 'nivel',
    alerta_em = case when res ->> 'alerta' is null then null else now() end, alerta_visto_em = null
  where id = pp.id;
  return jsonb_build_object('ok', true, 'feito', res ->> 'feito', 'alerta', res ->> 'alerta');
end;
$$;
revoke all on function public.portal_pedido_casar(text, uuid) from public, anon;
grant execute on function public.portal_pedido_casar(text, uuid) to authenticated;

-- ───────────────────────── GED360: aplicar o mapa numa venda ─────────────────────────
create or replace function public._ged360_aplicar(p_b public.nio_biometria)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg public.config_biometria_resultado;
  v   public.vendas;
  feito text := null;
begin
  select * into cfg from public.config_biometria_resultado where parceiro_id = p_b.parceiro_id and resultado = p_b.resultado;
  if not found then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'desconhecido');
  end if;
  -- "Concluído" sem Data da Conferência = ainda esperando a Nio; com conferência e sem regra própria, também espera (não chuta).
  if cfg.acao in ('espera') then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'espera');
  end if;
  if cfg.acao = 'alerta' then
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', 'alerta');
  end if;
  if p_b.venda_id is null then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
  end if;
  select * into v from public.vendas where id = p_b.venda_id for update;
  if not found or v.status = 'saida' then return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null); end if;
  if cfg.acao = 'aprovada' then
    if v.biometria_status is distinct from 'validada' then
      if coalesce(btrim(v.nio_pedido), '') = '' then
        return jsonb_build_object('alerta', 'Biometria aprovada no GED360, mas a venda está sem o nº do pedido · gravar o pedido',
                                  'nivel', 'hoje', 'feito', null);
      end if;
      update public.vendas set biometria_status = 'validada' where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v.id, 'biometria_validada', jsonb_build_object('origem', 'ged360', 'protocolo', p_b.protocolo, 'resultado', p_b.resultado));
      feito := 'biometria validada (GED360)';
    end if;
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', feito);
  end if;
  if cfg.acao = 'risco' then
    -- Não regride: só antes da OS, e só se o GED360 disse isso DEPOIS de alguém marcar validada (vale o mais recente).
    if v.status = '0_qualificado' and (v.biometria_status is distinct from 'validada' or v.biometria_validada_em < p_b.resultado_desde)
       and v.biometria_status is distinct from 'com_risco' then
      update public.vendas set biometria_status = 'com_risco' where id = v.id;
      feito := 'biometria com risco (GED360)';
    end if;
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', feito);
  end if;
  return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
end;
$$;
revoke all on function public._ged360_aplicar(public.nio_biometria) from public, anon, authenticated;

-- ───────────────────────── GED360: RPC do robô (só service_role) ─────────────────────────
-- p_linhas = [{protocolo, cpf_cnpj, data_envio, data_conferencia, tipo_servico, resultado}] · p_erro = texto da falha (ou null)
create or replace function public.ged360_registrar(p_linhas jsonb, p_erro text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r     jsonb;
  prot  text;
  res   text;
  ant   public.nio_biometria;
  b     public.nio_biometria;
  ap    jsonb;
  novo  boolean;
  n     int := 0;
  mud   int := 0;
  vid   uuid;
  desc_ text[] := '{}';
begin
  if p_erro is not null then
    insert into public.ged360_leituras (ok, erro) values (false, left(p_erro, 300));
    return jsonb_build_object('ok', false, 'erro', p_erro);
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    prot := btrim(coalesce(r ->> 'protocolo', ''));
    res := upper(btrim(regexp_replace(coalesce(r ->> 'resultado', ''), '\s+', ' ', 'g')));
    if prot = '' then continue; end if;
    n := n + 1;
    select * into ant from public.nio_biometria where parceiro_id = 'dharma' and protocolo = prot for update;
    novo := not found;
    insert into public.nio_biometria as t (protocolo, cpf_cnpj, data_envio, data_conferencia, tipo_servico, resultado, desconhecido)
    values (prot, public._so_digitos(r ->> 'cpf_cnpj'), public._br_ts(r ->> 'data_envio'), public._br_ts(r ->> 'data_conferencia'),
            nullif(btrim(r ->> 'tipo_servico'), ''), nullif(res, ''),
            nullif(res, '') is not null and not exists (select 1 from public.config_biometria_resultado c where c.parceiro_id = 'dharma' and c.resultado = res))
    on conflict (parceiro_id, protocolo) do update set
      cpf_cnpj = coalesce(excluded.cpf_cnpj, t.cpf_cnpj), data_envio = coalesce(excluded.data_envio, t.data_envio),
      data_conferencia = coalesce(excluded.data_conferencia, t.data_conferencia), tipo_servico = excluded.tipo_servico,
      resultado_desde = case when t.resultado is distinct from excluded.resultado then now() else t.resultado_desde end,
      resultado = coalesce(excluded.resultado, t.resultado), desconhecido = excluded.desconhecido, ultima_leitura = now()
    returning * into b;
    if b.desconhecido and (novo or ant.resultado is distinct from b.resultado) then
      desc_ := desc_ || b.resultado;
    end if;
  end loop;

  -- Casar pelo CPF (só dígitos) com a venda de pedido aberto (antes da instalação); nunca pelo nome.
  update public.nio_biometria nb set venda_id = x.venda_id
  from (select distinct on (nb2.id) nb2.id, v.id as venda_id
          from public.nio_biometria nb2
          join public.vendas v on public._so_digitos(v.cliente_cpf_cnpj) = nb2.cpf_cnpj
         where nb2.venda_id is null and nb2.cpf_cnpj is not null and v.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
         order by nb2.id, v.criado_em desc) x
  where nb.id = x.id;

  -- Para cada venda, vale o protocolo de Data de Envio mais recente; aplica o mapa quando o resultado mudou (ou casou agora).
  for b in
    select distinct on (venda_id) * from public.nio_biometria
     where venda_id is not null and (ultima_leitura > now() - interval '5 minutes')
     order by venda_id, data_envio desc nulls last, id desc
  loop
    if b.desconhecido then continue; end if;
    if exists (select 1 from public.eventos_venda e where e.venda_id = b.venda_id and e.tipo = 'biometria_ged360'
                and e.detalhe ->> 'protocolo' = b.protocolo and e.detalhe ->> 'para' = b.resultado) then
      continue;   -- já aplicado
    end if;
    mud := mud + 1;
    insert into public.eventos_venda (venda_id, tipo, detalhe)
    values (b.venda_id, 'biometria_ged360', jsonb_build_object('protocolo', b.protocolo, 'para', b.resultado,
            'envio', b.data_envio, 'conferencia', b.data_conferencia));
    ap := public._ged360_aplicar(b);
    update public.nio_biometria set alerta = ap ->> 'alerta', alerta_nivel = ap ->> 'nivel',
      alerta_em = case when ap ->> 'alerta' is null then null else now() end, alerta_visto_em = null
    where id = b.id;
  end loop;
  -- Sem venda: os alertas valem igual (pendência "biometria sem venda" mostra o resultado).
  update public.nio_biometria nb set alerta = c.texto, alerta_nivel = c.nivel, alerta_em = coalesce(nb.alerta_em, now())
    from public.config_biometria_resultado c
   where nb.venda_id is null and c.parceiro_id = nb.parceiro_id and c.resultado = nb.resultado and c.acao in ('alerta', 'risco')
     and nb.alerta is null and nb.alerta_visto_em is null;

  if array_length(desc_, 1) > 0 then
    insert into public.mari_erros (no_n8n, mensagem, payload)
    values ('ged360_desconhecido', 'GED360: resultado novo fora do mapa (config_biometria_resultado) — completar o mapa',
            jsonb_build_object('resultados', to_jsonb(desc_)));
  end if;
  insert into public.ged360_leituras (ok, linhas, mudancas) values (true, n, mud);
  return jsonb_build_object('ok', true, 'linhas', n, 'mudancas', mud, 'desconhecidos', to_jsonb(desc_));
end;
$$;
revoke all on function public.ged360_registrar(jsonb, text) from public, anon, authenticated;
grant execute on function public.ged360_registrar(jsonb, text) to service_role;

-- ───────────────────────── alerta visto (tira da Minha vez) ─────────────────────────
create or replace function public.andamento_alerta_visto(p_origem text, p_chave text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if p_origem = 'portal' then
    update public.portal_pedidos set alerta_visto_em = now(), alerta_visto_por = auth.uid() where parceiro_id = 'dharma' and pedido_nio = p_chave;
  elsif p_origem = 'ged360' then
    update public.nio_biometria set alerta_visto_em = now(), alerta_visto_por = auth.uid() where parceiro_id = 'dharma' and protocolo = p_chave;
  else
    raise exception 'Origem inválida.';
  end if;
end;
$$;
revoke all on function public.andamento_alerta_visto(text, text) from public, anon;
grant execute on function public.andamento_alerta_visto(text, text) to authenticated;

-- ───────────────────────── views ─────────────────────────
-- Andamento por venda (ficha, listas): o último status do portal e a biometria do protocolo mais recente.
create or replace view public.v_venda_andamento with (security_invoker = true) as
select v.id as venda_id,
       pp.pedido_nio as portal_pedido, pp.status as portal_status, cps.rotulo as portal_rotulo, pp.status_desde as portal_desde,
       pp.ultima_leitura as portal_lido_em, pp.oferta as portal_oferta,
       case when pp.alerta_visto_em is null then pp.alerta end as portal_alerta, pp.alerta_nivel as portal_alerta_nivel,
       nb.protocolo as bio_protocolo, nb.resultado as bio_resultado, cbr.rotulo as bio_rotulo, cbr.acao as bio_acao,
       nb.data_envio as bio_envio, nb.data_conferencia as bio_conferencia, nb.resultado_desde as bio_desde,
       nb.ultima_leitura as bio_lido_em, nb.desconhecido as bio_desconhecido,
       case when nb.alerta_visto_em is null then nb.alerta end as bio_alerta, nb.alerta_nivel as bio_alerta_nivel
  from public.vendas v
  left join lateral (select * from public.portal_pedidos p where p.venda_id = v.id order by p.ultima_leitura desc limit 1) pp on true
  left join public.config_portal_status cps on cps.parceiro_id = pp.parceiro_id and cps.status = pp.status
  left join lateral (select * from public.nio_biometria b where b.venda_id = v.id order by b.data_envio desc nulls last, b.id desc limit 1) nb on true
  left join public.config_biometria_resultado cbr on cbr.parceiro_id = nb.parceiro_id and cbr.resultado = nb.resultado
 where pp.id is not null or nb.id is not null;
grant select on public.v_venda_andamento to authenticated;

-- Pendências sem venda (Minha vez): "casar pedido" (pedido de Venda do portal sem venda) e "biometria sem venda".
create or replace view public.v_andamento_pendencias with (security_invoker = true) as
select 'casar_pedido'::text as tipo, p.pedido_nio as chave, p.cliente_nome as nome, p.status as status,
       coalesce(c.rotulo, p.status) as rotulo, p.oferta, p.data_pedido as quando, p.primeira_leitura as desde, p.alerta,
       coalesce((select jsonb_agg(jsonb_build_object('venda_id', s.id, 'nome', s.cliente_nome, 'pedido', s.nio_pedido, 'cidade', s.cidade,
                                                     'etapa', s.etapa))
                   from (select v.id, v.cliente_nome, v.nio_pedido, v.cidade, public.jornada_nome(public.jornada_etapa(v.status, v.nio_pedido)) as etapa
                           from public.vendas v
                          where v.status <> 'saida'
                            and not exists (select 1 from public.portal_pedidos x where x.venda_id = v.id and x.tipo = 'VENDA')
                            and (public._nome_norm(v.cliente_nome) = public._nome_norm(p.cliente_nome)
                                 or (split_part(public._nome_norm(v.cliente_nome), ' ', 1) = split_part(public._nome_norm(p.cliente_nome), ' ', 1)
                                     and regexp_replace(public._nome_norm(v.cliente_nome), '^.* ', '') = regexp_replace(public._nome_norm(p.cliente_nome), '^.* ', '')))
                          order by v.criado_em desc limit 3) s), '[]'::jsonb) as sugestoes
  from public.portal_pedidos p
  left join public.config_portal_status c on c.parceiro_id = p.parceiro_id and c.status = p.status
 where p.venda_id is null and p.tipo = 'VENDA'
union all
select 'biometria_sem_venda', b.protocolo, null, b.resultado, coalesce(c.rotulo, b.resultado), null, b.data_envio, b.primeira_leitura,
       case when b.alerta_visto_em is null then b.alerta end, '[]'::jsonb
  from public.nio_biometria b
  left join public.config_biometria_resultado c on c.parceiro_id = b.parceiro_id and c.resultado = b.resultado
 where b.venda_id is null and b.data_envio > now() - interval '30 days' and b.alerta_visto_em is null;
grant select on public.v_andamento_pendencias to authenticated;

-- Painel: contagens e saúde das leituras.
create or replace view public.v_andamento_resumo with (security_invoker = true) as
select
  (select coalesce(jsonb_object_agg(coalesce(c.rotulo, x.status), x.n), '{}'::jsonb)
     from (select status, count(*) n from public.portal_pedidos where tipo = 'VENDA' group by 1) x
     left join public.config_portal_status c on c.parceiro_id = 'dharma' and c.status = x.status) as por_status_portal,
  (select coalesce(jsonb_object_agg(coalesce(c.rotulo, x.resultado), x.n), '{}'::jsonb)
     from (select resultado, count(*) n from public.nio_biometria where data_envio > now() - interval '30 days' group by 1) x
     left join public.config_biometria_resultado c on c.parceiro_id = 'dharma' and c.resultado = x.resultado) as por_resultado_bio,
  (select max(lida_em) from public.portal_leituras where completa) as portal_ultima_leitura,
  (select max(lida_em) from public.ged360_leituras where ok) as ged360_ultima_ok,
  (select count(*) from (select ok from public.ged360_leituras order by id desc limit 2) z where not z.ok) as ged360_falhas_seguidas,
  (select erro from public.ged360_leituras order by id desc limit 1) as ged360_ultimo_erro,
  (select max(lida_em) from public.ged360_leituras) as ged360_ultima_tentativa,
  (select count(*) from public.portal_pedidos where venda_id is null and tipo = 'VENDA') as casar_pedido,
  (select count(*) from public.nio_biometria where venda_id is null and data_envio > now() - interval '30 days' and alerta_visto_em is null) as bio_sem_venda,
  (select count(*) from public.nio_biometria where desconhecido) as bio_desconhecidos;
grant select on public.v_andamento_resumo to authenticated;

-- ───────────────────────── v_jornada: a base + a camada do andamento ─────────────────────────
do $$
begin
  if to_regclass('public.v_jornada_base') is null then
    execute 'create view public.v_jornada_base with (security_invoker = true) as ' || pg_get_viewdef('public.v_jornada'::regclass, true);
  end if;
end $$;
grant select on public.v_jornada_base to authenticated;

create or replace view public.v_jornada with (security_invoker = true) as
select j.tipo, j.chave, j.venda_id, j.conversa_id, j.chatwoot_conversation_id, j.nome, j.cidade, j.plano, j.origem, j.etapa, j.etapa_nome,
       j.precisa_acao or a.usa as precisa_acao,
       case when a.usa then a.nivel else j.nivel end as nivel,
       case when a.usa then a.texto else j.o_que_fazer end as o_que_fazer,
       case when a.usa then 'abrir'::text else j.botao end as botao,
       case when a.usa then a.em else j.desde end as desde,
       j.dono_tipo, j.dono_nome, j.pendencia, j.acao_id, j.status_venda, j.parceiro_id, j.sem_dono_min, j.pedido_provisorio,
       j.cliente_confirmou, j.confirmou_em,
       an.portal_status, an.portal_desde as portal_status_desde, an.bio_resultado as biometria_ged, an.bio_desde as biometria_ged_desde
  from public.v_jornada_base j
  left join public.v_venda_andamento an on an.venda_id = j.venda_id
  left join lateral (
    select x.texto, x.nivel, x.em from (values
             (an.portal_alerta, an.portal_alerta_nivel, an.portal_desde),
             (an.bio_alerta, an.bio_alerta_nivel, an.bio_desde)) x(texto, nivel, em)
     where x.texto is not null
     order by case x.nivel when 'agora' then 0 else 1 end, x.em
     limit 1) al on true
  -- O alerta do andamento entra quando a linha não está em "agora" (o que já é urgente continua na frente) e é pelo menos tão
  -- urgente quanto o que ela mostra.
  cross join lateral (
    select al.texto, al.nivel, al.em,
           coalesce(al.texto is not null and j.etapa > 0 and j.nivel <> 'agora'
             and (case al.nivel when 'agora' then 0 else 1 end) <= (case j.nivel when 'hoje' then 1 else 2 end), false) as usa) a;
