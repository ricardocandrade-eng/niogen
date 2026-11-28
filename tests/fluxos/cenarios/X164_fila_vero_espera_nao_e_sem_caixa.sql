-- id: X164
-- titulo: 0442 (Ricardo, 28/11, print da tela da Mari: "todos sem cadência ligada e com a conversa aberta, sem saída. Acredito que isso seja um furo" → "Sim, corrigir"): lead da Fila Vero que clicou na oferta e não escreveu tem a Saída automática marcada (0285/0426), então não é "Sem caixa" — é Mari conduzindo, com o texto dizendo quando ele sai sozinho; se a Saída automática atrasar mais de 1 h, o alarme volta
-- tipo: atual
select sim.como('servico');
insert into sim.cw (conv, telefone, nome) values
  ('996401', '5531999640001', 'Ana X164'), ('996402', '5531999640002', 'Bia X164'), ('996403', '5531999640003', 'Caio X164');
insert into public.fila_vero (nome, telefone, segmento, status, template, wamid, codigo)
values ('Ana X164', '5531999640001', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X164A', 'x164a001'),
       ('Bia X164', '5531999640002', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X164B', 'x164b002'),
       ('Caio X164', '5531999640003', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X164C', 'x164c003');
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x164a001'), true, '996401') ->> 'conversa_id') as a \gset
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x164b002'), true, '996402') ->> 'conversa_id') as b \gset
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x164c003'), true, '996403') ->> 'conversa_id') as c \gset
select sim.fila_rodar();

-- 1) clicou, recebeu o template e não escreveu (antes do Enviei): a Saída automática já tem data → não é "Sem caixa"
select sim.passa(:'a', interval '61 minutes');
select sim.passa(:'b', interval '61 minutes');
select sim.passa(:'c', interval '61 minutes');
select caixa as cx1, precisa_acao as pa1, nivel as nv1, o_que_fazer as of1 from public.v_jornada where conversa_id = :'a' \gset
select sim.confere('clicou e não escreveu: Mari conduzindo (caixa 1), não "Sem caixa"', :cx1 = 1, :cx1 || ' · ' || :'of1');
select sim.confere('não sobe ao Para fazer pela jornada (a tarefa é o cartão "Chamar por fora" da Live 2.0)', not :'pa1'::boolean and :'nv1' = 'espera', :'pa1' || ' · ' || :'nv1');
select sim.confere('o texto diz que é Fila Vero, manda chamar por fora e diz quando sai sozinho',
  :'of1' like 'Fila Vero:%' and :'of1' like '%chamar por fora pela Live 2.0%' and :'of1' ~ 'sai sozinho em \d\d/\d\d \d\d:\d\d' and :'of1' not like 'Sem caixa%', :'of1');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a'), '{}') as la \gset
select sim.confere('na Live 2.0 o cartão "Chamar por fora" continua na fila 1 h depois',
  (:'la')::jsonb -> 'fontes' ? 'fila_vero:chamar_fora', left(:'la', 300));
select sim.confere('e o lead não está mais na fila como "Sem caixa"',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a' and x ->> 'oque' like 'Sem caixa%'),
  (:'la')::jsonb ->> 'oque');

-- 2) depois do Enviei: continua Mari conduzindo, e o texto passa a contar do contato por fora
select (public.fila_vero_fora_enviei(:'a') ->> 'ok') as ok \gset
select sim.como('servico');
select caixa as cx2, precisa_acao as pa2, o_que_fazer as of2 from public.v_jornada where conversa_id = :'a' \gset
select sim.confere('depois do Enviei: caixa 1, fora do Para fazer', :cx2 = 1 and not :'pa2'::boolean, :cx2 || ' · ' || :'pa2');
select sim.confere('o texto diz "chamado por fora em" e a data da Saída automática (2 dias do Enviei)',
  :'of2' like 'Fila Vero:%chamado por fora em%' and :'of2' like '%sai sozinho em ' || to_char(((select fora_enviado_em from public.fila_vero where codigo = 'x164a001') + interval '2 days') at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || '%',
  :'of2');

-- 3) a Saída automática roda no prazo e o lead sai (o texto prometeu a verdade)
select sim.passa(:'a', interval '49 hours');
select public.fila_vero_clique_encerrar();
select sim.confere('2 dias depois do Enviei a Saída automática leva o lead',
  (select coalesce(funil_destino, 'em_andamento') <> 'em_andamento' from public.mari_conversas where id = :'a'),
  (select funil_destino from public.mari_conversas where id = :'a'));

-- 4) regra 20 (ninguém parado em silêncio): se a Saída automática NÃO rodar, 1 h depois do prazo o alarme "Sem caixa" volta
select sim.passa(:'b', interval '2 days 2 hours');
select caixa as cx4, precisa_acao as pa4, o_que_fazer as of4 from public.v_jornada where conversa_id = :'b' \gset
select sim.confere('prazo da Saída vencido há mais de 1 h e o lead ainda aqui: volta a ser "Sem caixa", no Para fazer',
  :cx4 = 5 and :'pa4'::boolean and :'of4' like 'Sem caixa%', :cx4 || ' · ' || :'of4');
select public.fila_vero_clique_encerrar();

-- 5) o cliente escreveu: deixa de ser espera da Fila Vero (a conversa é da Mari, pelo caminho de sempre)
select sim.cliente_escreve(:'c', 'Oi, quero saber da internet', false);
select sim.fila_rodar();
select o_que_fazer as of5 from public.v_jornada where conversa_id = :'c' \gset
select sim.confere('cliente escreveu: o texto da espera da Fila Vero some', :'of5' not like 'Fila Vero: clicou%', :'of5');

-- 6) lead comum sem toque marcado continua "Sem caixa" (a regra nova vale só para a espera da Fila Vero)
select sim.lead_novo('Davi X164') as d \gset
update public.mari_conversas
   set ultima_msg_lead_at = now() - interval '3 days', ultima_msg_mari_at = now() - interval '2 hours',
       cadencia_proximo_em = null, cadencia_passo = 'F3', retomada_desde = null, retomada_fim = null, status = 'ativo'
 where id = :'d';
select caixa as cx6 from public.v_jornada where conversa_id = :'d' \gset
select sim.confere('lead comum, a Mari falou por último e não há toque marcado: continua caixa 5', :cx6 = 5, :cx6::text);

-- 7) orçamento de memória (regra 19): o plano da v_jornada continua dentro dos 20 MB
create temp table x164_plano (kb int);
do $$
declare j json;
begin
  execute 'explain (memory, format json) select * from public.v_jornada' into j;
  insert into x164_plano values ((j -> 0 -> 'Planning' ->> 'Memory Used')::int);
end $$;
select sim.confere('o plano da v_jornada cabe em 20 MB', (select kb < 20000 from x164_plano), (select kb || ' kB' from x164_plano));
select sim.confere('a v_jornada continua lendo a base por subconsulta com OFFSET 0',
  pg_get_viewdef('public.v_jornada'::regclass, true) ~ 'FROM v_jornada_base\s+OFFSET 0\)\s+j', 'sem OFFSET 0');
