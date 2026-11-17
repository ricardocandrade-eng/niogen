-- id: X6
-- titulo: Cliente pediu SAIR: Reabrir é recusado; depois que ele escreve de novo, Reabrir vale (decisão b, 17/11)
-- tipo: atual
select sim.lead_novo('Nina X6') as c \gset
select sim.cliente_escreve(:'c', 'SAIR');
select sim.fila_rodar();
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.lead_reabrir(%L, null)$q$, :'c')), '') as rec \gset
select sim.confere('sem o cliente escrever, Reabrir é recusado', :'rec' like '%escrever de novo%', coalesce(nullif(:'rec', ''), 'aceitou'));
select sim.como('servico');
select sim.cliente_escreve(:'c', 'oi, quero saber da internet de novo');
select sim.fila_rodar();
select sim.como('backoffice');
select public.lead_reabrir(:'c', null);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('reabriu e o Não contatar saiu', sim.lead_de(:'c') ->> 'destino' = 'em_andamento' and not (sim.foto(:'c') ->> 'nao_contatar')::boolean, sim.foto(:'c')::text);
