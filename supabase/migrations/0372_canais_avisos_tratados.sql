-- NIOGEN | supabase/migrations/0372_canais_avisos_tratados.sql | 23/11/2026 — Claude Code (Opus 5.5)
-- Prompt docs/Prompt_canais_avisos_ajustes_231126_1912.md (Ricardo, 23/11 19h12): os avisos de "Precisa de ação" da tela Canais
-- não sabiam o que já tinha sido tratado (teto de CPC e palavras novas, às 16h20) e iam virar papel de parede.
--  (1) canal_aviso: um episódio por aviso (canal × chave) — aberto_em, visto_em, fechado_em, valor_abertura, valor_atual (o
--      indicador do aviso, "maior = pior"). canal_aviso_tratado: a trilha de "marcar como tratado" (quem, quando, nota, valor no
--      tratamento). Leitura: admin/backoffice. Escrita: só pelas funções.
--  (2) canal_avisos_sincronizar(canal, avisos[]): a tela manda os avisos que calculou (chave, título, valor); a função abre o
--      episódio novo, atualiza valor_atual/visto_em, fecha o que sumiu e devolve, por chave, aberto_em e se fica ESCONDIDO.
--      Regra (uma fonte só, no banco): tratado esconde por config_meta_ads_regras.aviso_tratado_horas (48 h); passado esse prazo,
--      volta se o indicador não melhorou (valor_atual >= valor no tratamento); melhorou → segue escondido, e volta assim que piorar
--      de novo. Nunca some para sempre: episódio novo (o aviso sumiu e voltou) começa sem tratamento.
--  (3) canal_aviso_tratar(canal, chave, nota): admin/backoffice; só aviso aberto; grava a trilha.
--  (4) config_meta_ads_regras: aviso_tratado_horas = 48 · clique_conversa_min_cliques = 10 · clique_conversa_taxa_min = 0.30
--      (o aviso novo "Cliques que não viraram conversa" do Google; nada fixo no código, regra 15).
--  (5) conferencia_itens(): item 32 "Avisos tratados voltam" (injetado na versão no ar).
-- Regra 20: (1) nada toca lead · (2) tratar só por canal_aviso_tratar; o episódio só por canal_avisos_sincronizar · (3) o botão
-- "marcar como tratado" só aparece para aviso aberto e para admin/backoffice (o que a função aceita) · (4) cliques só de
-- google_ads_diario, conversas só de mari_conversas: o aviso cruza na tela, não guarda cópia · (5) item 32.
begin;

insert into public.config_meta_ads_regras (parceiro_id, chave, valor, descricao)
select 'dharma', x.chave, x.valor, x.descricao from (values
  ('aviso_tratado_horas', 48::numeric, 'Tela Canais: horas que um aviso marcado como tratado fica escondido; depois volta se o indicador não melhorou (0372)'),
  ('clique_conversa_min_cliques', 10, 'Aviso "Cliques que não viraram conversa": mínimo de cliques no período para avaliar; abaixo disso, "amostra pequena" (0372)'),
  ('clique_conversa_taxa_min', 0.30, 'Aviso "Cliques que não viraram conversa": dispara com conversas ÷ cliques abaixo disto (0372)')) x(chave, valor, descricao)
 where not exists (select 1 from public.config_meta_ads_regras c where c.parceiro_id = 'dharma' and c.chave = x.chave);

create table if not exists public.canal_aviso (
  id              bigserial primary key,
  parceiro_id     text not null default 'dharma',
  canal           text not null references public.config_canais(canal),
  aviso_chave     text not null,
  titulo          text,
  aberto_em       timestamptz not null default now(),
  visto_em        timestamptz not null default now(),
  fechado_em      timestamptz,
  valor_abertura  numeric,
  valor_atual     numeric
);
create unique index if not exists canal_aviso_aberto on public.canal_aviso (parceiro_id, canal, aviso_chave) where fechado_em is null;

create table if not exists public.canal_aviso_tratado (
  id                  bigserial primary key,
  parceiro_id         text not null default 'dharma',
  canal               text not null references public.config_canais(canal),
  aviso_chave         text not null,
  aviso_id            bigint references public.canal_aviso(id),
  tratado_em          timestamptz not null default now(),
  tratado_por         uuid,
  nota                text,
  valor_no_tratamento numeric
);
create index if not exists canal_aviso_tratado_aviso on public.canal_aviso_tratado (aviso_id, tratado_em desc);

alter table public.canal_aviso enable row level security;
alter table public.canal_aviso_tratado enable row level security;
drop policy if exists canal_aviso_ler on public.canal_aviso;
create policy canal_aviso_ler on public.canal_aviso for select to authenticated
  using (coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice'));
drop policy if exists canal_aviso_tratado_ler on public.canal_aviso_tratado;
create policy canal_aviso_tratado_ler on public.canal_aviso_tratado for select to authenticated
  using (coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice'));
grant select on public.canal_aviso, public.canal_aviso_tratado to authenticated;
grant all on public.canal_aviso, public.canal_aviso_tratado to service_role;
grant usage on sequence public.canal_aviso_id_seq, public.canal_aviso_tratado_id_seq to service_role;

-- o estado de um episódio, numa regra só (a tela e a conferência leem daqui)
create or replace function public._canal_aviso_estado(p_id bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  with a as (select * from public.canal_aviso where id = p_id),
       t as (select x.* from public.canal_aviso_tratado x where x.aviso_id = p_id order by x.tratado_em desc limit 1),
       h as (select coalesce((select valor from public.config_meta_ads_regras where parceiro_id = 'dharma' and chave = 'aviso_tratado_horas'), 48) as horas)
  select jsonb_build_object(
    'chave', a.aviso_chave, 'aberto_em', a.aberto_em, 'valor_atual', a.valor_atual,
    'tratado_em', t.tratado_em, 'tratado_nota', t.nota, 'valor_no_tratamento', t.valor_no_tratamento,
    'escondido', case when t.id is null then false
                      when t.tratado_em > now() - make_interval(hours => (select horas from h)::int) then true
                      else coalesce(a.valor_atual < t.valor_no_tratamento, false) end,
    'volta_em', case when t.id is not null then t.tratado_em + make_interval(hours => (select horas from h)::int) end)
    from a left join t on true
$$;
revoke execute on function public._canal_aviso_estado(bigint) from public, anon, authenticated;

create or replace function public.canal_avisos_sincronizar(p_canal text, p_avisos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_out jsonb := '{}'::jsonb; v_id bigint; v_chaves text[];
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and auth.role() is distinct from 'service_role' then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.config_canais where canal = p_canal) then raise exception 'Canal desconhecido: %', p_canal; end if;
  if jsonb_typeof(coalesce(p_avisos, '[]')) <> 'array' then raise exception 'p_avisos precisa ser array' using errcode = '22023'; end if;
  v_chaves := array(select x->>'chave' from jsonb_array_elements(p_avisos) x where coalesce(x->>'chave', '') <> '');
  -- o que sumiu fecha o episódio (voltando, é aviso novo, sem o tratamento antigo)
  update public.canal_aviso set fechado_em = now()
   where parceiro_id = 'dharma' and canal = p_canal and fechado_em is null and aviso_chave <> all (v_chaves);
  for r in select x from jsonb_array_elements(p_avisos) x where coalesce(x->>'chave', '') <> '' loop
    update public.canal_aviso set visto_em = now(), titulo = coalesce(r->>'titulo', titulo), valor_atual = (r->>'valor')::numeric
     where parceiro_id = 'dharma' and canal = p_canal and aviso_chave = r->>'chave' and fechado_em is null
    returning id into v_id;
    if v_id is null then
      insert into public.canal_aviso (canal, aviso_chave, titulo, valor_abertura, valor_atual)
      values (p_canal, r->>'chave', r->>'titulo', (r->>'valor')::numeric, (r->>'valor')::numeric)
      returning id into v_id;
    end if;
    v_out := v_out || jsonb_build_object(r->>'chave', public._canal_aviso_estado(v_id));
    v_id := null;
  end loop;
  return jsonb_build_object('avisos', v_out,
    'horas', coalesce((select valor from public.config_meta_ads_regras where parceiro_id = 'dharma' and chave = 'aviso_tratado_horas'), 48));
end $$;
revoke execute on function public.canal_avisos_sincronizar(text, jsonb) from public, anon;
grant execute on function public.canal_avisos_sincronizar(text, jsonb) to authenticated, service_role;

create or replace function public.canal_aviso_tratar(p_canal text, p_aviso text, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a record;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and auth.role() is distinct from 'service_role' then
    raise exception 'Só admin ou backoffice marcam aviso como tratado.' using errcode = '42501';
  end if;
  select * into a from public.canal_aviso
   where parceiro_id = 'dharma' and canal = p_canal and aviso_chave = p_aviso and fechado_em is null;
  if not found then raise exception 'Este aviso não está aberto (já sumiu ou nunca apareceu).'; end if;
  insert into public.canal_aviso_tratado (canal, aviso_chave, aviso_id, tratado_por, nota, valor_no_tratamento)
  values (p_canal, p_aviso, a.id, auth.uid(), nullif(btrim(coalesce(p_nota, '')), ''), a.valor_atual);
  return public._canal_aviso_estado(a.id);
end $$;
revoke execute on function public.canal_aviso_tratar(text, text, text) from public, anon;
grant execute on function public.canal_aviso_tratar(text, text, text) to authenticated, service_role;

-- (5) conferência: item 32, injetado antes do "return it;" final (vale com qualquer versão no ar)
do $m$
declare
  d text := pg_get_functiondef('public.conferencia_itens(text)'::regprocedure);
  fim text := E'\n  return it;\nend';
  item text := $x$
  -- 32. 0372 — avisos da tela Canais: tratado não fica escondido além do prazo sem ter melhorado; todo aviso aberto tem data
  select count(*) filter (where (public._canal_aviso_estado(a.id)->>'escondido')::boolean
                             and (public._canal_aviso_estado(a.id)->>'volta_em')::timestamptz < now()
                             and a.valor_atual >= (public._canal_aviso_estado(a.id)->>'valor_no_tratamento')::numeric),
         count(*) filter (where a.aberto_em is null),
         string_agg(a.canal || ': ' || coalesce(a.titulo, a.aviso_chave), ' · ') filter (where a.visto_em < now() - interval '3 days')
    into n, n2, ex
    from public.canal_aviso a where a.fechado_em is null;
  it := it || jsonb_build_object('codigo', 'canal_avisos', 'nome', 'Avisos da tela Canais: tratado volta, aberto tem data',
    'nivel', case when n + n2 > 0 then 'falha' when ex is not null then 'atencao' else 'ok' end, 'n', n + n2,
    'texto', case when n + n2 = 0 and ex is null then 'nenhum aviso escondido além do prazo; todos com data de abertura'
                  else concat_ws(' · ',
                         case when n > 0 then format('%s aviso(s) tratado(s) escondido(s) além do prazo sem melhorar', n) end,
                         case when n2 > 0 then format('%s aviso(s) sem data de abertura', n2) end,
                         case when ex is not null then left('aviso aberto e não visto há 3 dias (ninguém abriu a tela Canais): ' || ex, 240) end) end,
    'fazer', case when n + n2 > 0 then 'Avisar o Claude Code: a regra dos avisos tratados não está valendo (é defeito).'
                  when ex is not null then 'Abrir a tela Canais e ler os avisos.' end);
$x$;
begin
  if position('canal_avisos' in d) > 0 then raise notice '0372: o item canal_avisos já existe'; return; end if;
  if (length(d) - length(replace(d, fim, ''))) / length(fim) <> 1 then
    raise exception '0372: não achei um único "return it;" no fim de conferencia_itens — refazer a migration';
  end if;
  execute replace(d, fim, item || fim);
end $m$;

commit;
