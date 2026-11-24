-- id: X101
-- titulo: Margem por canal (0376) e plano e datas na conciliação (0377, Ricardo 24/11: "Sim, corrigir"): a "Comissão Nio paga" do canal vem das linhas do extrato da Nio na razão (comissão, bônus, estorno), não da coluna antiga vendas.comissao_paga que ninguém escreve; linha da Nio sem venda não entra em canal nenhum
-- tipo: atual

-- A) venda instalada na 1ª quinzena, com OS
select sim.venda_pronta('Cliente X101') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', 'X101OS1', 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.instalou(:'c');
select sim.como('servico');
update public.vendas set instalado_em = '2026-11-13 12:00-03', nio_os = 'X101OS1', nio_pedido = 'X101OS1' where id = sim.venda(:'c');
select origem as orig from public.vendas where id = sim.venda(:'c') \gset
select coalesce((select comissao_nio_paga from public.v_margem_canal where origem = :'orig'), 0) as antes \gset

-- B) o extrato chega: 350 de comissão + 30 de bônus desta venda e 50 de um contrato sem venda
select sim.como('backoffice');
select public.extrato_importar('202611_1Q_X101.xlsx', $j${
  "PEDIDO": [{"CICLO": "1QNOV26", "DOCUMENTO DE COMPRAS": "4500000101", "VALOR": 430}],
  "LINHA_A_LINHA": [
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO", "NUM_OS_PEDIDO_SIEBEL": "X101OS1", "DATA_ATV": "46339", "COMISSAO": 350},
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "BONUS", "SUB_EVENTO": "TRANSICAO", "NUM_OS_PEDIDO_SIEBEL": "X101OS1", "DATA_ATV": "46339", "COMISSAO": 30},
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO", "CONTRATO": "X101SEM", "NUM_OS_PEDIDO_SIEBEL": "X101OS9", "DATA_ATV": "46339", "COMISSAO": 50}]}$j$::jsonb);

-- C) o pago do canal da venda sobe exatamente 380 (o contrato sem venda fica fora)
select sim.confere('comissão Nio paga do canal = antes + 380 (linhas do extrato desta venda)',
  (select comissao_nio_paga from public.v_margem_canal where origem = :'orig') = :'antes'::numeric + 380,
  (select row_to_json(m)::text from public.v_margem_canal m where origem = :'orig'));
select sim.confere('margem paga do canal acompanha (sem custo de parceiro fora do PAP)',
  (select margem_paga = comissao_nio_paga - parceiros_pago from public.v_margem_canal where origem = :'orig'), null);
select sim.confere('nenhum canal recebe a linha de 50 sem venda',
  (select coalesce(sum(comissao_nio_paga), 0) from public.v_margem_canal)
  = (select coalesce(sum(valor), 0) from public.comissao_lancamentos where origem = 'extrato' and venda_id is not null), null);

-- D) 0377: a conciliação diz o plano, a data da venda e a da instalação
select sim.confere('v_conciliacao traz plano, data da venda e data da instalação da venda',
  (select plano_nome is not distinct from (select coalesce(p.nome_curto, p.nome) from public.vendas v2 left join public.config_planos p on p.id = v2.plano_id where v2.id = sim.venda(:'c'))
          and vendido_em is not null and (instalado_em at time zone 'America/Sao_Paulo')::date = date '2026-11-13'
     from public.v_conciliacao where venda_id = sim.venda(:'c') and ciclo = '2026-11-1Q'),
  (select row_to_json(x)::text from public.v_conciliacao x where venda_id = sim.venda(:'c')));
