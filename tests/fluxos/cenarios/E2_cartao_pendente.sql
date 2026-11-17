-- id: E2
-- titulo: Cartão pendente: aviso do cadastro, um lembrete em 24 h e depois o time liga
-- tipo: atual
select sim.venda_pronta('Oto E2') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '92' || sim._conv(:'c'), 'dia', (current_date + 5)::text, 'periodo', '13:00', 'forma', 'cartao'));
select sim.fila_rodar();
select sim.como('servico');
select count(*) from sim.cadencia(sim.meio_dia());
select sim.confere('saiu o aviso do cadastro do cartão', sim.envios_de(:'c', 'cadencia:CARTAO') = 1, 'CARTAO: ' || sim.envios_de(:'c', 'cadencia:CARTAO'));
select sim.confere('a confirmação da instalação espera o cartão', sim.envios_de(:'c', 'cadencia:INSTALACAO') = 0, 'INSTALACAO: ' || sim.envios_de(:'c', 'cadencia:INSTALACAO'));
select sim.passa(:'c', '1 day');
-- o template do cartão (nio_cartao_cadastro) ainda não está aprovado na Meta: fora da janela de 24 h o lembrete não tem como sair.
-- Aqui o cliente escreveu de manhã (janela aberta) e o lembrete sai como texto.
select sim.cliente_escreve(:'c', 'oi, recebi o link do cartão', false, '0');
select count(*) from sim.cadencia(sim.meio_dia() + interval '1 hour');
select sim.passa(:'c', '1 day');
select count(*) from sim.cadencia(sim.meio_dia() + interval '1 hour');
select sim.confere('um lembrete do cartão, uma vez só', sim.envios_de(:'c', 'cadencia:CARTAO2') = 1, 'CARTAO2: ' || sim.envios_de(:'c', 'cadencia:CARTAO2'));
select sim.confere('nada mais automático sobre o cartão', sim.envios_de(:'c', 'cadencia:CARTAO') = 1, 'CARTAO: ' || sim.envios_de(:'c', 'cadencia:CARTAO'));
