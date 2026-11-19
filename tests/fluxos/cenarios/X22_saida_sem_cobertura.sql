-- id: X22
-- titulo: Saída "Fachada não atendida": o cliente é avisado; quando volta a escrever a venda não reabre, a Mari não promete nada e quem insiste vai ao time
-- tipo: atual
select sim.lead_com_venda('Feli X22') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'viabilidade', '{"resultado":"sem_viabilidade"}');
select public.lead_sair(:'c', null, 'fachada_nao_atendida');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o cliente recebeu o aviso de que a Nio não chega no endereço',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' in ('saida_sem_cobertura', 'saida_sem_cobertura_indicacao')) = 1, '');

-- no dia seguinte ele pergunta pela instalação
select sim.passa(:'c', '1 day');
select sim.cliente_escreve(:'c', 'Vou ter internet esta semana?') as r1 \gset
select sim.fila_rodar();
select sim.confere('a Mari não responde (não promete instalação)', :'r1' like 'calada%', :'r1');
select sim.confere('a venda continua em Saída', (select status = 'saida' from public.vendas where id = sim.venda(:'c')), '');
select sim.confere('o lead continua em Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.confere('ele recebe a resposta honesta (a Nio ainda não chega no endereço)',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' in ('saida_sem_cobertura', 'saida_sem_cobertura_indicacao')) = 2, '');
select sim.confere('lead em Saída não vira oportunidade na Live',
  not exists (select 1 from public.v_oportunidades o where o.conversa_id = :'c'), '');

-- ele manda o CEP de outro endereço: pode ser venda → com o time, conversa aberta
select sim.passa(:'c', '1 day');
select sim.cliente_escreve(:'c', 'E no CEP 32800-000, número 15?') as r2 \gset
select sim.fila_rodar();
select sim.confere('com o CEP novo a Mari também não responde', :'r2' like 'calada%', :'r2');
select sim.confere('o CEP novo fica com o time',
  exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'sistema' and t.texto like '%mandou um CEP%com o time%'), '');
-- o time confere o endereço novo e reabre (a viabilidade nova se grava com o lead já em andamento)
select sim.como('backoffice');
select public.lead_reabrir(:'c', null::uuid);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('reaberto pelo time, a venda volta', (select status <> 'saida' from public.vendas where id = sim.venda(:'c')), '');

-- Saída desliga o "👀 Acompanhar" (caso souzalucimar: em Saída e ainda no Na mira)
select sim.lead_novo('Luci X22') as c2 \gset
select sim.como('admin');
select public.conversa_acompanhar(:'c2', true);
select public.lead_sair(:'c2', null, 'sem_resposta');
select sim.fila_rodar();
select sim.confere('em Saída, sai do Na mira', not exists (select 1 from jsonb_array_elements(public.live_na_mira()) x where x ->> 'conversa_id' = :'c2'), '');
select sim.como('servico');
