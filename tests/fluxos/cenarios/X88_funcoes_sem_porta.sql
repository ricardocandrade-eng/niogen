-- id: X88
-- titulo: 0362 (pendências da 0361, 23/11): login sem perfil e quem nem logou não gravam por função interna, não ligam a Fila Vero, não pedem auditoria e não leem a contagem de contatos; o time, o serviço e as duas funções públicas de propósito seguem funcionando; a conferência acusa se alguma voltar a abrir
-- tipo: atual
select sim.como('servico');
-- O portão roda como superusuário; as portas que olham session_user (_os_pode_gravar, fila_vero_ligar) só valem entrando como a
-- API entra: authenticator + o papel. Por isso cada bloco abaixo faz "set session authorization authenticator; set role …".
grant authenticated, anon, service_role to authenticator;
select sim.lead_novo('Ana X88') as a \gset
select sim.venda_pronta('Beto X88', true) as b \gset
select sim.venda(:'b') as vb \gset
update public.config_regras set valor = 'false'::jsonb where chave = 'fila_vero_ativo';

-- as chamadas que NÃO podem passar para quem não é do time
create temp table _cham (n int, o_que text, sql text);
insert into _cham values
  (1, '_fv_cfg_set',          $$select public._fv_cfg_set('fila_vero_ativo', 'true'::jsonb)$$),
  (2, '_fv_cfg',              $$select public._fv_cfg('fila_vero_ativo')$$),
  (3, '_lead_estado_marcar',  format($$select public._lead_estado_marcar(%L::uuid, null::uuid, 'prova', 'x88')$$, :'a')),
  (4, '_lead_estado_tick',    $$select public._lead_estado_tick(now())$$),
  (5, '_lead_estado_gravar',  format($$select public._lead_estado_gravar(%L::uuid, null::uuid, 'prova', 'x88')$$, :'a')),
  (6, '_porta_anotar',        format($$select public._porta_anotar('prova', 'x88', %L::uuid, null::uuid, 'x', '{}'::jsonb)$$, :'a')),
  (7, 'fila_vero_ligar',      $$select public.fila_vero_ligar(true, 'x88')$$),
  (8, 'auditoria_mari_pedir', $$select public.auditoria_mari_pedir(null::uuid)$$);
create temp table _x (quem text, o_que text, r text);
grant all on _cham, _x to authenticated, anon, service_role;
-- devolve 'ACEITOU' ou o código + a frase da recusa
create or replace function pg_temp.tenta(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql; return 'ACEITOU';
exception when others then return sqlstate || ' ' || sqlerrm;
end $$;

-- o que o dono da visão conta (referência para o time)
select count(*) as ref_n, coalesce(sum(hoje), 0) as ref_hoje, coalesce(sum(mes), 0) as ref_mes from public.v_contatos_limite \gset
select count(*) as sombra_antes from public.porta_sombra where origem = 'x88' or evento = 'prova' \gset
select count(*) as mud_antes from public.lead_estado_mudancas where origem = 'x88' \gset
select count(*) as aud_antes from public.auditoria_mari \gset

-- 1) login SEM perfil (usuário desativado): papel authenticated de verdade
select sim.como('vendedor');
set session authorization authenticator;
set role authenticated;
insert into _x select 'sem perfil', o_que, pg_temp.tenta(sql) from _cham order by n;
select public.meu_perfil() is null as sp_sem_perfil, public.nio_portal_sessao_status() is null as sp_portal_nulo,
       (select count(*) from public.v_contatos_limite) as sp_limite \gset
reset role;
reset session authorization;

-- 2) a agência (para tudo o que já existia é um login sem perfil)
select sim.como('servico');
update public.usuarios set perfil = 'agencia', ativo = true
 where id = (select id from public.usuarios where perfil = 'vendedor' and not ativo order by id desc limit 1);
select sim.como('agencia');
set session authorization authenticator;
set role authenticated;
insert into _x select 'agencia', o_que, pg_temp.tenta(sql) from _cham order by n;
select (select count(*) from public.v_contatos_limite) as ag_limite, public.nio_portal_sessao_status() is null as ag_portal_nulo \gset
reset role;
reset session authorization;

-- 3) quem nem logou (papel anon)
select set_config('request.jwt.claims', '{"role":"anon"}', false);
set session authorization authenticator;
set role anon;
insert into _x select 'anon', o_que, pg_temp.tenta(sql) from _cham order by n;
-- as duas públicas de propósito continuam atendendo sem login
select pg_temp.tenta($$select public.fila_vero_clique('x88abc', 'nio_fv_a1')$$) as anon_clique,
       pg_temp.tenta($$select public.parceiro_cadastrar('', '', '', '', '')$$) as anon_cadastro \gset
reset role;
reset session authorization;

select sim.como('servico');
select sim.confere('o login de teste não tem perfil', :'sp_sem_perfil'::boolean, 'tem perfil');
select sim.confere('login sem perfil: as 8 chamadas são recusadas com 42501 (sem permissão)',
  (select count(*) from _x where quem = 'sem perfil' and r like '42501%') = 8,
  (select string_agg(o_que || ': ' || left(r, 60), ' · ') from _x where quem = 'sem perfil' and r not like '42501%'));
select sim.confere('agência: as 8 chamadas são recusadas com 42501',
  (select count(*) from _x where quem = 'agencia' and r like '42501%') = 8,
  (select string_agg(o_que || ': ' || left(r, 60), ' · ') from _x where quem = 'agencia' and r not like '42501%'));
select sim.confere('sem login (anon): as 8 chamadas são recusadas com 42501',
  (select count(*) from _x where quem = 'anon' and r like '42501%') = 8,
  (select string_agg(o_que || ': ' || left(r, 60), ' · ') from _x where quem = 'anon' and r not like '42501%'));
select sim.confere('nada foi gravado pelas tentativas: Fila Vero segue desligada, nenhuma linha no diário da porta, nenhuma mudança de situação, nenhuma auditoria pedida',
  (select valor from public.config_regras where chave = 'fila_vero_ativo') = 'false'::jsonb
    and (select count(*) from public.porta_sombra where origem = 'x88' or evento = 'prova') = :sombra_antes
    and (select count(*) from public.lead_estado_mudancas where origem = 'x88') = :mud_antes
    and (select count(*) from public.auditoria_mari) = :aud_antes,
  'algo foi gravado');
select sim.confere('login sem perfil e agência não leem a contagem de contatos (v_contatos_limite) nem o estado da sessão do portal',
  :sp_limite = 0 and :ag_limite = 0 and :'sp_portal_nulo'::boolean and :'ag_portal_nulo'::boolean, :'sp_limite' || ' / ' || :'ag_limite');
select sim.confere('públicas de propósito seguem atendendo sem login: o clique do link da Fila Vero é aceito e o cadastro do Pocket chega à validação',
  :'anon_clique' = 'ACEITOU' and :'anon_cadastro' like 'P0001%nome completo%', :'anon_clique' || ' / ' || :'anon_cadastro');

-- 4) o time continua trabalhando, com o papel authenticated de verdade (as funções internas rodam por dentro, como dona)
select count(*) as sombra_a from public.porta_sombra where conversa_id = :'a' \gset
select count(*) as mud_a from public.lead_estado_mudancas where conversa_id = :'a' \gset
select sim.como('backoffice');
set session authorization authenticator;
set role authenticated;
select pg_temp.tenta(format($$select public.lead_sair(%L::uuid, null, 'recusou', 'preco')$$, :'a')) as bo_sair,
       pg_temp.tenta(format($$update public.vendas set ponto_referencia = 'x88' where id = %L::uuid$$, :'vb')) as bo_venda,
       pg_temp.tenta($$select public.fila_vero_ligar(true, 'x88')$$) as bo_ligar \gset
select count(*) as bo_n, coalesce(sum(hoje), 0) as bo_hoje, coalesce(sum(mes), 0) as bo_mes from public.v_contatos_limite \gset
select public.nio_portal_sessao_status() is not null as bo_portal \gset
reset role;
reset session authorization;
select sim.como('admin');
set session authorization authenticator;
set role authenticated;
select pg_temp.tenta($$select public.fila_vero_ligar(true, 'x88')$$) as ad_ligar \gset
select (select valor from public.config_regras where chave = 'fila_vero_ativo') = 'true'::jsonb as ad_ligou \gset
select pg_temp.tenta($$select public.fila_vero_ligar(false, 'x88')$$) as ad_pausar,
       pg_temp.tenta($$select public.auditoria_mari_pedir(null::uuid)$$) as ad_auditoria \gset
select count(*) as ad_n, coalesce(sum(mes), 0) as ad_mes from public.v_contatos_limite \gset
reset role;
reset session authorization;
-- o serviço (n8n) segue executando as internas
select sim.como('servico');
set session authorization authenticator;
set role service_role;
select pg_temp.tenta($$select public._lead_estado_tick(now())$$) as sv_tick, pg_temp.tenta($$select public._fv_cfg('fila_vero_ativo')$$) as sv_cfg,
       pg_temp.tenta(format($$select public._porta_anotar('prova', 'x88', %L::uuid, null::uuid, 'x', '{}'::jsonb)$$, :'a')) as sv_anotar \gset
reset role;
reset session authorization;

select sim.como('servico');
select sim.confere('backoffice (papel authenticated): dá Saída no lead — a situação é regravada e o diário da porta anota, pelas funções internas',
  :'bo_sair' = 'ACEITOU'
    and (select count(*) from public.porta_sombra where conversa_id = :'a') > :sombra_a
    and (select count(*) from public.lead_estado_mudancas where conversa_id = :'a') > :mud_a,
  :'bo_sair');
select sim.confere('backoffice (papel authenticated): grava direto na venda sem erro (o gatilho marca a situação por dentro)',
  :'bo_venda' = 'ACEITOU' and (select ponto_referencia from public.vendas where id = :'vb') = 'x88', :'bo_venda');
select sim.confere('backoffice lê a contagem de contatos igual ao dono da visão (mesmas linhas, mesmo hoje, mesmo mês)',
  :bo_n = :ref_n and :bo_hoje = :ref_hoje and :bo_mes = :ref_mes and :bo_n > 0, :'bo_n' || '/' || :'bo_hoje' || '/' || :'bo_mes' || ' × ' || :'ref_n' || '/' || :'ref_hoje' || '/' || :'ref_mes');
select sim.confere('backoffice vê o estado da sessão do portal; ligar a Fila Vero continua só do admin',
  :'bo_portal'::boolean and :'bo_ligar' like '42501%', :'bo_ligar');
select sim.confere('admin liga e pausa a Fila Vero, pede auditoria e lê a contagem de contatos',
  :'ad_ligar' = 'ACEITOU' and :'ad_ligou'::boolean and :'ad_pausar' = 'ACEITOU' and :'ad_auditoria' = 'ACEITOU' and :ad_n = :ref_n and :ad_mes = :ref_mes
    and (select valor from public.config_regras where chave = 'fila_vero_ativo') = 'false'::jsonb,
  :'ad_ligar' || ' / ' || :'ad_pausar' || ' / ' || :'ad_auditoria');
select sim.confere('o serviço (n8n) segue executando as funções internas', :'sv_tick' = 'ACEITOU' and :'sv_cfg' = 'ACEITOU' and :'sv_anotar' = 'ACEITOU',
  :'sv_tick' || ' / ' || :'sv_cfg' || ' / ' || :'sv_anotar');

-- 5) a conta fecha todo dia: limpo agora; afrouxou, acusa
select sim.confere('conferência: nenhuma função que grava está aberta a qualquer login', public.agencia_leituras_indevidas() = '[]'::jsonb, public.agencia_leituras_indevidas()::text);
create function public.x88_grava() returns void language sql security definer set search_path = public as
$$ update public.config_regras set atualizado_em = now() where chave = 'x88' $$;
create function public.x88_nulo() returns void language plpgsql security definer set search_path = public as $$
begin
  if public.meu_perfil() not in ('admin') then raise exception 'não' using errcode = '42501'; end if;
  update public.config_regras set atualizado_em = now() where chave = 'x88';
end $$;
select sim.confere('conferência: função nova que grava sem porta, e porta que não segura perfil nulo, são acusadas (e o item fica vermelho)',
  public.agencia_leituras_indevidas()::text like '%x88_grava grava%' and public.agencia_leituras_indevidas()::text like '%x88_nulo compara%'
    and jsonb_array_length(public.agencia_leituras_indevidas()) = 2
    and (select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'agencia_leitura') = 'falha',
  public.agencia_leituras_indevidas()::text);
drop function public.x88_grava();
drop function public.x88_nulo();
select sim.confere('conferência: tirou as duas, volta a ficar verde',
  (select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'agencia_leitura') = 'ok', 'vermelho');
