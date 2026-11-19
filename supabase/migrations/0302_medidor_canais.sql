-- NIOGEN | supabase/migrations/0302_medidor_canais.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Prompt docs/Prompt_medidor_canais_indicacao_181126_2155.md, parte A (Dia 1 do projeto "1 canal por dia", 19 a 30/11).
-- Sem saber quanto cada canal custa por venda, 12 origens novas viram uma mistura sem decisão. O que muda:
--  (1) config_canais: a lista oficial de canais (nada fixo no código). As checagens fixas de origem em mari_conversas e vendas
--      viram chave estrangeira para ela — canal novo = 1 linha aqui, sem migration de constraint.
--  (2) Origem conhecida sempre: conversa sem marca no texto deixa de cair em 'direto'. Grava 'meta_ads' quando o referral do
--      anúncio (meta_referrals) chegou para o telefone nos últimos 10 min; senão 'desconhecida'. 'direto' fica para quem a
--      gente sabe que chegou sem link (correção do backoffice). meta_referral_gravar corrige a conversa quando o referral
--      chega DEPOIS da 1ª mensagem. Correção de quem já existia: 9 'direto' com referral → 'meta_ads'; o resto → 'desconhecida'.
--  (3) conversa_origem_corrigir: o backoffice corrige a origem (Configurações › Canais), com motivo e autor na trilha.
--  (4) canal_custo_dia (custo à mão: Google, TikTok, Kwai, SMS…) + v_canal_custo_dia (Meta lida de meta_ads_diario, sem redigitar).
--  (5) canais_resumo(dias) e v_canais_7d: por canal, conversas, qualificados, vendas (OS), instaladas, R$ gasto, custo por conversa,
--      por venda e por venda instalada, comissão prevista. Card "Canais · 7 dias" no Painel.
--  (6) conferencia_itens(): + origem desconhecida nas últimas 24 h (dono: backoffice) · + o card fecha com a v_margem_canal ·
--      + pedidos de indicação vencidos (só existe depois da 0303).
-- Regra 20: (1) nenhuma situação nova; o lead nasce como sempre, com vez e prazo · (2) "origem desconhecida" tem dono (backoffice)
-- e sai do Conferir quando a origem é corrigida · (3) origem não é estado; mesmo assim só muda pela função, com autor ·
-- (4) gasto = plataforma (Meta pelo meta_ads_diario; os outros à mão até ter importador), venda = vendas, conversa = NIOGEN ·
-- (5) dois itens novos na conferência. Regra 15: parceiro_id nas tabelas novas; canais em config. Tela Live: sem mudança.
begin;


-- ───────────────────────── 1. canais ─────────────────────────
create table if not exists public.config_canais (
  canal        text primary key check (canal ~ '^[a-z][a-z0-9_]*$'),
  nome         text not null,
  tipo         text not null check (tipo in ('midia_paga', 'organico', 'base_propria', 'indicacao', 'parceiro', 'outbound', 'sem_pista', 'interno')),
  ativo        boolean not null default false,       -- aparece no card do Painel
  subiu_em     date,                                 -- dia em que o canal entrou no ar (projeto 1 canal por dia)
  ordem        int not null default 100,
  nota         text,
  parceiro_id  text not null default 'dharma',
  criado_em    timestamptz not null default now()
);
comment on table public.config_canais is
  'Canais de captação (0302): a lista oficial de origens de conversa e de venda. Canal novo = 1 linha (ativo quando subir). '
  'tipo sem_pista = direto/desconhecida/outro; interno = teste.';

insert into public.config_canais (canal, nome, tipo, ativo, subiu_em, ordem, nota) values
  ('meta_ads',     'Meta Ads',                 'midia_paga',   true,  date '2026-11-05', 10, 'custo lido de meta_ads_diario'),
  ('instagram',    'Instagram (bio)',          'organico',     true,  date '2026-11-06', 20, 'link da bio termina em (IG)'),
  ('facebook',     'Página do Facebook',       'organico',     true,  date '2026-11-06', 21, 'botão da página termina em (FB)'),
  ('site',         'Site',                     'organico',     false, null,              22, null),
  ('fila_vero',    'Fila Vero',                'base_propria', true,  date '2026-11-16', 30, 'código (FV-…) na 1ª mensagem'),
  ('indicacao',    'Indicação',                'indicacao',    true,  date '2026-11-13', 40, '0176 e 0303'),
  ('parceiro_pap', 'Parceiro PAP',             'parceiro',     true,  null,              50, 'venda de parceiro (vendas.parceiro_id)'),
  ('rua',          'Rua (PAP)',                'outbound',     true,  null,              60, null),
  ('google_ads',   'Google Ads',               'midia_paga',   false, null,              11, 'custo à mão em Configurações › Canais'),
  ('tiktok_ads',   'TikTok Ads',               'midia_paga',   false, null,              12, 'custo à mão'),
  ('kwai_ads',     'Kwai Ads',                 'midia_paga',   false, null,              13, 'custo à mão'),
  ('gmn',          'Google Meu Negócio',       'organico',     false, null,              23, null),
  ('marketplace',  'Marketplace (Facebook)',   'organico',     false, null,              24, null),
  ('olx',          'OLX',                      'organico',     false, null,              25, null),
  ('lp_cidade',    'Página por cidade',        'organico',     false, null,              26, null),
  ('grupos_wpp',   'Grupos de WhatsApp',       'organico',     false, null,              27, null),
  ('sms',          'SMS',                      'outbound',     false, null,              61, 'custo à mão'),
  ('mdu',          'Condomínios (MDU)',        'outbound',     false, null,              62, null),
  ('sdr',          'SDR (ligação ativa)',      'outbound',     false, null,              63, null),
  ('influencer',   'Influenciador',            'parceiro',     false, null,              51, 'custo à mão'),
  ('direto',       'Direto (sem link)',        'sem_pista',    true,  null,              90, 'só quem a gente sabe que chegou sem link'),
  ('desconhecida', 'Origem desconhecida',      'sem_pista',    true,  date '2026-11-18', 91, '0302: sem marca e sem referral — o backoffice confere'),
  ('outro',        'Outro',                    'sem_pista',    true,  null,              92, 'venda de origem sem canal próprio'),
  ('teste',        'Teste',                    'interno',      false, null,              99, null)
on conflict (canal) do update set nome = excluded.nome, tipo = excluded.tipo, nota = excluded.nota, ordem = excluded.ordem;

alter table public.config_canais enable row level security;
drop policy if exists config_canais_ler on public.config_canais;
create policy config_canais_ler on public.config_canais for select to authenticated using (true);
revoke all on public.config_canais from anon, authenticated;
grant select on public.config_canais to authenticated;
grant all on public.config_canais to service_role;

-- as checagens fixas viram chave estrangeira (os valores de hoje estão todos na lista acima)
alter table public.mari_conversas drop constraint if exists mari_conversas_origem_check;
alter table public.mari_conversas alter column origem set default 'desconhecida';
alter table public.mari_conversas drop constraint if exists mari_conversas_origem_fk;
alter table public.mari_conversas add constraint mari_conversas_origem_fk foreign key (origem) references public.config_canais (canal) on update cascade;
alter table public.vendas drop constraint if exists vendas_origem_check;
alter table public.vendas drop constraint if exists vendas_origem_fk;
alter table public.vendas add constraint vendas_origem_fk foreign key (origem) references public.config_canais (canal) on update cascade;

-- ───────────────────────── 2. custo por canal e dia ─────────────────────────
create table if not exists public.canal_custo_dia (
  id              bigserial primary key,
  parceiro_id     text not null default 'dharma',
  canal           text not null references public.config_canais (canal) on update cascade check (canal <> 'meta_ads'),
  dia             date not null,
  valor           numeric(12, 2) not null check (valor >= 0),
  origem_do_dado  text not null default 'manual' check (origem_do_dado in ('manual', 'importado')),
  obs             text,
  gravado_por     uuid,
  gravado_em      timestamptz not null default now(),
  unique (parceiro_id, canal, dia)
);
comment on table public.canal_custo_dia is
  'Custo por canal e dia (0302) dos canais sem importador (Google, TikTok, Kwai, SMS…). Meta Ads NÃO entra aqui: vem de '
  'meta_ads_diario (uma fonte por fato). Escrita só por canal_custo_gravar().';
alter table public.canal_custo_dia enable row level security;
drop policy if exists canal_custo_dia_ler on public.canal_custo_dia;
create policy canal_custo_dia_ler on public.canal_custo_dia for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.canal_custo_dia from anon, authenticated;
grant select on public.canal_custo_dia to authenticated;
grant all on public.canal_custo_dia to service_role;

create or replace view public.v_canal_custo_dia with (security_invoker = true) as
select 'dharma'::text as parceiro_id, 'meta_ads'::text as canal, d.dia, round(sum(d.gasto), 2)::numeric(12, 2) as valor,
       'meta_ads_diario'::text as origem_do_dado
  from public.meta_ads_diario d group by d.dia
union all
select c.parceiro_id, c.canal, c.dia, c.valor, c.origem_do_dado from public.canal_custo_dia c;
revoke all on public.v_canal_custo_dia from anon, authenticated;
grant select on public.v_canal_custo_dia to authenticated, service_role;

create or replace function public.canal_custo_gravar(p_canal text, p_dia date, p_valor numeric, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  -- logado: só o admin (ou a chave de serviço); sem login (CLI do Claude Code) passa
  if coalesce(current_setting('request.jwt.claims', true), '') <> ''
     and coalesce((select public.meu_perfil()), '') <> 'admin'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'Só o admin grava custo de canal.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.config_canais where canal = p_canal) then raise exception 'Canal desconhecido: %', p_canal; end if;
  if p_canal = 'meta_ads' then raise exception 'O custo da Meta vem sozinho da coleta (meta_ads_diario): não digite.'; end if;
  if p_dia is null or p_dia > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Informe um dia até hoje.'; end if;
  if p_valor is null then
    delete from public.canal_custo_dia where parceiro_id = 'dharma' and canal = p_canal and dia = p_dia;
    return jsonb_build_object('ok', true, 'apagado', true);
  end if;
  if p_valor < 0 then raise exception 'O valor não pode ser negativo.'; end if;
  insert into public.canal_custo_dia (canal, dia, valor, obs, gravado_por)
  values (p_canal, p_dia, round(p_valor, 2), nullif(btrim(coalesce(p_obs, '')), ''), auth.uid())
  on conflict (parceiro_id, canal, dia) do update set valor = excluded.valor, obs = excluded.obs, gravado_por = excluded.gravado_por, gravado_em = now();
  return jsonb_build_object('ok', true, 'canal', p_canal, 'dia', p_dia, 'valor', round(p_valor, 2));
end $$;
revoke all on function public.canal_custo_gravar(text, date, numeric, text) from public, anon;
grant execute on function public.canal_custo_gravar(text, date, numeric, text) to authenticated, service_role;

-- ───────────────────────── 3. origem conhecida ─────────────────────────
-- Conversa sem marca no texto: o anúncio deixa o referral (meta_referrals) — se chegou para este telefone há pouco, é Meta Ads.
create or replace function public._origem_sem_marca(p_tel text)
returns text language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.meta_referrals r
                            where r.telefone = regexp_replace(coalesce(p_tel, ''), '\D', '', 'g') and r.ad_id is not null
                              and r.recebido_em > now() - interval '10 minutes')
              then 'meta_ads' else 'desconhecida' end
$$;
revoke all on function public._origem_sem_marca(text) from public, anon, authenticated;

-- O backoffice corrige a origem (perguntou ao cliente por onde chegou). Não é estado do lead, mas muda só por aqui, com autor.
create or replace function public.conversa_origem_corrigir(p_conversa uuid, p_origem text, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas; k public.config_canais; quem text;
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  select * into k from public.config_canais where canal = p_origem;
  if k.canal is null or k.tipo = 'interno' or k.canal in ('desconhecida', 'parceiro_pap') then
    raise exception 'Escolha o canal por onde o cliente chegou.';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if c.id is null then raise exception 'Conversa não encontrada.'; end if;
  if c.origem = p_origem then return jsonb_build_object('ok', true, 'igual', true); end if;
  quem := coalesce((select nullif(btrim(u.nome), '') from public.usuarios u where u.id = auth.uid()), 'sistema');
  update public.mari_conversas set origem = p_origem where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[origem corrigida de "' || coalesce(c.origem, '—') || '" para "' || k.nome || '" por ' || quem
          || coalesce(' — ' || nullif(btrim(coalesce(p_obs, '')), ''), '') || ']', false);
  -- a venda que nasceu desta conversa com origem genérica acompanha
  if c.venda_id is not null and p_origem not in ('direto') then
    update public.vendas set origem = p_origem where id = c.venda_id and coalesce(origem, 'outro') = 'outro';
  end if;
  return jsonb_build_object('ok', true, 'de', c.origem, 'para', p_origem);
end $$;
revoke all on function public.conversa_origem_corrigir(uuid, text, text) from public, anon;
grant execute on function public.conversa_origem_corrigir(uuid, text, text) to authenticated, service_role;


-- ───────────────────────── 4. o medidor ─────────────────────────
-- Por canal, numa janela de p_dias dias (hoje incluído, dia de São Paulo):
--   conversas = conversas de WhatsApp que nasceram na janela (sem teste) · qualificados = chegaram ao degrau "qualificada" ou além
--   (a mesma conta de _agente_trafego_base.qualificada_real) · vendas = vendas criadas na janela com o status de venda da
--   v_margem_canal · instaladas = vendas instaladas na janela · gasto = v_canal_custo_dia na janela.
create or replace function public.canais_resumo(p_dias int default 7)
returns table (canal text, nome text, tipo text, ativo boolean, ordem int, conversas int, qualificados int, vendas int, instaladas int,
               gasto numeric, custo_conversa numeric, custo_venda numeric, custo_venda_instalada numeric, comissao_prevista numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  v_de date := (now() at time zone 'America/Sao_Paulo')::date - (greatest(1, least(coalesce(p_dias, 7), 3650)) - 1);
  v_ts timestamptz := (v_de::timestamp at time zone 'America/Sao_Paulo');
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  return query
  with cv as (
    select c.origem, count(*)::int as n,
           count(*) filter (where c.funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')
                              and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'credito_negado', 'teste_duplicada'))::int as q
      from public.mari_conversas c
     where c.canal = 'whatsapp' and c.created_at >= v_ts
       and coalesce(c.funil_destino, '') <> 'teste_duplicada' and coalesce(c.telefone, '') not like '5500000000%'
     group by c.origem
  ), vd as (
    select v.origem,
           count(*) filter (where v.criado_em >= v_ts and v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'))::int as n,
           count(*) filter (where v.instalado_em >= v_ts and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme'))::int as inst,
           coalesce(sum(v.comissao_prevista) filter (where v.criado_em >= v_ts
                      and v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')), 0) as com
      from public.vendas v group by v.origem
  ), gs as (
    select x.canal, sum(x.valor) as g from public.v_canal_custo_dia x where x.dia >= v_de group by x.canal
  )
  select k.canal, k.nome, k.tipo, k.ativo, k.ordem,
         coalesce(cv.n, 0), coalesce(cv.q, 0), coalesce(vd.n, 0), coalesce(vd.inst, 0),
         gs.g, round(gs.g / nullif(cv.n, 0), 2), round(gs.g / nullif(vd.n, 0), 2), round(gs.g / nullif(vd.inst, 0), 2),
         coalesce(vd.com, 0)::numeric
    from public.config_canais k
    left join cv on cv.origem = k.canal
    left join vd on vd.origem = k.canal
    left join gs on gs.canal = k.canal
   where k.tipo <> 'interno'
   order by round(gs.g / nullif(vd.inst, 0), 2) nulls last, round(gs.g / nullif(vd.n, 0), 2) nulls last,
            round(gs.g / nullif(cv.n, 0), 2) nulls last, coalesce(cv.n, 0) desc, k.ordem;
end $$;
revoke all on function public.canais_resumo(int) from public, anon;
grant execute on function public.canais_resumo(int) to authenticated, service_role;

create or replace view public.v_canais_7d as select * from public.canais_resumo(7);
revoke all on public.v_canais_7d from anon, authenticated;
grant select on public.v_canais_7d to authenticated, service_role;

-- ───────────────────────── 5. funções que gravam a origem (definição atual da produção + a troca da 0302) ─────────────────────────

CREATE OR REPLACE FUNCTION public.mari_entrada__nucleo(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when exists (select 1 from public.config_canais k where k.canal = p_origem) then p_origem end;   -- 0302: lista em config_canais
  v_cw   text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_pos  boolean;
  v_opt  boolean;
  v_sil  boolean := false;   -- 0261: silenciada (cliente Nio)
  v_cob  boolean := false;   -- 0279: volta depois de Saída por falta de cobertura (a Mari não responde)
  v_g    uuid;   -- 0155: cliente pediu para parar (SAIR, PARAR…)
  v_posv boolean;   -- 0155: cliente já instalado → pós-venda, com o time
begin
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  -- 0155 (D2): quem saiu pelo fim da cadência (encerrado_ia) e volta a escrever reaproveita a mesma linha, no mesmo degrau.
  if not found then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'retomada', cadencia_passo = 'nenhum', cadencia_proximo_em = null,
           ciclo_anterior = jsonb_strip_nulls(jsonb_build_object('motivo', m.handoff_motivo, 'em', m.handoff_em, 'encerrado_em', now(),
                              'origem', 'cliente voltou depois do fim da cadência', 'venda_id', m.venda_id)),
           ciclos_encerrados = coalesce(m.ciclos_encerrados, 0) + 1,
           handoff_motivo = null, handoff_em = null, handoff_briefing = null, chatwoot_resolvida = false, processando_ate = null,
           chatwoot_conversation_id = coalesce(v_cw, m.chatwoot_conversation_id)
     where m.id = (select x.id from public.mari_conversas x
                    where x.telefone = v_tel and x.canal = p_canal and x.status = 'encerrado_ia'
                    order by x.updated_at desc limit 1)
    returning * into v_conv;
    if found then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (v_conv.id, 'sistema', '[cliente voltou depois do fim da cadência — a conversa segue de onde parou]', false);
    end if;
  end if;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else public._origem_sem_marca(v_tel) end),   -- 0302: nunca mais 'direto' por falta de marca
            p_chatwoot_conversation_id)
    returning * into v_conv;
  elsif v_conv.origem in ('direto', 'desconhecida') and v_orig is not null and v_orig not in ('direto', 'desconhecida', 'teste') then   -- 0302
    -- 0033: conversa que já existia sem origem conhecida ganha a 1ª origem identificada (link (IG)/(FB) ou anúncio).
    update public.mari_conversas set origem = v_orig where id = v_conv.id returning * into v_conv;
  end if;

  if v_conv.status = 'handoff_realizado' and p_canal = 'whatsapp' and v_cw is not null
        and v_conv.chatwoot_conversation_id is distinct from v_cw then
    perform public._mari_fechar_ciclo(v_conv.id, 'nova conversa no Chatwoot (' || v_cw || ')');
    update public.mari_conversas set chatwoot_conversation_id = v_cw
     where id = v_conv.id returning * into v_conv;
  end if;
  -- 0259 (A4, conferência da sombra): também com a conversa ATIVA (ex.: Saída "pode voltar", que fica ativa) — o cliente escreveu
  -- numa conversa nova do Chatwoot e o NIOGEN seguia mandando etiquetas, notas, mensagens e "resolver" na antiga, já resolvida.
  if p_canal = 'whatsapp' and v_cw is not null and v_conv.chatwoot_conversation_id is distinct from v_cw then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[o cliente escreveu numa conversa nova do Chatwoot (' || v_cw || ', antes ' || coalesce(v_conv.chatwoot_conversation_id, '—')
            || ') — o NIOGEN passa a usar a nova]', false);
    update public.mari_conversas set chatwoot_conversation_id = v_cw, chatwoot_status = 'open', chatwoot_agente = null, chatwoot_time = null,
           chatwoot_etiquetas = '{}'
     where id = v_conv.id returning * into v_conv;
  end if;

  -- 0167 (Ricardo, 13/11; conversa #86): a Mari avisou "sem cobertura" e convidou o cliente a mandar o CEP ou o número certo.
  -- Se ele volta a escrever e ninguém do time assumiu, a conversa reabre na etapa do endereço para a Mari conferir de novo —
  -- até 3 voltas por conversa. dados.sem_cobertura_avisado guarda a hora do veredito: enquanto o endereço for o mesmo, a Mari
  -- sabe que já avisou e não repete; endereço novo zera o veredito (gatilho da 0133) e a consulta sai de novo.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo = 'sem_cobertura' and v_conv.cobertura_decisao = 'sem_cobertura'
     and v_conv.cobertura_em is not null
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and coalesce(case when v_conv.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (v_conv.dados->>'sem_cobertura_voltas')::int end, 0) < 3
     and not public._mari_optout(p_texto)
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > v_conv.handoff_em) then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'endereco', handoff_motivo = null, handoff_em = null, handoff_briefing = null,
           chatwoot_resolvida = false,
           dados = coalesce(m.dados, '{}'::jsonb) || jsonb_build_object(
             'sem_cobertura_avisado', floor(extract(epoch from m.cobertura_em))::bigint,
             'sem_cobertura_voltas', coalesce(case when m.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (m.dados->>'sem_cobertura_voltas')::int end, 0) + 1)
     where m.id = v_conv.id
    returning * into v_conv;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[cliente voltou a escrever depois do aviso de sem cobertura — a Mari confere o endereço de novo]', false);
  end if;

  -- 0189 (Ricardo, 13/11; conversa #39, Waldir): saiu por recusa (ou por sem contato), clicou no anúncio de novo e a Mari
  -- ficou muda. Recusa não é pedido de parar: quem volta a escrever reabre na retomada, com a Mari. Não reabre se alguém do
  -- time é o dono, se o time falou nas últimas 12 h, se o cliente pediu para parar, nem na despedida logo depois da saída.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo in ('recusa_compra', 'sem_contato')
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and not public._mari_optout(p_texto)
     and coalesce(v_conv.handoff_em, '-infinity') < now() - interval '30 minutes'
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > now() - interval '12 hours') then
    perform public._mari_fechar_ciclo(v_conv.id, 'cliente voltou a escrever depois da saída');
    update public.mari_conversas set chatwoot_resolvida = false where id = v_conv.id returning * into v_conv;
  end if;

  -- 0265 (passo 5): a volta do cliente em Saída passa pela porta. "Pode voltar" (recusou, sem resposta…) e escreveu de verdade
  -- (não só "ok, obrigado") mais de 30 min depois da Saída → reabre onde parou, com a Mari. Definitiva, Não contatar e cliente
  -- Nio não reabrem (a tabela diz). Era o ramo "cliente voltou a escrever" do _funil_antes, que saiu.
  -- 0279 (caso Felix, 18/11): Saída dada pelo time por falta de cobertura (fachada ou cidade não atendida) NÃO reabre com a Mari —
  -- ela voltava sem saber o motivo e prometia instalação. O cliente recebe a verdade uma vez; se insistir, a conversa vai ao time.
  if coalesce(v_conv.saida_motivo, '') in ('fachada_nao_atendida', 'cidade_nao_atendida')
     and coalesce(v_conv.funil_destino, 'em_andamento') <> 'em_andamento'
     and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and public._porta_situacao(v_conv.id, null::uuid) = 'saida_pode_voltar' then
    v_cob := true;
    if p_midia is not null or not public._saida_so_confirmacao(p_texto) then
      perform public.porta('cliente_escreveu:sem_cobertura', v_conv.id, null::uuid, jsonb_build_object('texto', p_texto));
      select * into v_conv from public.mari_conversas where id = v_conv.id;
    end if;
  end if;

  if not v_cob and coalesce(v_conv.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')
     and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and (p_midia is not null or not public._saida_so_confirmacao(p_texto))
     and coalesce(v_conv.saida_em, v_conv.funil_destino_em, '-infinity') < now() - interval '30 minutes'   -- 0189: despedida não reabre
     and public._porta_situacao(v_conv.id, null::uuid) = 'saida_pode_voltar' then
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'reabrir'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;

  -- 0261 (Ricardo, 17/11: "Cliente já é Nio, em qualquer situação, educadamente a Mari encerra a conversa, pedindo para procurar os
  -- canais oficiais. Se depois de alguns minutos o cliente insistir, silencie a conversa. Somos uma revenda da Nio"): conversa em
  -- "já é cliente Nio" em que já houve a despedida (a própria Mari deu a Saída, ou falamos depois dela) e o cliente escreve de novo → silenciada.
  if coalesce(v_conv.funil_destino, '') = 'ja_cliente_nio' and coalesce(v_conv.quadro_encerrada_motivo, '') <> 'suporte_nio'
     and (v_conv.handoff_motivo = 'ja_cliente_nio' or v_conv.ciclo_anterior ->> 'motivo' = 'ja_cliente_nio'   -- a Mari se despediu ao dar a Saída
          or exists (select 1 from public.mari_turnos t where t.conversa_id = v_conv.id and t.papel in ('mari', 'humano')
                      and t.created_at > coalesce(v_conv.funil_destino_em, v_conv.handoff_em, v_conv.created_at))) then
    -- 0265: o silêncio é da porta (cliente_escreveu em "Cliente Nio")
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'silenciar'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;
  -- 0261: silenciada (cliente Nio) = a Mari não responde, e o time também não (situação 15: ninguém)
  v_sil := coalesce(v_conv.quadro_encerrada_motivo, '') = 'suporte_nio' or v_cob;

  v_pos := public._mari_pos_handoff(v_conv);

  -- 0250 (H2): Não contatar gravado no NIOGEN cala a Mari, mesmo que tirem a etiqueta à mão no Chatwoot
  v_opt  := public._mari_optout(p_texto) or coalesce(v_conv.nao_contatar, false);
  v_posv := coalesce(v_conv.funil_destino, '') = 'instalada';

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), (v_conv.status = 'ativo' or v_pos) and not v_opt and not v_posv and not v_sil, public._midia_ok(p_midia));

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), '')),
         -- 0155: a trava "resolvida" da cadência cai quando o cliente escreve e a conversa segue em andamento
         chatwoot_resolvida = case when coalesce(funil_destino, 'em_andamento') = 'em_andamento' then false else chatwoot_resolvida end
   where id = v_conv.id;

  if v_opt and not coalesce(v_conv.nao_contatar, false) then perform public.conversa_nao_contatar(v_conv.id, 'cliente escreveu: ' || left(btrim(coalesce(p_texto, '')), 40)); end if;
  if v_posv and not v_opt then perform public._mari_pos_venda(v_conv.id); end if;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', (v_conv.status <> 'ativo' and not v_pos) or v_opt or v_posv or v_sil,
    'optout', v_opt, 'pos_venda', v_posv,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_registrar_turno(p_telefone text, p_nome text, p_texto text, p_papel text, p_canal text DEFAULT 'whatsapp'::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_txt  text := btrim(coalesce(p_texto, ''));
  v_conv public.mari_conversas;
  v_link text;
  v_venda record;
  v_capt text;
begin
  if p_papel not in ('lead', 'humano') then
    raise exception 'papel inválido: % (use lead | humano)', p_papel using errcode = '22023';
  end if;
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;
  if v_txt = '' then
    return jsonb_build_object('ignorado', true, 'motivo', 'texto vazio');
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            case when p_canal = 'teste' then 'teste' else public._origem_sem_marca(v_tel) end, p_chatwoot_conversation_id)   -- 0302
    returning * into v_conv;
  end if;

  if p_papel = 'humano' then
    if exists (select 1 from public.mari_turnos
                where conversa_id = v_conv.id and papel = 'mari'
                  and (btrim(texto) = v_txt or position(v_txt in texto) > 0)
                  and created_at > now() - interval '10 minutes') then
      return jsonb_build_object('ignorado', true, 'motivo', 'eco da Mari', 'conversa_id', v_conv.id);
    end if;
    if exists (select 1 from public.mari_turnos
                where conversa_id = v_conv.id and papel = 'humano'
                  and btrim(texto) = v_txt and created_at > now() - interval '1 minute') then
      return jsonb_build_object('ignorado', true, 'motivo', 'repetido', 'conversa_id', v_conv.id);
    end if;
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, tags, midia)
  values (v_conv.id, p_papel, v_txt, false, jsonb_build_object('sem_resposta', true),
          case when p_papel = 'lead' then public._midia_ok(p_midia) end);

  if p_papel = 'lead' then
    update public.mari_conversas
       set ultima_msg_lead_at = now(),
           nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), ''))
     where id = v_conv.id;
  end if;

  -- 0027: link da biometria mandado pelo atendente → venda da conversa.
  if p_papel = 'humano' then
    v_link := substring(v_txt from '(https://ged360\.niointernet\.com\.br/brprontopdv/pdv-mobile/biometria/login/[A-Za-z0-9_-]+)');
    if v_link is not null then
      select v.id, v.status, v.biometria_status, v.biometria_link, v.nio_pedido into v_venda
        from public.vendas v where v.id = v_conv.venda_id for update;
      if not found then
        v_capt := 'conversa sem venda no NIOGEN';
      elsif v_venda.status <> '0_qualificado' or v_venda.biometria_status = 'validada' then
        v_capt := 'venda já passou da biometria';
      elsif v_venda.biometria_link is not distinct from v_link and v_venda.biometria_status in ('pendente', 'com_risco') then
        v_capt := 'mesmo link já registrado';
      elsif coalesce(btrim(v_venda.nio_pedido), '') <> '' then
        -- 0032: o pedido já definiu a biometria (pendente) e a contagem (hora do pedido). O link colado só fica
        -- guardado como referência, se a venda ainda não tiver um; nada mais muda.
        if v_venda.biometria_link is null then
          update public.vendas set biometria_link = v_link where id = v_venda.id;
          insert into public.eventos_venda (venda_id, tipo, detalhe)
          values (v_venda.id, 'biometria_link', jsonb_build_object(
            'origem', 'chatwoot', 'conversa_id', v_conv.id, 'so_referencia', true));
          v_capt := 'link guardado (o pedido já define a contagem)';
        else
          v_capt := 'pedido já registrado (link não muda a contagem)';
        end if;
      else
        -- 0032: fallback — sem nº do pedido no NIOGEN, o link colado ainda marca a biometria pendente e a contagem.
        update public.vendas
           set biometria_link = v_link,
               biometria_status = case when biometria_status = 'com_risco' then 'com_risco' else 'pendente' end,
               biometria_link_enviado_em = now()
         where id = v_venda.id;
        insert into public.eventos_venda (venda_id, tipo, detalhe)
        values (v_venda.id, 'biometria_link', jsonb_build_object(
          'origem', 'chatwoot', 'conversa_id', v_conv.id, 'reenvio', v_venda.biometria_link is not null));
        v_capt := case when v_venda.biometria_link is null then 'link registrado' else 'link trocado (reenvio)' end;
      end if;
    end if;
  end if;

  return jsonb_strip_nulls(jsonb_build_object('ignorado', false, 'conversa_id', v_conv.id, 'papel', p_papel,
                                              'biometria_link', v_capt));
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_handoff__nucleo(p_conversa uuid, p_motivo text, p_lead jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  l        jsonb := coalesce(p_lead, '{}'::jsonb);
  d        jsonb;
  v_plano  public.config_planos;
  v_venda  uuid;
  v_motivo text;
  v_seg    text;
  v_forma  text;
  v_orig   text;
  v_cpf    text;
  v_tel    text;
  v_cluster text;
  v_dfv    jsonb;
  v_brief  text;
  v_obs    text;
  v_inst   text;
  v_viab   text;
  v_vnota  text;
  v_prox   text;
  v_endp   text;
  v_exist  uuid;   -- 0030: venda que já existe (duplicidade) — o link vai na nota do Chatwoot
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'motivo_recusa', 'conversa inexistente'); end if;

  -- Guard-rail 10: não repetir handoff.
  if c.status <> 'ativo' then
    return jsonb_build_object('ok', true, 'repetido', true, 'venda_id', c.venda_id);
  end if;

  -- 0266 (C3, Ricardo 17/11): "interesse caindo" e "múltiplos decisores" não passam para o time — a conversa fica com a Mari
  -- (status ativo; a Mari segue respondendo). O 🔥 na Live fica para o debate da Live.
  if p_motivo in ('interesse_caindo', 'multiplos_decisores') then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[a Mari sinalizou ' || case p_motivo when 'interesse_caindo' then 'interesse caindo' else 'múltiplos decisores' end
            || ' — a conversa fica com ela (C3)]', false);
    return jsonb_build_object('ok', true, 'fica_com_mari', true, 'venda_id', c.venda_id);
  end if;

  d := c.dados || coalesce(l -> 'dados', '{}'::jsonb);
  v_inst := coalesce(nullif(btrim(c.instalacao_preferencia), ''), nullif(btrim(l ->> 'instalacao_preferencia'), ''));
  v_viab := coalesce(c.nio_viab_resultado, nullif(l ->> 'nio_viab_resultado', ''));
  if v_viab not in ('viavel', 'sem_viabilidade', 'nao_encontrado', 'posse', 'indisponivel') then v_viab := null; end if;
  v_endp := coalesce(nullif(btrim(c.nio_viab_endereco_portal), ''), nullif(btrim(l ->> 'nio_viab_endereco_portal'), ''));

  -- Nota da viabilidade oficial (nunca nega venda): viável = atendido; o resto = conferir à mão antes do pedido.
  v_vnota := case
    when v_viab = 'viavel' then 'portal: viável' || coalesce(' · até ' || coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'), '')
    when v_viab = 'posse' then 'portal: posse (endereço com Nio ativo) — cliente disse que não tem; conferir manualmente antes de abrir o pedido'
    when v_viab is not null then 'portal: ' || v_viab || ' — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido'
    else 'portal: não consultado — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido' end
    || coalesce(' · endereço como a Nio cadastrou: ' || v_endp, '');

  -- Próximo passo do humano (venda remota, 05/11; 0032: o link da biometria é da Nio): sempre o mesmo texto.
  v_prox := case when p_motivo = 'dados_completos' then
    'Próximo passo: abrir pedido no portal PAP'
    || case when coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') is not null
            then ' (interesse ' || coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') || ' já criado na viabilidade)' else '' end
    || ' e registrar o nº do pedido no NIOGEN → a Nio dispara o link da biometria (WhatsApp + e-mail) → avisar o cliente nesta conversa → agendar a instalação ('
    || coalesce(v_inst, 'preferência não informada') || ').' end;

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    handoff_briefing = concat_ws(E'\n', coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing),
                                 case when p_motivo = 'dados_completos' or v_viab is not null then v_vnota end, v_prox),
    dados = d, processando_ate = null,
    instalacao_preferencia = coalesce(v_inst, instalacao_preferencia),
    -- 0189: recusa não é pedido de parar — o "não contatar" fica só para quem pediu (SAIR, PARAR, botão do time)
    agendamento_retorno = coalesce((l ->> 'agendamento_retorno')::timestamptz, agendamento_retorno)
  where id = p_conversa
  returning * into c;
  -- 0290: motivo de Saída (fora de área, sem cobertura, recusou, já cliente Nio, sem contato) → a Saída é da porta
  perform public._porta_mari_destino(p_conversa, 'mari_handoff');
  select * into c from public.mari_conversas where id = p_conversa;

  if p_motivo <> 'dados_completos' then
    return jsonb_build_object('ok', true, 'venda_id', null);
  end if;

  -- Pré-condições da venda (ordem: elegibilidade, área, plano, dados mínimos, duplicidade). Viabilidade NÃO entra.
  v_cluster := public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> 'bairro');
  v_cpf := regexp_replace(coalesce(d ->> 'cpf', ''), '\D', '', 'g');
  v_tel := regexp_replace(coalesce(d ->> 'telefone', c.telefone), '\D', '', 'g');
  select * into v_plano from public.config_planos where codigo = c.plano_escolhido;

  -- 0030: a mesma regra de duplicidade de sempre, agora guardando QUAL venda já existe (a mais recente).
  select v.id into v_exist from public.vendas v
   where v.status <> 'saida'
     and ((v_cpf <> '' and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = v_cpf)
       or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = c.cep
           and lower(btrim(coalesce(v.numero, ''))) = lower(btrim(c.numero))
           and lower(btrim(coalesce(v.complemento, ''))) = lower(btrim(coalesce(c.complemento, '')))))
   order by v.criado_em desc
   limit 1;

  v_motivo := case
    when coalesce(c.elegibilidade, '') <> 'ok' then 'elegibilidade não confirmada (' || coalesce(c.elegibilidade, 'vazia') || ')'
    when v_cluster is null then 'fora da área de atuação (' || coalesce(c.cidade, 'cidade desconhecida') || ')'
    when v_plano.id is null then 'plano não escolhido'
    when coalesce(btrim(d ->> 'nome'), '') = '' then 'nome do cliente ausente'
    when c.cep is null or c.numero is null then 'endereço incompleto'
    when v_exist is not null
      then 'duplicidade: CPF ou endereço já tem venda ativa no NIOGEN'
  end;

  if v_motivo is null then
    v_seg := case when c.segmento = 'empresas' then case when c.mei then 'MEI' else 'NMEI' end else 'PF' end;
    v_forma := coalesce(c.forma_pagamento, l ->> 'forma_pagamento');
    v_forma := case v_forma when 'debito' then 'dacc' when 'debito_automatico' then 'dacc' else v_forma end;
    if v_forma not in ('boleto', 'cartao', 'dacc') then v_forma := null; end if;
    v_orig := case when c.origem not in ('direto', 'desconhecida', 'teste', 'parceiro_pap', 'outro')
                     and exists (select 1 from public.config_canais k where k.canal = c.origem) then c.origem else 'outro' end;   -- 0302: canal novo vai para a venda
    v_dfv := c.dfv_detalhe;

    v_brief := coalesce(l ->> 'briefing', '');
    v_obs := concat_ws(E'\n',
      'Mari (' || c.canal || ') — handoff dados_completos em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
      'Plano: ' || v_plano.nome || ' · forma: ' || coalesce(v_forma, '?'),
      'Instalação: preferência ' || coalesce(v_inst, '?') || ' (data o nosso time confirma)',
      'Viabilidade Nio — ' || v_vnota,
      'DFV: ' || case coalesce(c.dfv_resultado, '')
                   when 'viavel' then 'viável'
                   when 'viavel_predio' then 'viável (prédio) — conferir unidade'
                   when 'endereco_ocupado' then 'indica Nio ativo no endereço — confirmar com o cliente e no portal antes de abrir o pedido'
                   else 'conferir manualmente antes de abrir o pedido' end,
      nullif(v_brief, ''),
      v_prox);

    begin
      insert into public.vendas (
        status, origem, origem_ref, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
        cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento,
        trava_area, trava_cpf_valido, trava_contato_confirmado, observacoes,
        dfv_viabilidade, dfv_resultado, dfv_hp_livre, dfv_hcs, dfv_faixa_credito, dfv_classificacao,
        dfv_particao, dfv_origem, dfv_consultado_em,
        instalacao_preferencia, biometria_status,
        nio_viab_resultado, nio_viab_velocidade, nio_viab_interesse_id, nio_viab_em, nio_viab_origem, nio_viab_endereco_portal)
      values (
        '0_qualificado', v_orig, 'mari:' || c.id, btrim(d ->> 'nome'), nullif(v_cpf, ''), v_tel, nullif(btrim(d ->> 'email'), ''), v_seg,
        c.cep, c.endereco_cep ->> 'logradouro', c.numero, c.complemento,
        coalesce(c.endereco_cep ->> 'bairro', v_dfv ->> 'bairro'), c.cidade, c.uf, v_plano.id, v_forma,
        true, case when v_cpf <> '' then public.mari_cpf_valido(v_cpf) end,
        case when coalesce((d ->> 'telefone_confirmado')::boolean, false) or v_tel <> '' then true end, v_obs,
        case c.dfv_resultado
          when 'viavel' then 'viavel' when 'viavel_predio' then 'viavel_predio'
          when 'endereco_ocupado' then 'sem_viabilidade' when 'sem_porta_livre' then 'sem_viabilidade'
          when 'nao_encontrado' then 'nao_encontrado'
          else 'nao_consultado' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then c.dfv_resultado end,
        (v_dfv ->> 'hp_livre')::int, (v_dfv ->> 'hc_tot')::int,
        public.dfv_faixa_codigo(v_dfv ->> 'faixa_credito'),
        case when v_dfv ->> 'classificacao' in ('ALTO', 'MEDIO', 'BAIXO') then v_dfv ->> 'classificacao' end,
        (v_dfv ->> 'particao')::date,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then 'auto' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then now() end,
        v_inst, 'nao_enviada',
        v_viab, coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'),
        coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id'),
        case when v_viab is not null then coalesce(c.nio_viab_em, now()) end,
        case when v_viab is not null then 'mari' end,
        v_endp)
      returning id into v_venda;

      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v_venda, 'mari_handoff', jsonb_strip_nulls(jsonb_build_object(
        'conversa_id', c.id, 'motivo', p_motivo, 'canal', c.canal, 'briefing', nullif(v_brief, ''),
        'instalacao_preferencia', v_inst, 'nio_viab_resultado', v_viab, 'dfv_resultado', c.dfv_resultado)));

      update public.mari_conversas set venda_id = v_venda where id = p_conversa;
    exception when others then
      v_motivo := sqlerrm;
    end;
  end if;

  if v_motivo is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_handoff', 'venda não criada: ' || v_motivo,
            jsonb_strip_nulls(jsonb_build_object('lead', l, 'dados', d, 'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end)));
    return jsonb_build_object('ok', false, 'venda_id', null, 'motivo_recusa', v_motivo,
                              'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end);
  end if;

  return jsonb_build_object('ok', true, 'venda_id', v_venda);
end;
$function$;

CREATE OR REPLACE FUNCTION public._fila_vero_origem()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cod text; v public.fila_vero%rowtype; v_tel text;
begin
  begin   -- nunca derruba a gravação do turno da Mari
    v_cod := lower(substring(new.texto from '\(FV-[A-Za-z0-9]+-([a-z0-9]{6,12})\)'));
    if v_cod is not null then
      select * into v from public.fila_vero where codigo = v_cod;
    end if;
    if v.id is null and new.texto ~ '\(FV-' then
      select telefone into v_tel from public.mari_conversas where id = new.conversa_id;
      select * into v from public.fila_vero where id = public._fila_vero_por_wa(null, v_tel);
    end if;
    if v.id is null then return null; end if;
    update public.mari_conversas set origem = 'fila_vero'
     where id = new.conversa_id and coalesce(origem, 'direto') in ('direto', 'desconhecida');   -- 0302
    update public.fila_vero set conversa_id = coalesce(conversa_id, new.conversa_id),
                                respondeu_em = coalesce(respondeu_em, now()),
                                clicou_em = coalesce(clicou_em, now())
     where id = v.id;
    if v.status in ('apto', 'enviado', 'erro', 'encerrado') then
      perform set_config('niogen.fila_vero_porta', 'on', true);
      perform set_config('niogen.fila_vero_motivo', 'falou com a Mari (código ' || coalesce(v_cod, 'FV') || ')', true);
      perform set_config('niogen.fila_vero_autor', 'mari_turnos', true);
      update public.fila_vero set status = 'respondeu' where id = v.id;
      perform set_config('niogen.fila_vero_porta', 'off', true);
    end if;
  exception when others then
    raise warning 'fila_vero_origem: %', sqlerrm;
  end;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.mari_turnos_pos_instalacao()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg   jsonb;
  c     public.mari_conversas;
  p     public.pos_instalacao;
  i     public.indicacoes;
  t     text;
  tels  jsonb;
  e     jsonb;
  v_nome text;
  v_ok  int := 0;
  v_ja  int := 0;
  v_nomes text[] := '{}';
  v_reclama boolean;
  v_nega    boolean;
  v_sim     boolean;
  v_tratou  boolean := false;
  v_ddd text;
begin
  if new.papel <> 'lead' then return new; end if;
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is null then return new; end if;

  -- (0) o indicado respondeu por uma conversa diferente da que abrimos (telefone com/sem o 9): a indicação acompanha a conversa viva
  if coalesce(c.funil_destino, '') <> 'instalada' then
    select * into i from public.indicacoes x
     where x.tel_chave = public._tel_chave(c.telefone) and x.estado in ('recebida', 'contatada') and x.conversa_id is distinct from c.id
     limit 1;
    if i.id is not null then
      update public.indicacoes set conversa_id = c.id, estado = 'contatada', contatada_em = coalesce(contatada_em, now()) where id = i.id;
      update public.mari_conversas set origem = 'indicacao' where id = c.id and origem in ('direto', 'desconhecida');   -- 0302
      update public.mari_conversas m set status = 'encerrado_humano'
       where m.id = i.conversa_id and m.status in ('ativo', 'handoff_realizado')
         and not exists (select 1 from public.mari_turnos tt where tt.conversa_id = m.id and tt.papel = 'lead');
    end if;
    return new;
  end if;

  -- (1) cliente instalado respondendo ao pós-instalação
  select * into p from public.pos_instalacao x where x.conversa_id = c.id and x.estado in ('enviada', 'pediu')
   order by x.criado_em desc limit 1 for update;
  if p.id is null then return new; end if;
  -- 0226 (M4): uma pessoa/o time atendendo o cliente instalado → as respostas automáticas da indicação não saem
  if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then return new; end if;
  cfg := public._ind_cfg();
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return new; end if;

  t := public._ind_norm(new.texto);
  v_reclama := t ~ coalesce(cfg ->> 're_reclama',
    '(problema|ruim|pessim|horrivel|lent[ao]|caindo|caiu|cai toda|sem sinal|sem internet|nao funciona|nao esta funcionando|travando|oscila|reclam|cancel|demor|errad|insatisf|decep|arrepend|defeito|quebr|fatura|boleto|cobranca|procon|anatel|tecnico nao|nao veio|nao instal)');
  v_nega := t ~ coalesce(cfg ->> 're_nega', '(^| )(nao|nem|mais ou menos|pouco|nada)( |$)');
  v_sim := length(t) <= 80 and t ~ coalesce(cfg ->> 're_sim',
    '^(sim|s|ss|ok|blz|top|show|super|beleza|certinho|excelente)( |$)|^(tudo certo|deu tudo certo|deu certo|tudo otimo|tudo ok|tudo bem|tudo perfeito|tudo joia|tudo show|tudo certinho|otim[oa]|perfeit[oa]|maravilh|muito bo[am]|mto bo[am]|bom demais|gostei|adorei|amei|funcionando|esta otim|ta otim|satisfeit|foi sim|deu sim|com certeza)');
  c.ultima_msg_lead_at := now();   -- a mari_entrada só grava isto depois: a fala que chegou agora abre a janela de 24 h

  if p.estado = 'enviada' then
    if v_reclama or v_nega then
      update public.pos_instalacao set estado = 'insatisfeito', respondeu_em = now(), resposta = left(new.texto, 300), encerrada_em = now() where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'pos_instalacao', p.venda_id, c, 'indicacao_problema', '{}'::jsonb);
      -- não marca "tratado": o pós-venda de sempre (etiqueta, nota e linha no Live) chama o time
    elsif v_sim then
      update public.pos_instalacao set estado = 'pediu', respondeu_em = now(), pediu_em = now(), resposta = left(new.texto, 300) where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_pedido', p.venda_id, c, 'indicacao_pedido', '{}'::jsonb);
      v_tratou := true;
    else
      update public.pos_instalacao set estado = 'com_time', respondeu_em = now(), resposta = left(new.texto, 300), encerrada_em = now() where id = p.id;
    end if;

  else   -- 'pediu': esperando o contato
    v_ddd := substr(public._tel_chave(c.telefone), 1, 2);
    tels := public._ind_telefones(new.texto, v_ddd);
    if jsonb_array_length(tels) > 0 then
      v_nome := case when jsonb_array_length(tels) = 1 then public._ind_nome(new.texto) end;
      for e in select * from jsonb_array_elements(tels) loop
        if (e ->> 'chave') = public._tel_chave(c.telefone)
           or exists (select 1 from public.indicacoes x where x.tel_chave = e ->> 'chave' and x.estado <> 'invalida')
           or exists (select 1 from public.vendas v where public._tel_chave(v.cliente_whatsapp) = e ->> 'chave') then
          v_ja := v_ja + 1;
          continue;
        end if;
        insert into public.indicacoes (pos_instalacao_id, indicador_venda_id, indicador_conversa_id, indicado_nome, indicado_telefone,
                                       tel_chave, texto_original, conversa_id, estado, contatada_em, motivo)
        select p.id, p.venda_id, c.id, v_nome, e ->> 'tel', e ->> 'chave', left(new.texto, 500), m.id,
               case when m.id is null then 'recebida' else 'contatada' end, case when m.id is null then null else now() end,
               case when m.id is null then null else 'já estava em atendimento com a Mari' end
          from (select 1) z
          left join lateral (select mc.id from public.mari_conversas mc
                              where public._tel_chave(mc.telefone) = e ->> 'chave' and mc.canal = 'whatsapp'
                                and mc.status in ('ativo', 'handoff_realizado') limit 1) m on true;
        v_ok := v_ok + 1;
        v_nomes := v_nomes || coalesce(public._ind_primeiro_nome(v_nome), 'a pessoa');
      end loop;
      if v_ok > 0 then
        perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', p.venda_id, c, 'indicacao_obrigado',
                                    jsonb_build_object('nome', case when v_ok = 1 then v_nomes[1] else 'cada uma dessas pessoas' end));
      else
        perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', p.venda_id, c, 'indicacao_ja', '{}'::jsonb);
      end if;
      update public.pos_instalacao set resposta = left(new.texto, 300) where id = p.id;
      v_tratou := true;
    elsif v_reclama or new.midia is not null then
      update public.pos_instalacao set estado = 'com_time', encerrada_em = now(), resposta = left(new.texto, 300) where id = p.id;
    elsif p.insistencias = 0 then
      update public.pos_instalacao set insistencias = 1, insistiu_em = now() where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
      v_tratou := true;
    else
      update public.pos_instalacao set estado = 'encerrada', encerrada_em = now() where id = p.id;
      v_tratou := true;   -- já insistimos uma vez e o cliente não tem quem indicar: encerra sem chamar o time
    end if;
  end if;

  if v_tratou then
    update public.pos_instalacao set tratado_em = now() where id = p.id;
    update public.mari_conversas set dispensada_em = now() where id = c.id;   -- a linha "pós-venda" do Live não acende
  end if;
  return new;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.conversa_id, 'mari_turnos_pos_instalacao', sqlerrm);
  return new;   -- nunca derruba a gravação da fala do cliente
end $function$;

CREATE OR REPLACE FUNCTION public.meta_referral_gravar(p_value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_n int := 0;
  v_msgs int := 0;
begin
  if jsonb_typeof(coalesce(p_value, '{}'::jsonb)) <> 'object' then
    raise exception 'p_value precisa ser o objeto "value" do webhook' using errcode = '22023';
  end if;
  v_msgs := coalesce(jsonb_array_length(p_value -> 'messages'), 0);

  insert into public.meta_referrals
    (wamid, telefone, phone_number_id, ad_id, source_type, ctwa_clid, source_url, titulo, recebido_em)
  select m ->> 'id', regexp_replace(m ->> 'from', '\D', '', 'g'), p_value -> 'metadata' ->> 'phone_number_id',
         case when m -> 'referral' ->> 'source_type' = 'ad' then m -> 'referral' ->> 'source_id' end,
         m -> 'referral' ->> 'source_type', m -> 'referral' ->> 'ctwa_clid', m -> 'referral' ->> 'source_url',
         left(m -> 'referral' ->> 'headline', 200), to_timestamp((m ->> 'timestamp')::bigint)
    from jsonb_array_elements(coalesce(p_value -> 'messages', '[]'::jsonb)) m
   where m ? 'referral' and m ->> 'id' is not null and m ->> 'from' is not null and m ->> 'timestamp' ~ '^\d+$'
  on conflict (wamid) do nothing;
  get diagnostics v_n = row_count;

  -- 0302: o referral chegou depois da 1ª mensagem → a conversa recém-aberta sem marca é do anúncio
  update public.mari_conversas c set origem = 'meta_ads'
    from public.meta_referrals r
   where r.wamid in (select m ->> 'id' from jsonb_array_elements(coalesce(p_value -> 'messages', '[]'::jsonb)) m)
     and r.ad_id is not null and c.telefone = r.telefone and c.origem in ('direto', 'desconhecida')
     and c.created_at between r.recebido_em - interval '10 minutes' and r.recebido_em + interval '10 minutes';

  return jsonb_build_object('ok', true, 'mensagens', v_msgs, 'referrals', v_n);
end $function$;

-- conferência: definição atual + itens 22, 23 e 24

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


  -- 14. 0202 — conferir a rua: o portal consultou outra rua e ninguém conferiu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where rua_conferir_em is not null and rua_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_rua', 'nome', 'Rua conferida em até 4 h quando o portal consulta outra rua',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma conferência de rua parada há mais de 4 h' else format('%s conversa(s) com a rua por conferir há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Portal: outra rua": refazer na Cobertura escolhendo a rua do cliente e marcar "Conferi".' end);

  -- 15. 0202 — a DFV ao vivo sai pela API do Power BI (o operador da VPS é só reserva)
  select count(*), count(*) filter (where coalesce(detalhe ->> 'fonte', '') <> 'api') into n, n2
    from public.operador_consultas where tipo = 'dfv'
     and criado_em > greatest(now() - interval '24 hours', timestamptz '2026-11-14 20:10-03');   -- API no ar desde 14/11 20h10
  it := it || jsonb_build_object('codigo', 'dfv_pela_api', 'nome', 'DFV consultada pela API do Power BI',
    'nivel', case when n = 0 or n2 * 100 <= n * 5 then 'ok' else 'atencao' end, 'n', n2,
    'texto', case when n = 0 then 'nenhuma consulta DFV nas últimas 24 h' else format('%s de %s consulta(s) DFV nas últimas 24 h fora da API', n2, n) end,
    'fazer', case when n = 0 or n2 * 100 <= n * 5 then null else 'A Nio pode ter republicado o relatório (chave/modelId mudaram): avisar o Claude Code — config_regras.dfv_api.' end);

  -- 16. 0218 — ninguém parado em silêncio: vez da Mari, conversa ativa, sem próximo toque e sem prazo
  select count(*), string_agg(coalesce(nullif(btrim(l.nome), ''), 'sem nome'), ', ' order by l.ultima_em desc) into n, ex
    from public._lead_em_silencio() s join public.v_leads l on l.conversa_id = s.conversa_id;
  it := it || jsonb_build_object('codigo', 'lead_em_silencio', 'nome', 'Ninguém parado em silêncio (vez da Mari sem próximo toque)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todo lead com a vez da Mari tem o próximo toque marcado ou um prazo'
                  else format('%s lead(s) com a vez da Mari, sem próximo toque e sem prazo: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir na Live e dar saída, esquentar (🔥) ou assumir. Se a cadência deveria ter marcado o próximo toque, avisar o Claude Code.' end);

  -- 17. 0228 (revisão dos fluxos) — Saída com dono: lead em Saída cuja conversa segue aberta com pessoa ou time no Chatwoot
  -- há mais de 1 h (a Saída devolve para a Mari na hora; "já é cliente Nio" e "não contatar" ficam de fora).
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and (v.status = 'saida' or (c.venda_id is null and c.saida_em is not null and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')))
     and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente') and not coalesce(c.nao_contatar, false)
     and c.chatwoot_status in ('open', 'pending') and (c.chatwoot_agente is not null or c.chatwoot_time is not null)
     and coalesce(c.saida_em, c.funil_destino_em, c.created_at) < now() - interval '1 hour';
  it := it || jsonb_build_object('codigo', 'saida_com_dono', 'nome', 'Lead em Saída sem dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead em Saída com a conversa aberta e com dono' else format('%s lead(s) em Saída ainda com pessoa ou time no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha: se o cliente ainda quer seguir, Reabrir; senão "Devolver para a Mari". Se voltar a acontecer, avisar o Claude Code.' end);

  -- 18. 0228 — mensagem automática com a conversa assumida por uma pessoa (pela fila do NIOGEN, na voz da Mari, ou a Mari
  -- respondendo o cliente), nas últimas 24 h. "Assumida" = a última ação de pessoa feita pelo NIOGEN foi atribuir.
  select count(*), string_agg(distinct nome, ', ') into n, ex from (
    select c.nome_contato as nome from public.chatwoot_acoes a join public.mari_conversas c on c.id = a.conversa_id
     where a.tipo = 'mensagem' and a.status = 'feita' and a.criada_em > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')
       and coalesce(a.payload ->> 'como', '') <> 'humano' and coalesce(c.telefone, '') not like '5500000000%'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < a.criada_em order by b.criada_em desc limit 1) = 'atribuir'
    union all
    select c.nome_contato from public.mari_turnos t join public.mari_conversas c on c.id = t.conversa_id
     where t.papel = 'mari' and t.created_at > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')   -- correções no ar desde 15/11 ~20h and coalesce(c.telefone, '') not like '5500000000%'
       and (select p.papel from public.mari_turnos p where p.conversa_id = t.conversa_id and p.papel <> 'sistema' and p.created_at < t.created_at
              order by p.created_at desc limit 1) = 'lead'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = t.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < t.created_at order by b.criada_em desc limit 1) = 'atribuir') x;
  it := it || jsonb_build_object('codigo', 'msg_auto_assumida', 'nome', 'Nada automático fala por cima de quem assumiu',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma mensagem automática com a conversa assumida nas últimas 24 h' else format('%s mensagem(ns) automática(s) com a conversa assumida: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code (guard da Mari ou botão sem o "em nome da pessoa"). Ver a conversa e, se precisar, corrigir com o cliente.' end);

  -- 19. 0228 — o banco diz "pessoa/time atribuído" e o Chatwoot diz sem dono (a 0227 espelha; isto acha o que escapar)
  select count(*), string_agg(coalesce(c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' and c.chatwoot_sync_em < now() - interval '10 minutes'
     and ((c.humano_atribuido and c.chatwoot_agente is null) or (c.time_atribuido and c.chatwoot_time is null and c.chatwoot_agente is null))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir' and a.status in ('pendente', 'executando'));
  it := it || jsonb_build_object('codigo', 'dono_banco_chatwoot', 'nome', 'Dono no NIOGEN = dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todo dono no banco também está no Chatwoot' else format('%s conversa(s) com dono no banco e sem dono no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o espelho do Chatwoot (0227) deixou passar. Enquanto isso a cadência dessas conversas fica parada.' end);

  -- 20. 0233 — unidade a confirmar: a unidade do cliente não está na lista da Nio e ninguém resolveu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where unidade_conferir_em is not null and unidade_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_unidade', 'nome', 'Unidade confirmada em até 4 h quando não bate com a lista da Nio',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma unidade por confirmar há mais de 4 h' else format('%s conversa(s) com a unidade por confirmar há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Unidade a confirmar": confirmar a unidade com o cliente ou pedir o cadastro à Nio e marcar "Conferi".' end);

  -- 21. 0239 — Fila Vero (módulo desligável): a conta da fila fecha
  if to_regclass('public.fila_vero') is not null then
    select count(*) into v_tot from public.fila_vero;
    select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.fila_vero group by status) x;
    select count(*) into n from public.fila_vero
     where (status in ('ja_cliente_nio') and toques > 0)
        or (status = 'opt_out' and ultimo_toque_em > (select max(e.em) from public.fila_vero_eventos e
                                                       where e.fila_id = fila_vero.id and e.para = 'opt_out'));
    select count(*) into n2 from public.fila_vero
     where status = 'enviado' and coalesce(meta_status, 'accepted') = 'accepted' and ultimo_toque_em < now() - interval '24 hours';
    it := it || jsonb_build_object('codigo', 'fila_vero', 'nome', 'Fila Vero: soma por status = total · nenhum toque proibido · status da Meta em 24 h',
      'nivel', case when v_tot <> v_soma or n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', (v_tot - v_soma) + n + n2,
      'texto', format('%s na fila (status somam %s) · %s toque(s) em já cliente/opt-out · %s enviado(s) sem status da Meta há mais de 24 h',
                      v_tot, v_soma, n, n2),
      'fazer', case when v_tot <> v_soma or n > 0 then 'Avisar o Claude Code: a fila da Vero tocou quem não podia ou perdeu linha.'
                    when n2 > 0 then 'Conferir o webhook do número do disparo (n8n fila_vero_webhook).' else null end);
    -- 0242: cota do dia e apto parado com o disparo ligado
    select count(*) into n from public.contatos_cliente where toque = 'fila_vero' and direcao = 'saida'
       and (em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
    n2 := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'fila_vero_ritmo_dia'), 100);
    it := it || jsonb_build_object('codigo', 'fila_vero_cota', 'nome', 'Fila Vero: envios de hoje dentro do ritmo do dia',
      'nivel', case when n <= n2 then 'ok' else 'falha' end, 'n', greatest(0, n - n2),
      'texto', format('%s envio(s) hoje · ritmo %s/dia', n, n2),
      'fazer', case when n <= n2 then null else 'Pausar a Fila Vero na tela e avisar o Claude Code.' end);
    select count(*) into n from public.fila_vero where status = 'apto' and atualizado_em < now() - interval '7 days'
       and coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'fila_vero_ativo'), false);
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_apto_parado', 'nome', 'Fila Vero: apto parado há mais de 7 dias com o disparo ligado',
        'nivel', 'atencao', 'n', n, 'texto', format('%s apto(s) esperando há mais de 7 dias', n),
        'fazer', 'Ver na tela Fila Vero se o ritmo está baixo ou se a faixa B está fora do disparo.');
    end if;
    select count(*) into n from public.fila_vero where status = 'respondeu' and conversa_id is null;
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_sem_conversa', 'nome', 'Fila Vero: quem respondeu tem conversa na Mari',
        'nivel', 'falha', 'n', n, 'texto', format('%s resposta(s) sem conversa ligada', n),
        'fazer', 'Avisar o Claude Code (gatilho mari_turnos_fila_vero).');
    end if;
  end if;


  -- 22. 0302 — origem conhecida: lead das últimas 24 h com a origem desconhecida (dono: backoffice; sai quando a origem é corrigida)
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ' order by c.created_at desc) into n, ex
    from public.mari_conversas c
   where c.origem = 'desconhecida' and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and coalesce(c.funil_destino, '') <> 'teste_duplicada' and c.created_at > now() - interval '24 hours';
  it := it || jsonb_build_object('codigo', 'origem_desconhecida', 'nome', 'Todo lead novo tem a origem conhecida (últimas 24 h)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead das últimas 24 h com a origem desconhecida'
                  else format('%s lead(s) das últimas 24 h sem origem: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Backoffice: perguntar ao cliente por onde chegou e corrigir em Configurações › Canais › Origem a conferir.' end);

  -- 23. 0302 — o card "Canais" fecha com a v_margem_canal (vendas por origem, desde sempre)
  select count(*), string_agg(format('%s: card %s × margem %s', coalesce(m.origem, '(sem origem)'), coalesce(r.vendas, 0), m.vendas), ' · ') into n, ex
    from public.v_margem_canal m
    left join public.canais_resumo(3650) r on r.canal = m.origem
   where coalesce(r.vendas, 0) <> m.vendas;
  it := it || jsonb_build_object('codigo', 'canais_conta', 'nome', 'Card Canais = v_margem_canal (vendas por origem)',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'as vendas por canal do card batem com a margem por canal' else left(ex, 200) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o card Canais e a v_margem_canal contam diferente (é defeito).' end);

  -- 24. 0303 — pedido de indicação: nenhum aberto além da validade (a rotina indicacao_rotina fecha)
  if to_regclass('public.indicacao_pedidos') is not null then
    select count(*) into n from public.indicacao_pedidos where estado = 'pediu' and pedido_em < now() - interval '8 days';
    select count(*) into n2 from public.indicacao_pedidos where pedido_em > now() - interval '7 days';
    select count(*) into v_tot from public.indicacoes where criado_em > now() - interval '7 days' and estado <> 'invalida';
    it := it || jsonb_build_object('codigo', 'indicacao_pedidos', 'nome', 'Pedido de indicação: nenhum aberto além da validade',
      'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
      'texto', format('%s pedido(s) de indicação em 7 dias · %s indicação(ões) recebida(s) · %s aberto(s) além da validade', n2, v_tot, n),
      'fazer', case when n = 0 then null else 'Avisar o Claude Code: a rotina indicacao_rotina não fechou os pedidos vencidos.' end);
  end if;

  return it;
end;
$function$;


-- ───────────────────────── 6. quem já existia ─────────────────────────
-- 'direto' de antes = "sem marca no texto", não "sem link". Com referral do anúncio no mesmo minuto → Meta Ads; o resto → desconhecida.
update public.mari_conversas c set origem = 'meta_ads'
 where c.origem = 'direto'
   and exists (select 1 from public.meta_referrals r
                where r.telefone = c.telefone and r.ad_id is not null
                  and r.recebido_em between c.created_at - interval '10 minutes' and c.created_at + interval '10 minutes');
update public.mari_conversas set origem = 'desconhecida' where origem = 'direto';

commit;
