-- id: X32
-- titulo: Fase 2, passo 6 (0298): ação só do admin pede o motivo — sem motivo é recusada (MOTIVO_ADMIN); com o motivo vale e ele fica gravado no evento da porta
-- tipo: atual
-- Decisões D11, D15, E7 de 17/11: "só admin, com motivo". Até a 0298 só o Mover pedia o motivo.
select sim.lead_com_venda('Rosa X32') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'credito_negado');
select sim.fila_rodar();
select sim.como('admin');
select coalesce(sim.recusa(format($q$select public.lead_reabrir(%L, null)$q$, :'c')), '') as rec \gset
select sim.confere('sem motivo, a ação do admin é recusada pedindo o motivo', :'rec' like 'MOTIVO_ADMIN:%', coalesce(nullif(:'rec', ''), 'aceitou'));
select sim.confere('sem motivo, nada mudou (continua em Saída definitiva)', sim.foto(:'c') -> 'venda' ->> 'status' = 'saida', (sim.foto(:'c') -> 'venda' ->> 'status'));
select public.porta_motivo_preparar('cliente aprovado no crédito pela Nio em nova consulta');
select public.lead_reabrir(:'c', null);
select sim.fila_rodar();
select sim.confere('com o motivo, o admin reabre', sim.foto(:'c') -> 'venda' ->> 'status' <> 'saida', (sim.foto(:'c') -> 'venda' ->> 'status'));
select sim.confere('o motivo ficou gravado no evento da porta',
  exists (select 1 from public.porta_sombra s where s.conversa_id = :'c' and s.evento = 'reabrir'
           and s.motivo = 'cliente aprovado no crédito pela Nio em nova consulta'),
  (select string_agg(evento || ' · ' || coalesce(motivo, '(sem motivo)'), ' | ') from public.porta_sombra s where s.conversa_id = :'c'));
select sim.confere('o motivo preparado foi usado uma vez só',
  (select count(*) from public.porta_motivos where usado_em is null) = 0
  and (select evento from public.porta_motivos order by id desc limit 1) = 'reabrir',
  (select string_agg(coalesce(evento, '(não usado)'), ', ') from public.porta_motivos));
select coalesce(sim.recusa($q$select public.porta_motivo_preparar('abc')$q$), '') as curto \gset
select sim.confere('motivo curto demais é recusado', :'curto' like '%5 letras%', coalesce(nullif(:'curto', ''), 'aceitou'));
select sim.como('backoffice');
select coalesce(sim.recusa($q$select public.porta_motivo_preparar('tentando passar como admin')$q$), '') as bo \gset
select sim.confere('só o admin prepara motivo', :'bo' like '%admin%', coalesce(nullif(:'bo', ''), 'aceitou'));
select sim.como('servico');
