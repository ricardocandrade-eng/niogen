-- id: X37
-- titulo: Varredura da base instalada (0303): instalado há 60 dias recebe 1 pedido de indicação pelo template (só depois de a Meta aprovar); a resposta com um WhatsApp vira indicação, sem acender o pós-venda; não pede de novo dentro de 60 dias
-- tipo: atual
select sim.venda_pronta('Rui X37') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '87' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.passa(:'c', '2 days');
select sim.instalou(:'c');
select sim.espera(:'c', '90 minutes');
select sim.cliente_escreve(:'c', 'Deu tudo certo sim, obrigado!') as r0 \gset
select sim.fila_rodar();
select sim.passa(:'c', '61 days');

select sim.como('servico');
select count(*) as antes from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'template' = 'nio_indicacao_base' \gset
-- template ainda não aprovado: nada sai
select count(*) from public.indicacao_tick(sim.hora('10:00'));
select sim.confere('sem o template aprovado pela Meta, a varredura não manda nada',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'template' = 'nio_indicacao_base') = :antes, '');
update public.config_templates_waba set status = 'APPROVED' where nome = 'nio_indicacao_base';
select count(*) from public.indicacao_tick(sim.hora('10:00'));
select sim.fila_rodar();
select sim.confere('instalado há 61 dias: sai 1 pedido de indicação pelo template',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'template' = 'nio_indicacao_base') = :antes + 1
  and exists (select 1 from public.indicacao_pedidos p where p.conversa_id = :'c' and p.motivo = 'varredura' and p.estado = 'pediu'),
  (select string_agg(p.estado, ', ') from public.indicacao_pedidos p where p.conversa_id = :'c'));
select count(*) from public.indicacao_tick(sim.hora('11:00'));
select sim.confere('não repete o pedido na volta seguinte da rotina',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'template' = 'nio_indicacao_base') = :antes + 1, '');

-- ele responde com o contato
select sim.passa(:'c', '1 hour');
select count(*) as pv from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'pos_venda' \gset
select sim.cliente_escreve(:'c', 'Indico o Pedro, 32 99911-2233') as r1 \gset
select sim.fila_rodar();
select sim.confere('a indicação foi anotada com a venda de quem indicou',
  exists (select 1 from public.indicacoes i where i.indicador_venda_id = sim.venda(:'c') and i.tel_chave = '3299112233'), '');
select sim.confere('ele recebeu o "Anotado, obrigada!"',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'texto_chave' = 'indicacao_obrigado'
            and a.criada_em > now() - interval '30 minutes'), '');
select sim.confere('a automação respondeu: o pós-venda do time não acende',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'pos_venda') = :pv, '');
select sim.confere('o pedido virou "recebeu"',
  (select estado from public.indicacao_pedidos p where p.conversa_id = :'c' and p.motivo = 'varredura') = 'recebeu', '');
