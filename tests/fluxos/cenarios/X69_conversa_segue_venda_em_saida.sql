-- id: X69
-- titulo: 0344 (21/11): conversa que ficou "em andamento" com a venda já em Saída (dado de antes da porta) — a conversa segue a venda: destino de Saída, sem dono, fechada no Chatwoot, a situação gravada concorda
-- tipo: atual
-- Caso do debate da Live (21/11 ~02h): venda em Saída · "Nio não instalou" desde 13/11 e a conversa aberta, "em andamento".
select sim.venda_pronta('Lia X69', true) as c \gset
select sim.como('servico');
-- premissa: a venda saiu ANTES da porta (sem o gatilho vendas_porta, como em 13/11)
alter table public.vendas disable trigger vendas_porta;
update public.vendas set status = 'saida', motivo_saida = 'Nio não instalou', saida_motivo = 'nio_nao_instalou' where id = sim.venda(:'c');
alter table public.vendas enable trigger vendas_porta;
select sim.confere('premissa: venda em Saída e a conversa ainda em andamento',
  (select status from public.vendas where id = sim.venda(:'c')) = 'saida'
  and (select coalesce(funil_destino, 'em_andamento') from public.mari_conversas where id = :'c') = 'em_andamento',
  (select coalesce(funil_destino, 'em_andamento') from public.mari_conversas where id = :'c'));

select public._porta_conversa_segue_venda(:'c')::text as r \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('a conversa seguiu a venda: destino de Saída',
  (select coalesce(funil_destino, 'em_andamento') from public.mari_conversas where id = :'c') <> 'em_andamento', :'r');
select sim.confere('sem dono e fechada no Chatwoot',
  sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null and sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s \gset
select sim.confere('a situação é de Saída', :'s' like 'saida_%', :'s');
select sim.confere('a porta anotou a mudança', exists (select 1 from public.porta_sombra where conversa_id = :'c' and origem = '0344'), 'sem anotação');
select public._porta_conversa_segue_venda(:'c')::text as r2 \gset
select sim.confere('rodar de novo não faz nada', :'r2'::jsonb ->> 'ok' = 'false', :'r2');

