-- NIOGEN | supabase/migrations/0186_meta_capi_eventos.sql | 13/11/2026 — Claude Code (Opus 5)
-- docs/PROMPT_CODE_23_meta_capi_vendas_061126_1305.md, descongelado em 13/11 (a onda 3 saiu com a 1ª instalação, 12h01)
-- + correções posteriores ao prompt 23: (a) o gatilho do Purchase é a OS gravada (decisão D3 do Ricardo, 12/11), não a biometria
-- aprovada; (b) são QUATRO eventos, não dois, e o evento de otimização é o "viável" — o degrau mais profundo que ainda tem volume
-- (14 d: 42 viáveis contra 4 qualificadas e 2 vendas) e o único que já exclui fora_area, sem_cobertura e ja_cliente_nio.
--
-- O CAMINHO DE VOLTA. A entrada já existe (0057/0067: meta_referrals, v_mari_conversa_anuncio). Esta migration faz a FILA do
-- caminho de volta; quem envia é o workflow n8n meta_capi_envio, de 5 em 5 min.
--   1. config_regras.meta_capi — dataset, WABA, de que degrau sai cada evento, fonte do value, "desde" (sem backfill). Regra 15:
--      nada fixo no código. O ID do dataset não é segredo; o token fica só na credencial do n8n.
--   2. meta_eventos — a fila. 1 linha por (fato, evento), event_id único para deduplicação. SEM TELEFONE, nem com hash
--      (decisão do Ricardo de 06/11 12h59). parceiro_id (regra 15). RLS: leitura ao usuário logado, escrita só service role.
--   3. _meta_capi_enfileirar + 2 gatilhos (mari_conversas pela escada do funil, vendas pela OS gravada). Sem ctwa_clid o evento
--      nasce 'sem_clique' e nunca é enviado — fica só como medida de quanto do funil não veio de anúncio.
--   4. meta_capi_pendentes() / meta_capi_marcar() — só service role. O SHA-256 do telefone é calculado DENTRO do banco, na hora
--      do envio: o telefone cru nunca sai daqui e o hash nunca é gravado.
--   5. v_meta_eventos_resumo (por dia e evento) e v_meta_capi_painel (o cartão "A Meta recebeu": hoje e 7 d) · v_venda_meta (o
--      selo Meta ✓/✗/— da venda, com o anúncio de origem).
--   6. conferencia_itens: item novo "Evento da Meta sem erro" (regra 5 do sistema fechado: número novo ganha conferência).
--      Função recriada a partir da produção (= 0183), só com esse item a mais.
--   7. config_regras.pulso_erros_classes: meta_capi_* entra como 'outro_fluxo' — falha de envio à Meta não é falha da Mari (0183).
--
-- O QUE VAI À META, e nada mais: ctwa_clid, o telefone com hash SHA-256 e, no Purchase, moeda + valor. Nunca nome, CPF, e-mail,
-- endereço, CEP, cidade, bairro ou coordenada. O CEP é GATILHO do evento, nunca dado enviado.
-- SEM BACKFILL: só fato a partir de config_regras.meta_capi.desde (gravado agora).
-- As cinco regras do sistema fechado (CLAUDE.md regra 20): 1/2 não se aplicam (não é estado de lead, é fila técnica com dono
-- único, o workflow); 3 o estado da linha muda só por meta_capi_marcar(); 4 a fonte do fato continua única (conversa → NIOGEN,
-- OS → a Nio), esta tabela só espelha o que já foi decidido; 5 item novo em conferencia_itens.

-- ============================== 1. config ==============================
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('meta_capi',
   jsonb_build_object(
     'ligado', true,
     'dataset_id', '1812713633112514',
     'waba_id', '1419511943295487',
     'graph_versao', 'v23.0',
     'desde', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'),
     'tentativas_max', 3,
     'value_fonte', 'comissao',
     'moeda', 'BRL',
     'degraus', jsonb_build_object(
       'ViewContent',   'area_ok',
       'QualifiedLead', 'viavel',
       'LeadSubmitted', 'qualificada')),
   'API de Conversões para mensagens de negócios: dataset da WABA, de que degrau da escada do funil sai cada evento de conversa '
   || '(o Purchase sai da OS gravada), fonte do value do Purchase (comissao | mensal), e "desde" = o instante da 0186, para não '
   || 'haver backfill. ligado=false para a fila parar de nascer. O token NÃO fica aqui (credencial do n8n).',
   'dharma')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao;

-- o erro de envio à Meta não é falha da Mari (0183): entra como outro_fluxo no pulso
update public.config_regras
   set valor = '{"regras": [
      {"classe": "governanca",  "no": ["resposta_fora_niogen", "jornada_furo"]},
      {"classe": "outro_fluxo", "no": ["ged360_desconhecido", "meta_capi_enfileirar", "meta_capi_envio"]},
      {"classe": "outro_fluxo", "workflow_fora": ["mari_principal", "mari_midia_envio", "mari_viabilidade", "mari_credito", "mari_duplicidade"]}
    ]}'::jsonb
 where chave = 'pulso_erros_classes';

-- ============================== 2. a fila ==============================
create table if not exists public.meta_eventos (
  id           bigserial primary key,
  parceiro_id  text not null default 'dharma',
  conversa_id  uuid references public.mari_conversas(id) on delete set null,
  venda_id     uuid references public.vendas(id) on delete set null,
  evento       text not null check (evento in ('ViewContent', 'QualifiedLead', 'LeadSubmitted', 'Purchase')),
  event_id     text not null unique,            -- deduplicação: niogen_<uuid>_<evento>
  fato_em      timestamptz not null,            -- event_time do evento: o instante do FATO, não do envio
  criado_em    timestamptz not null default now(),
  enviado_em   timestamptz,
  status       text not null default 'pendente' check (status in ('pendente', 'enviado', 'erro', 'sem_clique')),
  http_status  int,
  resposta     text,                             -- resposta resumida (até 500 caracteres); nunca o token
  tentativas   int not null default 0,
  fbtrace_id   text
);
comment on table public.meta_eventos is
  'Fila do caminho de volta para a Meta (API de Conversões para mensagens). 1 linha por (fato, evento). O workflow n8n meta_capi_envio lê os pendentes de 5 em 5 min. NÃO guarda telefone, nem com hash — o hash sai de meta_capi_pendentes() na hora do envio. sem_clique = conversa que não veio de anúncio (não tem ctwa_clid): nunca é enviada. 0186.';
comment on column public.meta_eventos.fato_em is 'event_time enviado à Meta: o instante do fato (degrau do funil / OS gravada), não o do envio.';

create index if not exists meta_eventos_pendentes_idx on public.meta_eventos (criado_em)
  where status in ('pendente', 'erro');
create index if not exists meta_eventos_venda_idx on public.meta_eventos (venda_id);
create index if not exists meta_eventos_conversa_idx on public.meta_eventos (conversa_id);
create index if not exists meta_eventos_dia_idx on public.meta_eventos (fato_em desc);

alter table public.meta_eventos enable row level security;
drop policy if exists meta_eventos_ler on public.meta_eventos;
create policy meta_eventos_ler on public.meta_eventos for select to authenticated using (true);
revoke all on public.meta_eventos from anon;
grant select on public.meta_eventos to authenticated;
grant all on public.meta_eventos to service_role;
grant usage, select on sequence public.meta_eventos_id_seq to service_role;

-- ============================== 3. enfileirar ==============================
-- O ctwa_clid da conversa, pela MESMA regra da v_mari_conversa_anuncio (0057/0067): o referral do mesmo telefone até 10 min
-- antes ou depois de a conversa nascer, e só para a conversa mais recente do telefone já aberta quando o clique chegou.
create or replace function public._meta_capi_clid(p_conversa uuid)
returns text language sql stable security definer set search_path = public as $$
  select r.ctwa_clid
    from public.mari_conversas c
    join lateral (
      select r.ctwa_clid, r.recebido_em from public.meta_referrals r
       where r.telefone = c.telefone and r.ad_id is not null and r.ctwa_clid is not null
         and r.recebido_em between c.created_at - interval '10 minutes' and c.created_at + interval '10 minutes'
         and not exists (select 1 from public.mari_conversas c2
                          where c2.telefone = c.telefone and c2.created_at > c.created_at
                            and c2.created_at <= r.recebido_em + interval '2 minutes')
       order by r.recebido_em
       limit 1
    ) r on true
   where c.id = p_conversa
$$;
revoke all on function public._meta_capi_clid(uuid) from public, anon;
grant execute on function public._meta_capi_clid(uuid) to authenticated, service_role;

create or replace function public._meta_capi_enfileirar(p_conversa uuid, p_venda uuid, p_evento text, p_fato_em timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare
  cfg   jsonb;
  conv  uuid := p_conversa;
  tel   text;
  dest  text;
  clid  text;
  ev_id text;   -- nunca chamar "chave": colide com config_regras.chave
begin
  select valor into cfg from public.config_regras where chave = 'meta_capi';
  if cfg is null or coalesce((cfg ->> 'ligado')::boolean, false) is not true then return; end if;

  -- sem backfill: só fato a partir do instante em que a 0186 foi aplicada
  if p_fato_em is null or p_fato_em < (cfg ->> 'desde')::timestamptz then return; end if;

  -- a conversa do fato: a do Purchase vem pela venda
  if conv is null and p_venda is not null then
    select c.id into conv from public.mari_conversas c
     where c.venda_id = p_venda and c.canal = 'whatsapp'
     order by c.created_at desc limit 1;
  end if;
  if conv is null then return; end if;

  select c.telefone, coalesce(c.funil_destino, '') into tel, dest from public.mari_conversas c where c.id = conv;
  -- telefone de teste e conversa marcada como teste/duplicada ficam fora (igual ao retrato e ao _funil_depois)
  if coalesce(tel, '') = '' or tel like '5500000000%' or dest = 'teste_duplicada' then return; end if;

  ev_id := 'niogen_' || coalesce(p_venda::text, conv::text) || '_' || p_evento;
  clid  := public._meta_capi_clid(conv);

  insert into public.meta_eventos (conversa_id, venda_id, evento, event_id, fato_em, status)
  values (conv, p_venda, p_evento, ev_id, p_fato_em,
          case when clid is null then 'sem_clique' else 'pendente' end)
  on conflict (event_id) do nothing;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('meta_capi_enfileirar', sqlerrm);
end;
$$;
revoke all on function public._meta_capi_enfileirar(uuid, uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public._meta_capi_enfileirar(uuid, uuid, text, timestamptz) to service_role;

-- 3a. gatilho na conversa: a escada do funil (0147) nunca volta, então basta ver que degrau ela acabou de cruzar
create or replace function public._meta_capi_conversa()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  cfg   jsonb;
  novo  int;
  velho int;
  ev    text;
  passo int;
begin
  select valor into cfg from public.config_regras where chave = 'meta_capi';
  if cfg is null or coalesce((cfg ->> 'ligado')::boolean, false) is not true then return null; end if;
  if new.funil_etapa is null then return null; end if;

  novo  := public._funil_ordem('etapa', new.funil_etapa);
  velho := case when tg_op = 'UPDATE' then public._funil_ordem('etapa', old.funil_etapa) else 0 end;
  if novo <= velho then return null; end if;

  for ev, passo in
    select d.key, public._funil_ordem('etapa', d.value #>> '{}')
      from jsonb_each(cfg -> 'degraus') d
  loop
    if passo > velho and passo <= novo then
      perform public._meta_capi_enfileirar(new.id, new.venda_id, ev, now());
    end if;
  end loop;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('meta_capi_enfileirar', sqlerrm);
  return null;
end;
$$;
drop trigger if exists mari_conversas_meta_capi on public.mari_conversas;
create trigger mari_conversas_meta_capi after insert or update on public.mari_conversas
  for each row execute function public._meta_capi_conversa();

-- 3b. gatilho na venda: Purchase na OS GRAVADA (decisão D3 do Ricardo, 12/11) — a mesma conta de escada.vendas_os e de
-- _agente_trafego_base.venda_os (0184), para não existir uma terceira definição de venda.
create or replace function public._meta_capi_venda_os(v public.vendas)
returns boolean language sql immutable set search_path = public as $$
  select nullif(btrim(v.nio_os), '') is not null or v.instalado_em is not null
      or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')
$$;

create or replace function public._meta_capi_venda()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public._meta_capi_venda_os(new) then return null; end if;
  if tg_op = 'UPDATE' and public._meta_capi_venda_os(old) then return null; end if;
  perform public._meta_capi_enfileirar(null, new.id, 'Purchase', coalesce(new.nio_os_em, now()));
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('meta_capi_enfileirar', sqlerrm);
  return null;
end;
$$;
drop trigger if exists vendas_meta_capi on public.vendas;
create trigger vendas_meta_capi after insert or update on public.vendas
  for each row execute function public._meta_capi_venda();

-- ============================== 4. o que o n8n lê e escreve ==============================
-- O telefone cru NUNCA sai do banco: o SHA-256 é calculado aqui, na hora do envio, e não é gravado em lugar nenhum.
create or replace function public.meta_capi_pendentes(p_limite int default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg jsonb;
  res jsonb;
begin
  select valor into cfg from public.config_regras where chave = 'meta_capi';
  if cfg is null then return jsonb_build_object('erro', 'config_regras.meta_capi não existe'); end if;

  select coalesce(jsonb_agg(x order by (x ->> 'event_time')::bigint), '[]'::jsonb) into res from (
    select jsonb_build_object(
             'fila', jsonb_build_object('id', e.id, 'tentativas', e.tentativas),
             'event_name', e.evento,
             'event_time', floor(extract(epoch from e.fato_em))::bigint,
             'event_id', e.event_id,
             'action_source', 'business_messaging',
             'messaging_channel', 'whatsapp',
             'user_data', jsonb_build_object(
               'whatsapp_business_account_id', cfg ->> 'waba_id',
               'ctwa_clid', public._meta_capi_clid(e.conversa_id),
               -- E.164 só dígitos, SHA-256 em minúsculas (sha256 nativo do Postgres, sem pgcrypto): o único dado pessoal
               -- que vai à Meta. Calculado aqui, no envio; não é gravado em lugar nenhum.
               'ph', jsonb_build_array(encode(sha256(convert_to(regexp_replace(c.telefone, '\D', '', 'g'), 'UTF8')), 'hex'))),
             'custom_data', case when e.evento = 'Purchase'
               then jsonb_build_object('currency', cfg ->> 'moeda', 'value',
                      coalesce(case when cfg ->> 'value_fonte' = 'mensal' then v.valor_mensal else p.comissao end,
                               p.comissao, v.valor_mensal, 0)::numeric)
               else null end) as x
      from public.meta_eventos e
      join public.mari_conversas c on c.id = e.conversa_id
      left join public.vendas v on v.id = e.venda_id
      left join public.config_planos p on p.id = v.plano_id
     where e.status in ('pendente', 'erro')
       and e.tentativas < coalesce((cfg ->> 'tentativas_max')::int, 3)
       and public._meta_capi_clid(e.conversa_id) is not null
     order by e.fato_em
     limit greatest(1, least(coalesce(p_limite, 50), 200))
  ) s;

  -- test_event_code: só existe enquanto se confere em Gerenciador de Eventos › Testar eventos; tirado depois da prova
  return jsonb_build_object('dataset_id', cfg ->> 'dataset_id', 'graph_versao', cfg ->> 'graph_versao',
                            'test_event_code', cfg ->> 'test_event_code', 'eventos', res);
end;
$$;
comment on function public.meta_capi_pendentes(int) is
  'Os eventos pendentes da fila, já no formato do POST /{dataset_id}/events. O SHA-256 do telefone é calculado aqui e não é gravado; nada além de ctwa_clid, ph e (no Purchase) currency/value vai à Meta. Só service role. 0186.';
revoke all on function public.meta_capi_pendentes(int) from public, anon, authenticated;
grant execute on function public.meta_capi_pendentes(int) to service_role;

create or replace function public.meta_capi_marcar(p_id bigint, p_status text, p_http int default null,
                                                   p_resposta text default null, p_fbtrace text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('enviado', 'erro', 'sem_clique', 'pendente') then
    raise exception 'status inválido: %', p_status using errcode = '22023';
  end if;
  update public.meta_eventos
     set status      = p_status,
         enviado_em  = case when p_status = 'enviado' then now() else enviado_em end,
         tentativas  = tentativas + 1,
         http_status = coalesce(p_http, http_status),
         resposta    = left(coalesce(p_resposta, resposta), 500),
         fbtrace_id  = coalesce(p_fbtrace, fbtrace_id)
   where id = p_id;
end;
$$;
comment on function public.meta_capi_marcar(bigint, text, int, text, text) is
  'O único caminho que muda o estado de uma linha de meta_eventos (regra 3 do sistema fechado). Só service role. 0186.';
revoke all on function public.meta_capi_marcar(bigint, text, int, text, text) from public, anon, authenticated;
grant execute on function public.meta_capi_marcar(bigint, text, int, text, text) to service_role;

-- ============================== 5. o que a tela lê ==============================
create or replace view public.v_meta_eventos_resumo
with (security_invoker = true) as
select (e.fato_em at time zone 'America/Sao_Paulo')::date as dia,
       e.evento,
       count(*)::int                                            as total,
       count(*) filter (where e.status = 'enviado')::int         as enviados,
       count(*) filter (where e.status = 'erro')::int            as erros,
       count(*) filter (where e.status = 'sem_clique')::int      as sem_clique,
       count(*) filter (where e.status = 'pendente')::int        as pendentes,
       max(e.enviado_em)                                        as ultimo_envio
  from public.meta_eventos e
 group by 1, 2;
comment on view public.v_meta_eventos_resumo is
  'A Meta recebeu, por dia e por evento: enviados, erros, sem clique, pendentes e o último envio. 0186.';
grant select on public.v_meta_eventos_resumo to authenticated;

-- o cartão "A Meta recebeu" em Meta Ads › Desempenho: uma linha só, hoje e 7 dias
drop view if exists public.v_meta_capi_painel;
create view public.v_meta_capi_painel
with (security_invoker = true) as
with j as (select (now() at time zone 'America/Sao_Paulo')::date as hoje),
e as (select e.*, (e.fato_em at time zone 'America/Sao_Paulo')::date as dia from public.meta_eventos e)
select
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.evento = 'ViewContent')::int   as cidade_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.evento = 'QualifiedLead')::int as viaveis_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.evento = 'LeadSubmitted')::int as qualificadas_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado' and e.evento = 'Purchase')::int      as vendas_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'enviado')::int                                as enviados_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'sem_clique')::int                             as sem_clique_hoje,
  (select count(*) from e, j where e.dia = j.hoje and e.status = 'erro')::int                                   as erros_hoje,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.evento = 'ViewContent')::int   as cidade_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.evento = 'QualifiedLead')::int as viaveis_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.evento = 'LeadSubmitted')::int as qualificadas_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado' and e.evento = 'Purchase')::int      as vendas_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'enviado')::int                                as enviados_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'sem_clique')::int                             as sem_clique_7d,
  (select count(*) from e, j where e.dia > j.hoje - 7 and e.status = 'erro')::int                                   as erros_7d,
  (select count(*) from e where e.status in ('pendente', 'erro'))::int                                              as na_fila,
  (select max(e.enviado_em) from e)                                                                                 as ultimo_envio,
  -- vermelho: há erro, ou venda de anúncio esperando na fila há mais de 1 h
  (select count(*) from e where e.status in ('pendente', 'erro') and e.criado_em < now() - interval '1 hour')::int   as atrasados,
  (select valor ->> 'dataset_id' from public.config_regras where chave = 'meta_capi')                               as dataset_id;
comment on view public.v_meta_capi_painel is
  'Cartão "A Meta recebeu" (Meta Ads › Desempenho): hoje e 7 dias, por evento, mais fila, atraso e último envio. 0186.';
grant select on public.v_meta_capi_painel to authenticated;

-- o selo Meta ✓ / ✗ / — da venda, com o anúncio de origem
create or replace view public.v_venda_meta
with (security_invoker = true) as
with cfg as (
  select (valor ->> 'desde')::timestamptz as desde from public.config_regras where chave = 'meta_capi'
)
select v.id                               as venda_id,
       a.ad_id,
       a.ad_nome,
       a.adset_nome,
       e.status                            as purchase_status,
       e.enviado_em                        as purchase_em,
       e.resposta                          as purchase_resposta,
       (nullif(btrim(v.nio_os), '') is not null or v.instalado_em is not null
        or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'))
                                           as tem_os,
       case
         when a.ad_id is null              then 'sem_anuncio'   -- selo —
         when e.status = 'enviado'         then 'enviado'       -- selo ✓
         when e.status = 'erro'            then 'erro'          -- selo ✗
         when e.status = 'sem_clique'      then 'sem_clique'    -- selo —
         when e.status = 'pendente'        then 'pendente'      -- selo ⏳
         -- venda anterior à 0186: não há evento e nunca haverá (sem backfill, decisão do prompt 23) — selo —
         when coalesce(v.nio_os_em, v.criado_em) < (select desde from cfg) then 'anterior'
         else 'sem_evento'
       end                                 as meta_status
  from public.vendas v
  left join lateral (
    select ca.ad_id, ca.ad_nome, ca.adset_nome
      from public.v_mari_conversa_anuncio ca
     where ca.venda_id = v.id
     order by ca.created_at desc limit 1
  ) a on true
  left join lateral (
    select e.status, e.enviado_em, e.resposta
      from public.meta_eventos e
     where e.venda_id = v.id and e.evento = 'Purchase'
     order by e.id desc limit 1
  ) e on true;
comment on view public.v_venda_meta is
  'Selo Meta da venda: sem_anuncio/sem_clique/anterior = "—", enviado = "✓", erro = "✗", pendente = "⏳", sem_evento = defeito (veio de anúncio, é posterior à 0186 e não gerou linha na fila), com o anúncio de origem. 0186.';
grant select on public.v_venda_meta to authenticated;

-- ============================== 6. a conferência diária ==============================
-- Regra 5 do sistema fechado: número novo ganha a sua conferência. Função recriada a partir da PRODUÇÃO (= 0183, conferida por
-- pg_get_functiondef em 13/11/2026 21h27), com só o item 13 a mais.
CREATE OR REPLACE FUNCTION public.conferencia_itens(p_parceiro text DEFAULT 'dharma'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  it     jsonb := '[]'::jsonb;
  n      int;
  n2     int;
  ex     text;
  v_tot  int;
  v_soma int;
begin
  if not public._os_pode_gravar() then   -- admin, backoffice, chave de serviço ou CLI
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;

  -- 1. A soma dos destinos é o total de leads
  select count(*) into v_tot from public.v_leads;
  select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.v_leads where destino is not null group by destino) x;
  it := it || jsonb_build_object('codigo', 'soma_destinos', 'nome', 'Soma dos destinos = total de leads',
    'nivel', case when v_tot = v_soma then 'ok' else 'falha' end, 'n', v_tot - v_soma,
    'texto', format('%s leads; os destinos somam %s', v_tot, v_soma),
    'fazer', case when v_tot = v_soma then null else 'Há lead sem destino: avisar o Claude Code (é defeito da v_leads).' end);

  -- 2. Lead em andamento sem vez / sem status · saída sem motivo
  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'em_andamento' and (vez is null or status is null)) x;
  it := it || jsonb_build_object('codigo', 'lead_sem_vez', 'nome', 'Todo lead em andamento tem status e vez',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todos com status e de quem é a vez' else format('%s lead(s) sem status ou sem vez: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir cada um na Leads e registrar o que falta; se o sistema não deixar, avisar o Claude Code.' end);

  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'saida' and saida_motivo is null) x;
  it := it || jsonb_build_object('codigo', 'saida_sem_motivo', 'nome', 'Toda saída tem motivo',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as saídas com motivo da lista única' else format('%s saída(s) sem motivo: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha e registrar o motivo da Saída.' end);

  -- 3. Prazo vencido (ninguém parado em silêncio): fecha, mas é para olhar hoje
  select count(*) into n from public.v_leads where destino = 'em_andamento' and atrasado and not em_espera;
  it := it || jsonb_build_object('codigo', 'atrasados', 'nome', 'Leads com o prazo da vez vencido',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead com prazo vencido' else format('%s lead(s) com o prazo vencido', n) end,
    'fazer', case when n = 0 then null else 'Leads › aba Precisam de ação.' end);

  -- 4. NIOGEN × Nio — venda sem pedido
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select cliente_nome, row_number() over (order by criado_em desc) rn from public.vendas
           where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio')
             and coalesce(nullif(btrim(nio_os), ''), nullif(btrim(nio_pedido), '')) is null) x;
  it := it || jsonb_build_object('codigo', 'venda_sem_pedido', 'nome', 'Toda venda tem o nº do pedido da Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as vendas com pedido' else format('%s venda(s) sem nº de pedido: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Gravar o nº do pedido do portal na ficha.' end);

  -- 5. NIOGEN × Nio — OS aberta que o Operador de OS nunca leu (há mais de 6 h)
  select count(*), string_agg(ped, ', ') filter (where rn <= 5) into n, ex
    from (select coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) as ped,
                 row_number() over (order by v.criado_em desc) rn
            from public.vendas v
           where v.status in ('1_vendido', '2_aguardando_instalacao')
             and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) ~ '^\d{8}$'
             and coalesce(v.nio_os_em, v.nio_pedido_em, v.vendido_em, v.criado_em) < now() - interval '6 hours'
             and not exists (select 1 from public.os_andamento a where a.parceiro_id = p_parceiro
                              and a.pedido = coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')))) x;
  it := it || jsonb_build_object('codigo', 'os_sem_leitura', 'nome', 'Toda OS aberta foi lida na Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as OS abertas com leitura do Operador de OS' else format('%s OS sem nenhuma leitura: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Operações › ⟳ Varrer OS abertas. Se não ler, conferir o CPF e o nº da OS da venda.' end);

  -- 6. NIOGEN × Nio — a Nio enxerga pedido que o NIOGEN não tem
  select count(*) into n from public.portal_pedidos p
   where p.parceiro_id = p_parceiro and p.venda_id is null and upper(coalesce(p.tipo, '')) = 'VENDA'
     and p.ultima_leitura > now() - interval '30 days';
  select coalesce((i.resumo ->> 'sem_venda')::int, 0) into n2 from public.importacoes i
   where i.tipo = 'osab' and i.aplicado_em is not null order by i.aplicado_em desc limit 1;
  it := it || jsonb_build_object('codigo', 'pedido_sem_venda', 'nome', 'Pedido na Nio sem venda no NIOGEN',
    'nivel', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'ok' else 'atencao' end, 'n', coalesce(n, 0) + coalesce(n2, 0),
    'texto', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'nenhum pedido da Nio sem venda nossa'
                  else format('%s no Histórico do portal e %s no último OSAB', coalesce(n, 0), coalesce(n2, 0)) end,
    'fazer', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then null else 'Live › Conferir › casar o pedido com a venda (ou registrar a venda que falta).' end);

  -- 7. NIOGEN × Nio — texto novo da Nio sem tradução e exceção de OS parada há mais de 1 dia
  select count(*), string_agg(texto, ' · ') into n, ex from public.config_os_estados where parceiro_id = p_parceiro and estado is null;
  it := it || jsonb_build_object('codigo', 'os_texto_novo', 'nome', 'Textos da Nio traduzidos',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todos os textos da OS conhecidos' else format('%s texto(s) sem tradução: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Ricardo para traduzir (config_os_estados). Enquanto isso a venda não muda sozinha.' end);

  select count(*) into n from public.os_andamento where parceiro_id = p_parceiro and excecao and excecao_desde < now() - interval '1 day';
  it := it || jsonb_build_object('codigo', 'os_excecao_parada', 'nome', 'Exceção de OS tratada no mesmo dia',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma exceção de OS aberta há mais de 1 dia' else format('%s exceção(ões) de OS aberta(s) há mais de 1 dia', n) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › linhas "OS … na Nio".' end);

  -- 8. NIOGEN × Chatwoot — conversa mexida fora e ação que o Chatwoot não obedeceu
  select count(*) into n from public.mari_conversas c
   where c.canal = 'whatsapp' and c.funil_alerta is not null and coalesce(c.telefone, '') not like '5500000000%';
  select count(*) into n2 from public.chatwoot_acoes a
   where a.status = 'erro' and a.criada_em > now() - interval '7 days'
     and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                       and b.status = 'feita' and b.criada_em > a.criada_em);
  it := it || jsonb_build_object('codigo', 'chatwoot', 'nome', 'NIOGEN e Chatwoot dizem a mesma coisa',
    'nivel', case when n + n2 = 0 then 'ok' else 'atencao' end, 'n', n + n2,
    'texto', case when n + n2 = 0 then 'nenhuma conversa mexida fora e nenhuma ação em erro'
                  else format('%s conversa(s) mexida(s) direto no Chatwoot · %s ação(ões) que o Chatwoot não obedeceu', n, n2) end,
    'fazer', case when n + n2 = 0 then null else 'Live › Conferir.' end);

  -- 9. Dinheiro — toda instalada tem a comissão prevista lançada
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select v.cliente_nome, row_number() over (order by v.instalado_em desc) rn from public.vendas v
           where v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.instalado_em is not null
             and coalesce(v.comissao_prevista, 0) > 0
             and not exists (select 1 from public.comissao_lancamentos l where l.venda_id = v.id and l.tipo = 'prevista')) x;
  it := it || jsonb_build_object('codigo', 'instalada_sem_previsto', 'nome', 'Toda instalada tem a comissão prevista lançada',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as instaladas com o previsto na razão da comissão' else format('%s instalada(s) sem o previsto: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: a razão da comissão não lançou o previsto.' end);

  -- 10. Dinheiro — previsto × extrato (só quando houver Extrato importado e conciliado: etapa 5c)
  select count(*) into n from public.comissao_lancamentos where parceiro_id = p_parceiro and origem = 'extrato';
  it := it || jsonb_build_object('codigo', 'previsto_extrato', 'nome', 'Comissão prevista × Extrato da Nio',
    'nivel', case when n = 0 then 'sem_dado' else 'ok' end, 'n', n,
    'texto', case when n = 0 then 'o Extrato da Nio ainda não foi conciliado (etapa 5c do plano)' else format('%s lançamento(s) do extrato', n) end,
    'fazer', null);

  -- 11. 0182 — risco de recompra: venda em andamento com CPF ou endereço repetido e ainda sem o "Conferi" (só aviso)
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') into n, ex from public.v_venda_risco_recompra;
  it := it || jsonb_build_object('codigo', 'risco_recompra', 'nome', 'Venda em andamento sem risco de recompra',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma venda em andamento com CPF ou endereço repetido' else format('%s venda(s) com CPF ou endereço repetido: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Conferir no portal antes de gravar o pedido e marcar "Conferi" na ficha. Recompra = multa de R$ 500.' end);

  -- 12. 0183 — o vermelho do pulso tem dono: incidente "Mari parada" sem nenhum cliente esperando (últimas 24 h; sem crédito não conta)
  select count(*), string_agg(to_char(inicio_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ', ' order by inicio_em) into n, ex
    from public.pulso_incidentes
   where parceiro_id = p_parceiro and elo = 'mari' and nivel = 'parado' and clientes_esperando_max = 0
     and inicio_em > now() - interval '24 hours' and coalesce(motivo, '') not ilike 'sem crédito%';
  it := it || jsonb_build_object('codigo', 'pulso_mari_sem_espera', 'nome', 'Alarme da Mari só com cliente esperando',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum alarme vermelho da Mari sem cliente esperando nas últimas 24 h'
                  else format('%s alarme(s) vermelho(s) da Mari sem cliente esperando: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o pulso acusou a Mari sem ninguém esperando (ver pulso_incidentes e Mari › Erros).' end);

  -- 13. 0186 — o caminho de volta para a Meta: evento na fila com erro, ou venda de anuncio cuja OS nao virou Purchase enviado
  select count(*), string_agg(distinct evento, ', ') into n, ex from public.meta_eventos
   where parceiro_id = p_parceiro and status = 'erro';
  -- só conta o que já passou de 1 h: a fila normal esvazia de 5 em 5 min
  select count(*) into n2 from public.v_venda_meta vm
   where vm.tem_os and vm.meta_status = 'sem_evento'
      or (vm.tem_os and vm.meta_status = 'pendente'
          and exists (select 1 from public.meta_eventos e where e.venda_id = vm.venda_id and e.evento = 'Purchase'
                        and e.criado_em < now() - interval '1 hour'));
  it := it || jsonb_build_object('codigo', 'meta_capi', 'nome', 'A Meta recebeu o que o NIOGEN gravou',
    'nivel', case when n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', n + n2,
    'texto', case when n > 0 then format('%s evento(s) com erro de envio (%s)', n, left(coalesce(ex, ''), 60))
                  when n2 > 0 then format('%s venda(s) de anuncio esperando o Purchase na fila', n2)
                  else 'nenhum erro de envio e nenhuma venda de anuncio parada na fila' end,
    'fazer', case when n > 0 then 'Avisar o Claude Code: ver meta_eventos (resposta e fbtrace_id) e o workflow meta_capi_envio. Nao reenviar a mao.'
                  when n2 > 0 then 'Se passar de 1 h, o workflow meta_capi_envio pode estar parado: avisar o Claude Code.'
                  else null end);

  return it;
end;
$function$;
revoke all on function public.conferencia_itens(text) from public, anon;
grant execute on function public.conferencia_itens(text) to authenticated, service_role;
