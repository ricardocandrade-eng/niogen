-- id: X26
-- titulo: Porta, peça 2 (0288): venda mudada pelo robô da Nio, Mover do admin, Quadro "Encerrada" e "Sou cliente Nio" passam pela porta
-- tipo: atual
-- (1) robô da Nio põe a venda em Saída (biometria reprovada) com o time dono da conversa
select sim.lead_com_venda('Edu X26') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim._servico();
select set_config('niogen.transicao_ok', 'robo', false);
update public.vendas set status = 'saida', motivo_saida = 'Biometria reprovada' where id = sim.venda(:'c');
select set_config('niogen.transicao_ok', '', false);
select sim.fila_rodar();
select sim.confere('robô pôs a venda em Saída: a conversa vai para o destino do motivo', sim.foto(:'c') ->> 'destino' = 'reprovado_biometria', sim.foto(:'c')::text);
select sim.confere('robô pôs a venda em Saída: ninguém fica com a conversa', sim.cw_de(:'c') ->> 'agente' is null, sim.cw_de(:'c')::text);
select sim.confere('a porta anotou a mudança (vendas_porta)',
  exists (select 1 from public.porta_sombra s where s.conversa_id = :'c' and s.origem = 'vendas_porta' and s.evento = 'funil:reprovado_biometria'));

-- (2) robô tira a venda da Saída: volta a "em andamento"
select set_config('niogen.transicao_ok', 'robo', false);
update public.vendas set status = '0_qualificado', motivo_saida = null where id = sim.venda(:'c');
select set_config('niogen.transicao_ok', '', false);
select sim.fila_rodar();
select sim.confere('saiu da Saída: a conversa volta a em andamento', sim.foto(:'c') ->> 'destino' = 'em_andamento', sim.foto(:'c')::text);

-- (3) Mover do admin pela porta: uma venda com OS gravada volta para Qualificado
select sim.lead_com_venda('Ivo X26') as c4 \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c4'), 'credito', '{"resultado":"aprovado"}');
select public.backoffice_momento(sim.venda(:'c4'), 'biometria', '{"resultado":"validada"}');
select public.backoffice_momento(sim.venda(:'c4'), 'os', jsonb_build_object('os', '97' || sim._conv(:'c4'), 'forma', 'boleto'));
select sim.fila_rodar();
select sim.foto(:'c4') -> 'venda' ->> 'status' as st0 \gset
select sim.como('admin');
select coalesce(sim.recusa(format($q$select public.porta('mover_admin:0_qualificado', null, %L, '{"motivo":"teste do mover"}')$q$, sim.venda(:'c4'))), '') as e3 \gset
select sim.confere('porta(mover_admin) executa', :'e3' = '', coalesce(nullif(:'e3', ''), 'ok'));
select sim.confere('a venda foi movida', sim.foto(:'c4') -> 'venda' ->> 'status' = '0_qualificado', :'st0' || ' → ' || (sim.foto(:'c4') -> 'venda')::text);
select sim.confere('o Mover ficou no histórico', exists (select 1 from public.eventos_venda e where e.venda_id = sim.venda(:'c4') and e.tipo = 'movida_admin'));

-- (4) Quadro da tela Mari: "Encerrada · Perdida" = a Saída da conversa da porta
select sim.lead_novo('Lia X26') as c2 \gset
select sim.mari_fala(:'c2', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.mari_quadro_mover(:'c2', 'encerrada', 'perdida') ->> 'ok' as q \gset
select sim.fila_rodar();
select sim.confere('Quadro Encerrada responde ok', :'q' = 'true', :'q');
select sim.confere('Quadro Encerrada: Saída Recusou pela porta (anotada como silenciar:perdida)',
  exists (select 1 from public.porta_sombra s where s.conversa_id = :'c2' and s.evento = 'silenciar:perdida' and s.concorda));
select sim.confere('Quadro Encerrada: destino recusou e conversa resolvida no Chatwoot',
  sim.foto(:'c2') ->> 'destino' = 'recusou' and sim.cw_de(:'c2') ->> 'status' = 'resolved', sim.foto(:'c2')::text);

-- (5) abertura "Sou cliente Nio": a Saída Já é cliente Nio pela porta, sem erro
select sim.lead_novo('Rita X26') as c3 \gset
select sim._servico();
update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || '{"abertura_botao":"cliente"}' where id = :'c3';
select sim.fila_rodar();
select sim.confere('Sou cliente Nio: destino já cliente Nio', sim.foto(:'c3') ->> 'destino' = 'ja_cliente_nio', sim.foto(:'c3')::text);
select sim.confere('Sou cliente Nio: nenhum erro', not exists (select 1 from public.mari_erros e where e.conversa_id = :'c3' and e.no_n8n = '_abertura_cliente_depois'));
