-- id: X23
-- titulo: Caso Silvanio (0280): Saída "Recusou · desistiu" e "Recusou" sem motivo ligam a Retomada; preço não liga
-- tipo: atual
select sim.lead_novo('Silva X23') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'desistiu')::text as r \gset
select sim.fila_rodar();
select sim.confere('desistiu: a Saída avisa que a Mari faz a Retomada', :'r' like '%Retomada%', :'r');
select sim.confere('desistiu: a Retomada começou', (select retomada_desde is not null and retomada_origem = 'saida_recusou' from public.mari_conversas where id = :'c'), '');

select sim.lead_novo('Sem Motivo X23') as c2 \gset
select sim.como('backoffice');
select public.lead_sair(:'c2', null, 'recusou', 'outro')::text as r2 \gset
select sim.fila_rodar();
select sim.confere('outro: não liga a Retomada', (select retomada_desde is null from public.mari_conversas where id = :'c2'), :'r2');

select sim.lead_novo('Preco X23') as c3 \gset
select sim.como('backoffice');
select public.lead_sair(:'c3', null, 'recusou', 'preco')::text as r3 \gset
select sim.fila_rodar();
select sim.confere('preço: não liga a Retomada', (select retomada_desde is null from public.mari_conversas where id = :'c3'), :'r3');

-- sem motivo: a Mari deu a recusa no handoff? não — aqui o time grava "Recusou" sem motivo pela casca (p_pede_sub = false: silenciar:recusou)
select sim.lead_novo('Vazio X23') as c4 \gset
select sim.como('backoffice');
select public.porta('silenciar:recusou', :'c4', null::uuid, '{}'::jsonb)::text as r4 \gset
select sim.fila_rodar();
select sim.confere('sem motivo: a Retomada começou', (select retomada_desde is not null from public.mari_conversas where id = :'c4'), :'r4');
select sim.como('servico');
