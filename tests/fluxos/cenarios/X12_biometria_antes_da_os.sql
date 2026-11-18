-- id: X12
-- titulo: Caso Geraldo (0272): crédito aprovado com biometria pendente — a Live espera a biometria (não manda gravar a OS) e a biometria à mão só sai sem leitura do GED360 há 2 h
-- tipo: atual
select sim.lead_com_venda('Gil X12') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select coalesce((select o_que_fazer || ' | ' || botao from public.v_jornada where venda_id = sim.venda(:'c') limit 1), '') as j1 \gset
select sim.confere('crédito aprovado sem link: a Live não manda gravar a OS', :'j1' not like '%gravar a OS%' and :'j1' like '%Continuar manda a biometria%', :'j1');

-- o robô do GED360 lê "LINK ENVIADO" (como no caso Geraldo)
select sim._servico();
insert into public.nio_biometria (protocolo, cpf_cnpj, resultado, venda_id, ultima_leitura)
values ('X12-' || sim._conv(:'c'), '00000000000', 'LINK ENVIADO', sim.venda(:'c'), now());
update public.vendas set biometria_status = 'pendente', biometria_link_enviado_em = now() where id = sim.venda(:'c');
select sim.como('backoffice');
select coalesce((select o_que_fazer || ' | ' || botao || ' | ' || nivel from public.v_jornada where venda_id = sim.venda(:'c') limit 1), '') as j2 \gset
select sim.confere('link enviado: a Live diz "esperando a biometria do cliente"', :'j2' like '%esperando a biometria do cliente%' and :'j2' not like '%| os |%', :'j2');

select public.porta_botoes(:'c', sim.venda(:'c')) as b \gset
select sim.confere('com leitura do GED360: "Biometria validada" à mão não aparece e diz por quê',
  not (:'b'::jsonb #>> '{eventos,momento:biometria:validada,ok}')::boolean and coalesce(:'b'::jsonb #>> '{eventos,momento:biometria:validada,frase}', '') like '%GED360: LINK ENVIADO%',
  :'b'::jsonb #>> '{eventos,momento:biometria:validada}');
-- 0275 (mapa situação × botão, Ricardo 18/11): "Nio dispensou" pula a biometria — passou a ser só do admin
select sim.confere('"Nio dispensou" continua existindo, só para o admin', not (:'b'::jsonb #>> '{eventos,momento:biometria:dispensada,ok}')::boolean
  and (:'b'::jsonb #>> '{eventos,momento:biometria:dispensada,exige}') = 'admin', :'b'::jsonb #>> '{eventos,momento:biometria:dispensada}');
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'biometria', '{"resultado":"validada"}')$q$, sim.venda(:'c'))), '') as rec \gset
select sim.confere('a porta recusa a biometria à mão com a leitura do GED360', :'rec' like '%GED360%', coalesce(nullif(:'rec', ''), 'aceitou'));

-- o admin ainda vê o botão, mas marcado: a tela diz que é só dele e o que o GED360 diz (0273, caso Geraldo)
select sim.como('admin');
select public.porta_botoes(:'c', sim.venda(:'c')) as ba \gset
select sim.confere('admin: o botão aparece com o aviso "Só o admin" e o status do GED360',
  (:'ba'::jsonb #>> '{eventos,momento:biometria:validada,ok}')::boolean and coalesce(:'ba'::jsonb #>> '{eventos,momento:biometria:validada,frase}', '') like 'Só o admin%GED360: LINK ENVIADO%',
  :'ba'::jsonb #>> '{eventos,momento:biometria:validada}');

-- 3 h depois sem leitura nova: a mão volta a valer
select sim.passa(:'c', '3 hours');
select sim.como('backoffice');
select public.porta_botoes(:'c', sim.venda(:'c')) as b2 \gset
select sim.confere('sem leitura do GED360 há mais de 2 h: "Biometria validada" volta a aparecer', (:'b2'::jsonb #>> '{eventos,momento:biometria:validada,ok}')::boolean,
  :'b2'::jsonb #>> '{eventos,momento:biometria:validada}');
