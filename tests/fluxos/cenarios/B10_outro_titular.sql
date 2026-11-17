-- id: B10
-- titulo: Crédito negado, outro titular aprovado: a pendência "outro CPF" fecha e a venda segue
-- tipo: atual
select sim.lead_com_venda('Vivi B10') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"negado"}');
select sim.fila_rodar();
select sim.confere('abriu a pendência de outro CPF', exists (select 1 from public.venda_pendencias where venda_id = sim.venda(:'c') and encerrada_em is null), null);
select public.venda_trocar_titular(sim.venda(:'c'), 'Maria Titular Simulada', sim.cpf(777000 + sim._conv(:'c')::int % 1000), 'mãe', 'crédito negado no CPF do filho', 'aprovado');
select sim.fila_rodar();
select sim.confere('a pendência de outro CPF fechou', not exists (select 1 from public.venda_pendencias where venda_id = sim.venda(:'c') and encerrada_em is null),
  (select string_agg(motivo, ', ') from public.venda_pendencias where venda_id = sim.venda(:'c') and encerrada_em is null));
select sim.confere('a escada segue para a biometria/pedido (crédito ok)', sim.lead_de(:'c') ->> 'status' in ('fazer_pedido', 'aguarda_biometria', 'abrir_os'), sim.lead_de(:'c')::text);
