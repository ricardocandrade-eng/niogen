-- id: X138
-- titulo: 0410 (rotina do Dashboard, 25/11): osab_importar existe de novo — a OSAB do robô entra pela mesma regra da importação manual (Concluído com data real leva a venda instalada a Ativa provisória) e arquivo vazio é recusado sem apagar o retrato
-- tipo: atual
select sim.como('servico');
-- 27/11: o cenário monta o próprio estado — quando a cópia não traz venda instalada com pedido (na produção todas já viraram Ativa),
-- a venda ativa mais nova volta a 'instalada' só aqui, para a OSAB do robô ter o que casar.
do $x138$ begin
  if not exists (select 1 from public.vendas where status = '3_instalado' and coalesce(btrim(nio_pedido), '') <> '') then
    perform set_config('session_replication_role', 'replica', true);
    update public.vendas set status = '3_instalado', nio_osab_em = null, nio_situacao = null
     where id = (select id from public.vendas where status = '4_ativo_provisorio' and coalesce(btrim(nio_pedido), '') <> '' order by criado_em desc limit 1);
    perform set_config('session_replication_role', 'origin', true);
  end if;
end $x138$;
select id as v, btrim(nio_pedido) as os from public.vendas where status = '3_instalado' and coalesce(btrim(nio_pedido), '') <> '' order by criado_em desc limit 1 \gset
select sim.confere('arquivo vazio é recusado', sim.recusa($q$select public.osab_importar('vazio', '[]'::jsonb)$q$) is not null, '');
select public.osab_importar('teste X137', jsonb_build_array(jsonb_build_object('pedido', :'os', 'situacao', 'Concluído', 'fonte', 'painel',
  'data_fechamento', '2026-11-20T10:00:00-03:00', 'atualizado_nio_em', '2026-11-25T14:25:13-03:00', 'dt_ref', '2026-11-25'))) as r \gset
select sim.confere('a OSAB automática casa o pedido e leva a venda instalada a Ativa (provisória)',
  (select status = '4_ativo_provisorio' and nio_osab_em is not null and nio_situacao = 'Concluído' from public.vendas where id = :'v'), :'r');
select sim.confere('o retrato da OSAB é só este arquivo', (select count(*) from public.nio_osab) = 1, (select count(*)::text from public.nio_osab));
