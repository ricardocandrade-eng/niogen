-- id: E2
-- titulo: Cartão pendente: instrução do cadastro na OS (0366), um lembrete em 24 h e depois o time liga
-- tipo: atual
select sim.venda_pronta('Oto E2') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '92' || sim._conv(:'c'), 'dia', (current_date + 5)::text, 'periodo', '13:00', 'forma', 'cartao'));
select sim.fila_rodar();
select sim.como('servico');
select count(*) from sim.cadencia(sim.meio_dia());
-- 0366 (L-248, Ricardo 23/11: "acho que o Niogen pode fazer isso"): a instrução do cartão sai na hora em que a OS é gravada no
-- cartão com a biometria aprovada (bo_cartao_link), e não mais pela cadência depois da agenda; a cadência fica com o lembrete.
select sim.confere('saiu a instrução do cadastro do cartão (na OS), uma vez',
  (select count(*) from sim.envios where conversa = :'c' and texto ilike '%cadastrar o cartão%') = 1 and sim.envios_de(:'c', 'cadencia:CARTAO') = 0,
  'instrução: ' || (select count(*) from sim.envios where conversa = :'c' and texto ilike '%cadastrar o cartão%') || ' · CARTAO: ' || sim.envios_de(:'c', 'cadencia:CARTAO'));
select sim.confere('a confirmação da instalação espera o cartão', sim.envios_de(:'c', 'cadencia:INSTALACAO') = 0, 'INSTALACAO: ' || sim.envios_de(:'c', 'cadencia:INSTALACAO'));
select sim.passa(:'c', '1 day');
-- o template do cartão (nio_cartao_cadastro) ainda não está aprovado na Meta: fora da janela de 24 h o lembrete não tem como sair.
-- Aqui o cliente escreveu de manhã (janela aberta) e o lembrete sai como texto.
select sim.cliente_escreve(:'c', 'oi, recebi o link do cartão', false, '0');
select count(*) from sim.cadencia(sim.meio_dia() + interval '1 hour');
select sim.passa(:'c', '1 day');
select count(*) from sim.cadencia(sim.meio_dia() + interval '1 hour');
select sim.confere('um lembrete do cartão, uma vez só', sim.envios_de(:'c', 'cadencia:CARTAO2') = 1, 'CARTAO2: ' || sim.envios_de(:'c', 'cadencia:CARTAO2'));
select sim.confere('nada mais automático sobre o cartão',
  sim.envios_de(:'c', 'cadencia:CARTAO') = 0 and (select count(*) from sim.envios where conversa = :'c' and texto ilike '%cadastrar o cartão%') = 1,
  'CARTAO: ' || sim.envios_de(:'c', 'cadencia:CARTAO'));
