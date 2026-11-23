-- NIOGEN | supabase/migrations/0362_funcoes_sem_porta.sql | 23/11/2026 — Claude Code (Fable 5.2)
-- Pendências (b) e (c) da linha do Diário de 23/11 ~00h45 (perfil agencia, 0361): funções SECURITY DEFINER que gravam, são
-- executáveis por qualquer login (papel authenticated; algumas até sem login, papel anon) e não conferem o perfil.
-- Achado antigo, não veio da 0361. "Login sem perfil" = parceiro do Pocket, usuário desativado, agência.
--
-- Conferido uma a uma na cópia local em 23/11, chamando como login sem perfil e como anon (transação desfeita). A lista de
-- 12 era heurística; o resultado:
--   JÁ BARRAVAM (a porta está um nível abaixo; nada muda aqui):
--     backoffice_responder_citando → backoffice_responder__nucleo · lead_volta_adiar, mari_soprar, retomada_ligacao,
--     venda_janela → as peças _porta_* da porta · parceiro_enviar_venda, parceiro_reenviar_venda → parceiro_ativo_ou_erro().
--   PÚBLICAS DE PROPÓSITO (nada muda aqui):
--     fila_vero_clique (o link do template abre fv.html sem login; só marca o clique pelo código da linha) ·
--     parceiro_cadastrar (cadastro do Pocket, sem login; limite de tentativas por IP e por CPF).
--   ABERTAS DE VERDADE — FECHADAS AQUI (funções internas, só chamadas por outras funções do banco):
--     _fv_cfg_set       qualquer login regravava QUALQUER linha de config_regras
--     _lead_estado_marcar, _lead_estado_tick   qualquer um, até sem login, enfileirava regravação de situação
--   ACHADAS NA VARREDURA REFEITA (fora da lista de 12) — FECHADAS AQUI:
--     _lead_estado_gravar   sem login: regravava a situação de um lead e anotava mudança com evento inventado
--     _porta_anotar         sem login: escrevia linha no diário da porta (porta_sombra)
--     _fv_cfg               sem login: LIA qualquer linha de config_regras
--     fila_vero_ligar       a porta comparava meu_perfil() = 'admin' sem tratar nulo: para login SEM perfil a conta dava
--                           nulo e a recusa não disparava — qualquer login sem perfil ligava ou pausava a Fila Vero
--     auditoria_mari_pedir  o mesmo defeito (meu_perfil() not in (…) com perfil nulo): login sem perfil pedia auditoria
--     nio_portal_sessao_status   o mesmo defeito, em leitura: mostrava o estado da sessão do portal (não o token)
--   VISÃO v_contatos_limite: roda como dona e devolvia id de venda + contagem de contatos a qualquer login. Trocar para
--     security_invoker mudaria o número do backoffice (2 contatos casados só pelo telefone somem pelo RLS), então ela
--     continua como dona e ganha o filtro: time e serviço veem tudo, vendedor só as suas, o resto nada.
--
-- Como fecha: as internas perdem o EXECUTE de public, anon e authenticated (ficam postgres e service_role). Todas as que as
-- chamam são SECURITY DEFINER (rodam como dona), menos mari_entrada e mari_handoff, que só o service_role executa. Nenhuma
-- tela, visão ou policy as chama. As três portas furadas passam a tratar o perfil nulo. Nenhuma casca da porta em sombra é
-- tocada (regra de ouro 9).
--
-- Regra 15: nenhuma tabela. Regra 19: sem impacto (a visão ganha um filtro constante; medido 6,9 ms → ver Diário).
-- Regra 20: (1)(2)(3)(4) nenhum estado, tela ou fonte muda · (5) a conferência `agencia_leitura` passa a acusar também
-- função que grava sem porta e porta que não segura perfil nulo (agencia_leituras_indevidas()).
-- Cenário X88.
begin;

-- ───────────── 1. funções internas: só o banco e o serviço executam ─────────────
revoke all on function public._fv_cfg_set(text, jsonb)                          from public, anon, authenticated;
revoke all on function public._fv_cfg(text)                                     from public, anon, authenticated;
revoke all on function public._lead_estado_marcar(uuid, uuid, text, text)       from public, anon, authenticated;
revoke all on function public._lead_estado_tick(timestamptz)                    from public, anon, authenticated;
revoke all on function public._lead_estado_gravar(uuid, uuid, text, text)       from public, anon, authenticated;
revoke all on function public._porta_anotar(text, text, uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public._fv_cfg_set(text, jsonb), public._fv_cfg(text),
  public._lead_estado_marcar(uuid, uuid, text, text), public._lead_estado_tick(timestamptz),
  public._lead_estado_gravar(uuid, uuid, text, text), public._porta_anotar(text, text, uuid, uuid, text, jsonb) to service_role;

-- ───────────── 2. portas que não seguravam perfil nulo ─────────────
-- As três são a da produção em 23/11 com UMA troca: coalesce(meu_perfil(), '') na comparação.
create or replace function public.fila_vero_ligar(p_ligar boolean, p_motivo text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_autor text;
begin
  if not (coalesce(public.meu_perfil(), '') = 'admin' or session_user <> 'authenticator'
          or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role') then
    raise exception 'Só admin liga ou pausa a Fila Vero.' using errcode = '42501';
  end if;
  v_autor := coalesce((select nome from public.usuarios where id = auth.uid()), 'sistema');
  perform public._fv_cfg_set('fila_vero_ativo', to_jsonb(p_ligar));
  perform public._fv_cfg_set('fila_vero_ativo_hist',
    (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (
       select x, o from (
         select jsonb_build_object('ativo', p_ligar, 'por', v_autor, 'em', now(), 'motivo', coalesce(p_motivo, case when p_ligar then 'ligado' else 'pausado' end)) x, 0::bigint o
         union all
         select e.x, e.o from jsonb_array_elements(coalesce(public._fv_cfg('fila_vero_ativo_hist'), '[]'::jsonb)) with ordinality e(x, o)) u
       order by o limit 30) h));
  return jsonb_build_object('ativo', p_ligar);
end $function$;

create or replace function public.auditoria_mari_pedir(p_conversa uuid default null::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id bigint; v_hoje int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'auditoria_mari_pedir: só admin e backoffice' using errcode = '42501';
  end if;
  select id into v_id from public.auditoria_mari
   where status in ('pedido', 'rodando') and conversa_id is not distinct from p_conversa order by pedido_em limit 1;
  if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'ja_havia', true); end if;
  select count(*) into v_hoje from public.auditoria_mari where modo = 'pedido' and pedido_em > now() - interval '24 hours';
  if v_hoje >= 20 then
    return jsonb_build_object('ok', false, 'motivo', 'limite de 20 auditorias pedidas em 24 h');
  end if;
  insert into public.auditoria_mari (modo, conversa_id, pedido_por, janela_de, janela_ate)
  values ('pedido', p_conversa, auth.uid(),
          case when p_conversa is null then now() - interval '24 hours' else now() - interval '7 days' end, now())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'ja_havia', false);
end $function$;

create or replace function public.nio_portal_sessao_status()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select case
    when coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then null
    else coalesce((
      select jsonb_build_object(
        'obtido_em', s.obtido_em,
        'expira_estimado', s.expira_estimado,
        'ultimo_uso', s.ultimo_uso,
        'ultimo_erro', s.ultimo_erro,
        'ultimo_erro_em', s.ultimo_erro_em,
        'ok', s.obtido_em is not null and coalesce(s.expira_estimado, now()) > now()
              and (s.ultimo_erro_em is null or s.ultimo_erro_em < s.obtido_em),
        'sem_sessao_desde', case
          when s.ultimo_erro_em is not null and (s.obtido_em is null or s.ultimo_erro_em >= s.obtido_em)
            then coalesce(least(s.expira_estimado, s.ultimo_erro_em), s.ultimo_erro_em)
          when s.expira_estimado is not null and s.expira_estimado <= now() then s.expira_estimado end)
      from public.nio_portal_sessao s where s.id = 1), jsonb_build_object('ok', false, 'nunca', true))
  end
$function$;

-- ───────────── 3. v_contatos_limite: a mesma conta, só para quem pode ver a venda ─────────────
create or replace view public.v_contatos_limite as
 select v.id as venda_id,
    count(c.id) filter (where (c.em at time zone 'America/Sao_Paulo'::text)::date = (now() at time zone 'America/Sao_Paulo'::text)::date)::integer as hoje,
    count(c.id) filter (where date_trunc('month'::text, (c.em at time zone 'America/Sao_Paulo'::text)) = date_trunc('month'::text, (now() at time zone 'America/Sao_Paulo'::text)))::integer as mes
   from public.vendas v
     left join public.contatos_cliente c on c.direcao = 'saida'::text and coalesce(c.tipo, 'ativo'::text) <> 'receptivo'::text
       and (c.venda_id = v.id or c.telefone is not null and c.telefone = public.tel_norm(v.cliente_whatsapp))
  where (select public._os_pode_gravar())
     or ((select public.meu_perfil()) = 'vendedor' and (v.vendedor_id = (select auth.uid()) or v.criado_por = (select auth.uid())))
  group by v.id;

-- ───────────── 4. a conta fecha todo dia: a conferência acusa se alguma voltar a abrir ─────────────
-- A da 0361 com dois blocos novos no fim (função que grava sem porta · porta que não segura perfil nulo).
create or replace function public.agencia_leituras_indevidas()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  achados text[] := '{}';
  tabelas_ok text[] := array['usuarios', 'meta_ads_diario', 'meta_ads_anuncios', 'meta_ads_conjuntos', 'meta_ads_posicionamento_diario',
                             'config_meta_ads_regras', 'config_metas', 'config_area', 'dfv_bairros_pronto'];
  visoes_ok text[] := array['v_jornada', 'v_canais_7d', 'v_contatos_limite'];   -- conferidas em 22/11 (v_contatos_limite filtrada na 0362)
  funcoes_ok text[] := array['sou_agencia', 'meta_ads_dia', 'meta_ads_resultado', 'meta_ads_motivos_saida', 'placar_conversas_dia',
                             'placar_agencia', 'tabela_agencia', 'painel_meta_ritmo', 'agencia_leituras_indevidas'];
  -- 0362: o que conta como porta no corpo de uma função, e as conferidas à mão em 23/11 que não têm porta no próprio corpo
  porta_re text := '(meu_perfil|_os_pode_gravar|auth\.role\(\)|parceiro_atual|parceiro_ativo_ou_erro|sou_agencia|session_user|request\.jwt\.claims|_pendencia_pode)';
  gravam_ok text[] := array[
    'fila_vero_clique',               -- pública de propósito: o link do template (fv.html), só marca o clique pelo código
    'parceiro_cadastrar',             -- pública de propósito: cadastro do Pocket, com limite de tentativas
    'app_sessao_registrar',           -- só grava a sessão do próprio login
    'backoffice_responder_citando',   -- a porta está no backoffice_responder__nucleo
    '_cutucada', '_os_agenda_aviso']; -- só leem (o filtro pega a atribuição ":= public.")
  r record;
begin
  if not public._os_pode_gravar() then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if (select p.prosrc from pg_proc p where p.oid = 'public.meu_perfil()'::regprocedure) !~ 'perfil\s*<>\s*''agencia''' then
    achados := achados || 'meu_perfil() voltou a devolver o perfil agencia'::text;
  end if;
  for r in
    select p.schemaname, p.tablename, p.policyname, p.cmd from pg_policies p
     where (coalesce(p.qual, '') ~ 'sou_agencia' or coalesce(p.with_check, '') ~ 'sou_agencia')
       and (p.cmd <> 'SELECT' or p.schemaname <> 'public' or p.tablename <> all (tabelas_ok))
  loop
    achados := achados || format('policy %s em %s.%s (%s) libera a agência fora da lista', r.policyname, r.schemaname, r.tablename, r.cmd);
  end loop;
  for r in
    select p.tablename, p.policyname from pg_policies p
     where p.schemaname = 'public' and p.permissive = 'PERMISSIVE' and p.cmd in ('SELECT', 'ALL')
       and p.roles && array['authenticated', 'public']::name[]
       and coalesce(p.qual, 'true') !~ '(meu_perfil|sou_agencia|parceiro_atual|usuario_id|perfil\s*=|EXISTS)'
       and exists (select 1 from information_schema.columns c
                    where c.table_schema = 'public' and c.table_name = p.tablename
                      and c.column_name ~ '(telefone|whatsapp|cpf|cnpj|email|^cep$|logradouro|endereco|cliente|nome_contato|conversa_id|venda_id|lead_id|payload|markdown)')
  loop
    achados := achados || format('tabela %s (policy %s) tem dado de cliente e é lida por qualquer login', r.tablename, r.policyname);
  end loop;
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       and not coalesce(c.reloptions::text, '') ~ 'security_invoker=(true|on)'
       and has_table_privilege('authenticated', c.oid, 'select')
       and c.relname <> all (visoes_ok)
  loop
    achados := achados || format('visão %s roda como dona (sem security_invoker): conferir o que ela mostra', r.relname);
  end loop;
  for r in
    select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosrc ~ 'sou_agencia' and p.proname <> all (funcoes_ok)
       and p.proname not in ('conferencia_itens')
  loop
    achados := achados || format('função %s atende a agência e não foi conferida', r.proname);
  end loop;
  -- 0362: função definer que grava (ou chama outra), executável por qualquer login ou sem login, sem porta no corpo.
  -- Não conta: casca da porta em sombra cujo __nucleo tem porta, casca que entrega à porta() (as peças _porta_* conferem o
  -- perfil) e as conferidas à mão (gravam_ok). Função interna nova: tire o EXECUTE de public, anon e authenticated.
  for r in
    select p.proname from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosecdef and p.prorettype <> 'trigger'::regtype
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))
       and p.prosrc ~* '(insert\s+into|update\s+(public\.)?[a-z_]+\s+set|delete\s+from|perform\s|net\.http_post|:=\s*public\.)'
       and p.prosrc !~* porta_re
       and p.prosrc !~ 'public\.porta\('
       and not exists (select 1 from pg_proc k where k.pronamespace = p.pronamespace and k.proname = p.proname || '__nucleo'
                          and p.prosrc ~ (p.proname || '__nucleo') and k.prosrc ~* porta_re)
       and p.proname <> all (gravam_ok)
     order by p.proname
  loop
    achados := achados || format('função %s grava, qualquer login executa e não tem porta de perfil', r.proname);
  end loop;
  -- 0362: porta que compara meu_perfil() sem tratar nulo — para login sem perfil a conta dá nulo e a recusa não dispara.
  for r in
    select p.proname from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname <> 'agencia_leituras_indevidas'
       and p.prosrc ~* '(meu_perfil\(\)\)?\s*(not\s+in|<>|!=)|not\s*\(\s*(public\.)?meu_perfil\(\)\s*=)'
     order by p.proname
  loop
    achados := achados || format('função %s compara meu_perfil() sem tratar perfil nulo (use coalesce): login sem perfil passa', r.proname);
  end loop;
  return to_jsonb(achados);
end $$;
revoke all on function public.agencia_leituras_indevidas() from public, anon;
grant execute on function public.agencia_leituras_indevidas() to authenticated;

commit;
