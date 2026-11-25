-- id: X121
-- titulo: 0390 (Live 2.0, passo 1): a conta fecha (todo lead vivo está em um lugar só: na fila, com a Mari, esperando o cliente ou esperando a Nio — nenhum sem lugar) e a conferência de cobertura grava furo quando um cliente espera resposta fora da fila, e fecha o furo quando ele é atendido
-- tipo: atual
select sim.como('servico');
update public.config_regras set valor = valor || '{"hora_ini":0,"hora_fim":24}'::jsonb where chave = 'live2_pesos';   -- o portão roda a qualquer hora
select sim.lead_novo('Dora X121') as d \gset
select sim.mari_fala(:'d', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.venda_pronta('Eli X121', true) as e \gset
select sim.fila_rodar();

-- 1) a conta fecha
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('vivos = na fila + em pausa + com a Mari + esperando o cliente + esperando a Nio + sem lugar',
  ((:'f')::jsonb #>> '{conta,vivos}')::int = ((:'f')::jsonb #>> '{conta,na_fila}')::int + coalesce(((:'f')::jsonb #>> '{conta,em_pausa}')::int, 0) + ((:'f')::jsonb #>> '{conta,com_mari}')::int
     + ((:'f')::jsonb #>> '{conta,esperando_cliente}')::int + ((:'f')::jsonb #>> '{conta,esperando_nio}')::int + ((:'f')::jsonb #>> '{conta,sem_lugar}')::int,
  (:'f')::jsonb ->> 'conta');
select sim.confere('nenhum lead vivo sem lugar', ((:'f')::jsonb #>> '{conta,sem_lugar}')::int = 0, (:'f')::jsonb #>> '{radar,sem_lugar}');
select sim.confere('os leads novos estão contados entre os vivos',
  ((:'f')::jsonb #>> '{conta,vivos}')::int = (select count(distinct coalesce(j.venda_id::text, 'c:' || j.conversa_id::text)) from public.v_jornada j where j.caixa between 1 and 5),
  (:'f')::jsonb #>> '{conta,vivos}');

-- 2) cobertura: sem ninguém esperando fora da fila, zero furo
select public.live2_cobertura_conferir()::text as c0 \gset
select sim.confere('conferência roda e não acha furo', jsonb_array_length((:'c0')::jsonb -> 'furos') = 0, :'c0');
select sim.confere('a fila mostra quando foi a última conferência', (public.live2_fila() #>> '{cobertura,rodada_em}') is not null, 'sem carimbo');

-- 3) furo: o cliente escreve, a Mari não responde e a conversa não está na fila de ninguém
select sim.como('servico');
select sim.cliente_escreve(:'d', 'Alguém aí? Quero fechar hoje', false);
select sim.passa(:'d', '15 minutes');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'d') as na_fila \gset
select public.live2_cobertura_conferir()::text as c1 \gset
select sim.confere('cliente esperando há 15 min: ou está na fila, ou virou furo (nunca em silêncio)',
  :'na_fila'::boolean or exists (select 1 from jsonb_array_elements((:'c1')::jsonb -> 'furos') x where x ->> 'conversa_id' = :'d'),
  'na fila: ' || :'na_fila' || ' · ' || :'c1');
select sim.confere('e o furo fica gravado enquanto ele espera fora da fila',
  :'na_fila'::boolean or exists (select 1 from public.live2_furos f where f.conversa_id = :'d' and f.fechado_em is null), 'sem linha em live2_furos');

-- 4) alguém responde: o furo fecha
select sim.como('servico');
select sim.mari_fala(:'d', 'Oi! Estou aqui. Me passa o seu CEP?');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_cobertura_conferir()::text as c2 \gset
select sim.confere('respondido, o furo fecha',
  not exists (select 1 from public.live2_furos f where f.conversa_id = :'d' and f.fechado_em is null), :'c2');

-- 5) só o backoffice confere
select sim.como('servico');
select sim.confere('fora do backoffice/admin a conferência recusa', sim.recusa($$select public.live2_cobertura_conferir()$$) is not null, 'aceitou');
