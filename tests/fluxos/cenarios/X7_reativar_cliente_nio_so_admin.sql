-- id: X7
-- titulo: Cliente Nio silenciado: o backoffice não reativa, o admin reativa (decisão c, 17/11)
-- tipo: atual
select sim.lead_novo('Olivia X7') as c \gset
select sim.como('backoffice');
select public.backoffice_conversa_saida(:'c', 'suporte_nio');
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.backoffice_conversa_saida(%L, 'reativar')$q$, :'c')), '') as rec \gset
select sim.confere('o backoffice recebe a recusa com a frase', :'rec' like '%admin%', coalesce(nullif(:'rec', ''), 'aceitou'));
select sim.como('admin');
select public.porta_motivo_preparar('teste do X7: não é cliente Nio, quer contratar');   -- 0298: ação de admin pede o motivo
select public.backoffice_conversa_saida(:'c', 'reativar');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o silêncio saiu', coalesce((select quadro_encerrada_motivo from public.mari_conversas where id = :'c'), '') = '', sim.foto(:'c')::text);
select sim.confere('sem a etiqueta suporte-nio', not ((sim.cw_de(:'c') -> 'etiquetas') ? 'suporte-nio'), sim.cw_de(:'c')::text);
