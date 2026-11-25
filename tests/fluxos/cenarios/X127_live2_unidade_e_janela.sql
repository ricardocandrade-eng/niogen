-- id: X127
-- titulo: 0396 (caso L-275): na Live 2.0, "Unidade a confirmar" manda na linha (é o que trava a venda) e o passo da venda fica nos motivos, sem o texto genérico da situação; com a janela de 24 h fechada o tipo vira Ligar e os botões da ligação aparecem, mesmo que o time tenha falado há menos de 24 h (a fala foi antes de a janela fechar)
-- tipo: atual
select sim.lead_com_venda('Uli X127') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim._servico();
update public.mari_conversas set unidade_conferir_em = now() where id = :'c';

-- 1) unidade a confirmar manda na linha
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as l1 \gset
select sim.confere('a linha é a da unidade a confirmar', (:'l1')::jsonb ->> 'fonte' = 'conferir' and (:'l1')::jsonb ->> 'sub' = 'conferir_unidade', left(:'l1', 300));
select sim.confere('o botão principal abre o cliente e o passo da venda fica nos motivos',
  exists (select 1 from jsonb_array_elements((:'l1')::jsonb -> 'acoes') y where y ->> 'a' = 'abrir' and (y ->> 'principal')::boolean)
  and exists (select 1 from jsonb_array_elements_text((:'l1')::jsonb -> 'motivos') m where m like 'Crédito aprovado%'), (:'l1')::jsonb ->> 'motivos');
select sim.confere('a urgência e os pontos são os do aviso mais urgente do lead',
  ((:'l1')::jsonb ->> 'pontos')::numeric = round(((:'l1')::jsonb ->> 'vale')::numeric * ((:'l1')::jsonb ->> 'pe')::numeric * ((:'l1')::jsonb ->> 'pu')::numeric)
  and ((:'l1')::jsonb ->> 'urg')::int >= 2, (:'l1')::jsonb ->> 'urg');
select sim.confere('o motivo genérico da situação ("Rodar o crédito no portal") não aparece: a jornada já diz o passo',
  not exists (select 1 from jsonb_array_elements_text((:'l1')::jsonb -> 'motivos') m where m = 'Rodar o crédito no portal'), (:'l1')::jsonb ->> 'motivos');

-- 2) o cliente escreve, o time responde 2 h depois, e 23 h passam: janela fechada, com fala do time há menos de 24 h
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Moro no bloco 8', false);
select sim.fila_rodar();
select sim.passa(:'c', '2 hours');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Uli, o portal não mostra o bloco 8. Qual o número do apartamento?');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c', '23 hours');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as l2 \gset
select sim.confere('janela fechada entra na linha, apesar de o time ter falado há 23 h',
  (:'l2')::jsonb -> 'fontes' ? 'conferir:janela_fechada', (:'l2')::jsonb ->> 'fontes');
select sim.confere('o tipo vira Ligar e os botões da ligação aparecem',
  (:'l2')::jsonb ->> 'tipo' = 'ligar' and exists (select 1 from jsonb_array_elements((:'l2')::jsonb -> 'acoes') y where y ->> 'rotulo' in ('Atendeu', 'Não atendeu')),
  ((:'l2')::jsonb ->> 'tipo') || ' · ' || ((:'l2')::jsonb ->> 'acoes'));
