-- id: X87
-- titulo: 0361 (prompt perfil agencia, 22/11): a agência só lê Meta Ads, Placar e Tabela, em contagens — nenhuma conversa, venda, lead, comissão nem saldo; quem já lia continua lendo; o número da agência é o mesmo do admin; a conferência acusa se alguém afrouxar
-- tipo: atual
select sim.como('servico');
select sim.lead_novo('Ana X87') as a \gset
update public.mari_conversas set origem = 'meta_ads' where id = :'a';
select sim.venda_pronta('Beto X87', true) as b \gset
update public.usuarios set perfil = 'agencia', ativo = true
 where id = (select id from public.usuarios where perfil = 'vendedor' and not ativo order by id limit 1);

-- o que cada papel LÊ de verdade: conta as linhas com o RLS valendo (papel authenticated); negado ou inexistente = -1
create temp table _alvo (r text primary key);
insert into _alvo values ('mari_conversas'), ('mari_turnos'), ('vendas'), ('v_leads'), ('v_vendas'), ('v_conversas'), ('v_jornada'),
  ('nio_biometria'), ('fila_vero'), ('indicacoes'), ('contatos_cliente'), ('eventos_venda'), ('push_subscriptions'), ('parceiros'),
  ('balanco_diario'), ('config_links'), ('config_regras'), ('meta_ads_conta_saldo'), ('config_planos'), ('config_adicionais'),
  ('config_bonus'), ('nio_hp'), ('importacoes'), ('conteudos'), ('projetor_sombra'), ('porta_sombra'), ('lead_estado'),
  ('lead_estado_mudancas'), ('meta_eventos'), ('mari_portao_rodadas'), ('pulso_batimentos'), ('meta_referrals'), ('os_andamento'),
  ('meta_ads_diario'), ('meta_ads_anuncios'), ('meta_ads_conjuntos'), ('meta_ads_posicionamento_diario'), ('config_meta_ads_regras'),
  ('config_metas'), ('config_area'), ('dfv_bairros_pronto'), ('usuarios');
create temp table _leu (quem text, r text, n bigint);
grant all on _alvo, _leu to authenticated;
create or replace function pg_temp.ler(p_quem text) returns void language plpgsql as $$
declare a record; q bigint;
begin
  for a in select r from _alvo loop
    begin
      execute format('select count(*) from public.%I', a.r) into q;
    exception when others then q := -1;
    end;
    insert into _leu values (p_quem, a.r, q);
  end loop;
end $$;

select sim.como('agencia');
set role authenticated;
select pg_temp.ler('agencia');
select public.meu_perfil() is null as ag_sem_perfil, public.sou_agencia() as ag_sou \gset
select (select count(*) from public.conversas_lista()) + (select count(*) from public.leads_lista()) + (select count(*) from public.jornada_live()) as ag_listas \gset
select public.meta_ads_resultado() as ag_res, public.placar_agencia()::text as ag_placar, public.tabela_agencia()::text as ag_tabela,
       public.meta_ads_motivos_saida(null, null) as ag_motivos, public.painel_meta_ritmo() is not null as ag_ritmo \gset
select (select jsonb_agg(to_jsonb(x) order by x.dia) from public.meta_ads_dia() x) as ag_dia,
       (select jsonb_agg(to_jsonb(x) order by x.dia) from public.placar_conversas_dia('2026-01-01') x) as ag_conv \gset
-- tentar gravar: nada pode passar
with u as (update public.usuarios set perfil = 'admin' where true returning 1) select count(*) as ag_virou_admin from u \gset
with u as (update public.meta_ads_diario set gasto = 0 where true returning 1) select count(*) as ag_gravou_meta from u \gset
reset role;

select sim.como('backoffice');
set role authenticated;
select pg_temp.ler('backoffice');
select public.meu_perfil() as bo_perfil \gset
reset role;

select sim.como('admin');
set role authenticated;
select public.meta_ads_resultado() as ad_res, public.meta_ads_motivos_saida(null, null) as ad_motivos \gset
select (select jsonb_agg(to_jsonb(x) order by x.dia) from public.meta_ads_dia() x) as ad_dia,
       (select jsonb_agg(to_jsonb(x) order by x.dia) from public.placar_conversas_dia('2026-01-01') x) as ad_conv \gset
reset role;

select sim.como('servico');
select sim.confere('para tudo o que já existia, a agência não tem perfil (meu_perfil() nulo) e sou_agencia() é verdadeiro',
  :'ag_sem_perfil'::boolean and :'ag_sou'::boolean, 'meu_perfil devolveu perfil');
select sim.confere('agência NÃO lê conversa, fala, venda, lead, biometria, Fila Vero, indicação, contato, parceiro, balanço, links, regras, saldo, planos/bônus (comissão), HP, guia nem as tabelas de sombra',
  not exists (select 1 from _leu where quem = 'agencia' and n > 0 and r not in
    ('meta_ads_diario', 'meta_ads_anuncios', 'meta_ads_conjuntos', 'meta_ads_posicionamento_diario', 'config_meta_ads_regras',
     'config_metas', 'config_area', 'dfv_bairros_pronto', 'usuarios')),
  (select string_agg(r || '=' || n, ', ') from _leu where quem = 'agencia' and n > 0));
select sim.confere('agência lê o que é dela: a campanha na Meta, a meta do mês e só a PRÓPRIA linha de usuário',
  (select n from _leu where quem = 'agencia' and r = 'usuarios') = 1
    and (select n from _leu where quem = 'agencia' and r = 'meta_ads_diario') = (select count(*) from public.meta_ads_diario)
    and (select n from _leu where quem = 'agencia' and r = 'config_metas') = (select count(*) from public.config_metas),
  (select string_agg(r || '=' || n, ', ') from _leu where quem = 'agencia' and r in ('usuarios', 'meta_ads_diario', 'config_metas')));
select sim.confere('as listas do time (conversas_lista, leads_lista, jornada_live) não devolvem nada à agência', :ag_listas = 0, :'ag_listas');
select sim.confere('agência não grava: não muda o próprio perfil nem os dados da Meta', :ag_virou_admin = 0 and :ag_gravou_meta = 0,
  :'ag_virou_admin' || ' / ' || :'ag_gravou_meta');
select sim.confere('o Placar da agência vem sem nome, CPF, telefone, endereço, vendedor, pedido e comissão',
  :'ag_placar' is not null and :'ag_placar' !~* '(cliente|cpf|cnpj|whatsapp|telefone|email|logradouro|bairro|vendedor|comissao|nio_pedido|"nio_os"|"id")'
    and :'ag_placar' !~ (select string_agg(id::text, '|') from public.vendas),
  left(:'ag_placar', 200));
select sim.confere('o Placar da agência traz todas as vendas com OS', jsonb_array_length(:'ag_placar'::jsonb) = (select count(*) from public.vendas where nio_os is not null),
  jsonb_array_length(:'ag_placar'::jsonb)::text);
select sim.confere('a Tabela da agência vem sem comissão', :'ag_tabela' !~* 'comiss' and jsonb_array_length(:'ag_tabela'::jsonb -> 'planos') > 0, left(:'ag_tabela', 120));
select sim.confere('a agência recebe a meta do mês (só números)', :'ag_ritmo'::boolean, 'nulo');
select sim.confere('fonte única: Meta Ads e Placar dão à agência exatamente o que dão ao admin',
  :'ag_res'::jsonb = :'ad_res'::jsonb and :'ag_dia'::jsonb = :'ad_dia'::jsonb and :'ag_conv'::jsonb = :'ad_conv'::jsonb and :'ag_motivos'::jsonb = :'ad_motivos'::jsonb,
  'diferente');
select sim.confere('o resultado do Meta Ads conta todas as conversas de anúncio, uma vez cada',
  (select sum((x ->> 'n')::int) from jsonb_array_elements(:'ag_res'::jsonb -> 'conversas') x) = (select count(*) from public.mari_conversas where origem = 'meta_ads'),
  (select sum((x ->> 'n')::int)::text from jsonb_array_elements(:'ag_res'::jsonb -> 'conversas') x));
select sim.confere('o resultado do Meta Ads só tem contagem (nenhum id de conversa ou de venda, nenhum telefone)',
  :'ag_res' !~ (select string_agg(id::text, '|') from public.mari_conversas where origem = 'meta_ads')
    and :'ag_res' !~* '(telefone|conversa_id|venda_id|dataset_id)', 'veio identificador');
select sim.confere('o dia a dia do Meta Ads vai sem as colunas de venda e de comissão', :'ag_dia' !~* '(comissao|vendas)', left(:'ag_dia', 120));
select sim.confere('as conversas por dia do Placar somam as conversas do período',
  (select sum((x ->> 'conversas')::int) from jsonb_array_elements(:'ag_conv'::jsonb) x) = (select count(*) from public.mari_conversas where created_at >= '2026-01-01 00:00-03'),
  'soma diferente');
select sim.confere('quem já lia continua lendo: o backoffice lê as oito tabelas que passaram a exigir perfil',
  public.meu_perfil() is null and :'bo_perfil' = 'backoffice'
    and not exists (select 1 from _leu l where l.quem = 'backoffice' and l.r in ('conteudos', 'projetor_sombra', 'porta_sombra', 'lead_estado',
          'lead_estado_mudancas', 'meta_eventos', 'mari_portao_rodadas', 'pulso_batimentos', 'mari_conversas', 'config_planos', 'meta_ads_conta_saldo')
        and l.n is distinct from (select (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', l.r), false, true, '')))[1]::text::bigint)),
  (select string_agg(r || '=' || n, ', ') from _leu where quem = 'backoffice' and r in ('conteudos', 'projetor_sombra', 'porta_sombra', 'lead_estado', 'meta_eventos', 'pulso_batimentos')));

-- "Por que os leads saíram": a saída de um lead de anúncio entra na contagem, só como número
select sim.como('agencia');
select coalesce(sum((x ->> 'n')::int), 0) as antes from jsonb_array_elements(public.meta_ads_motivos_saida(null, null) -> 'linhas') x where x ->> 'motivo' = 'recusou' \gset
select sim.como('backoffice');
select public.lead_sair(:'a', null, 'recusou', 'preco');
select sim.como('agencia');
select coalesce(sum((x ->> 'n')::int), 0) as depois from jsonb_array_elements(public.meta_ads_motivos_saida(null, null) -> 'linhas') x where x ->> 'motivo' = 'recusou' \gset
select public.meta_ads_motivos_saida(null, null)::text as mot \gset
select sim.como('servico');
select sim.confere('a saída "Recusou" de um lead de anúncio soma 1 no bloco "Por que os leads saíram"', :depois = :antes + 1, :'antes' || ' → ' || :'depois');
select sim.confere('o bloco dos motivos só tem contagem (nenhum id, nome ou telefone)',
  :'mot' !~ (select string_agg(id::text, '|') from public.mari_conversas) and :'mot' !~* '(X87|telefone|conversa_id|lead_id)', 'veio identificador');
select sim.confere('os motivos somam as saídas de leads de anúncio da v_leads',
  (select sum((x ->> 'n')::int) from jsonb_array_elements(:'mot'::jsonb -> 'linhas') x)
    = (select count(*) from public.v_leads where origem = 'meta_ads' and destino = 'saida' and saida_motivo is not null),
  'soma diferente');

-- a conta fecha todo dia: limpo agora; afrouxou, acusa
select sim.confere('conferência: nada aberto demais para a agência', public.agencia_leituras_indevidas() = '[]'::jsonb, public.agencia_leituras_indevidas()::text);
select sim.confere('conferência: o item agencia_leitura existe e está verde',
  (select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'agencia_leitura') = 'ok', 'faltou ou vermelho');
create policy x87_frouxa on public.vendas for select to authenticated using ((select public.sou_agencia()));
create policy x87_aberta on public.mari_turnos for select to authenticated using (true);
select sim.confere('conferência: policy que libera a agência em tabela de cliente, ou tabela de cliente aberta a qualquer login, é acusada',
  jsonb_array_length(public.agencia_leituras_indevidas()) = 2
    and (select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'agencia_leitura') = 'falha',
  public.agencia_leituras_indevidas()::text);
drop policy x87_frouxa on public.vendas;
drop policy x87_aberta on public.mari_turnos;

-- agência desativada volta a não ler nada
update public.usuarios set ativo = false where perfil = 'agencia';
select sim.como('agencia');
set role authenticated;
select public.sou_agencia() as inativa_sou, (select count(*) from public.meta_ads_diario) as inativa_le, public.meta_ads_resultado() is null as inativa_res \gset
reset role;
select sim.como('servico');
select sim.confere('agência desativada não lê mais nada', not :'inativa_sou'::boolean and :inativa_le = 0 and :'inativa_res'::boolean, :'inativa_le');
