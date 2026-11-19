-- id: X44
-- titulo: Caso Michele (19/11): o crédito volta "pedido em andamento" (pedido Nio de OUTRA revenda) → NÃO é cliente Nio; o lead segue em andamento com o time; crédito aprovado depois limpa a marca. E Reabrir em "Cliente Nio" só o admin
-- tipo: atual
select sim.lead_pronto('Michele X44') as c \gset
select sim._servico();
select public.mari_credito_gravar(:'c', '{"resultado": "pedido_em_andamento"}'::jsonb);
select sim.fila_rodar();
select sim.confere('pedido de outra revenda: não virou cliente Nio', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('segue em andamento (não silencia, não é Saída nem cliente Nio)', :'s1' not in ('cliente_nio', 'saida_definitiva', 'saida_pode_voltar'), :'s1');
select sim.confere('a conversa não foi adiada no Chatwoot', coalesce(sim.cw_de(:'c') ->> 'status', 'open') <> 'snoozed', sim.cw_de(:'c')::text);
select sim._servico();
select public.mari_credito_gravar(:'c', '{"resultado": "aprovado_todas"}'::jsonb);
select sim.confere('crédito aprovado depois: a marca de pedido aberto caiu',
  (select nio_pedido_aberto from public.mari_conversas where id = :'c') = 'nao', (select coalesce(nio_pedido_aberto, 'null') from public.mari_conversas where id = :'c'));

-- Reabrir em Cliente Nio: só o admin (quem foi marcado errado por elegibilidade, por exemplo)
select sim.lead_novo('Kelly X44') as k \gset
select sim._servico();
select public.mari_handoff(:'k', 'ja_cliente_nio', '{}'::jsonb);
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'k'), '') as sk \gset
select sim.confere('marcado cliente Nio', :'sk' = 'cliente_nio', :'sk');
select coalesce((select p.exige from public.porta_prever('cliente_nio', 'reabrir') p), 'sem regra') as ex \gset
select sim.confere('Reabrir em Cliente Nio existe e é só do admin', :'ex' = 'admin', :'ex');
