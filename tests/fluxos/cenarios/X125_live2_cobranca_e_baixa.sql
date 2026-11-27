-- id: X125
-- titulo: 0394 (caso L-153): na Live 2.0, tarefa que é do cliente (biometria pendente) vira "Cobrar o cliente" — sem o botão da etapa, com Falar/Ligar/Já cobrei; o time falou → a cobrança sai sozinha e o lead fica "em pausa" com hora de volta; o cliente escreveu → volta; "Já cobrei" e "Adiar" dão baixa com teto de 7 dias; 7 dias sem sinal → Decidir; a conta continua fechando
-- tipo: atual
select sim.lead_com_venda('Bruno X125') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
-- o GED360 leu "LINK ENVIADO": a biometria é do cliente
select sim._servico();
insert into public.nio_biometria (protocolo, cpf_cnpj, resultado, venda_id, ultima_leitura)
values ('X125-' || sim._conv(:'c'), '00000000000', 'LINK ENVIADO', sim.venda(:'c'), now());
update public.vendas set biometria_status = 'pendente', biometria_link_enviado_em = now() where id = sim.venda(:'c');
select sim.fila_rodar();

-- 1) 30 h depois e ninguém cobrou: aparece como cobrança
select sim.como('servico');
select sim.passa(:'c', '30 hours');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as l1 \gset
select sim.confere('biometria pendente há 30 h → linha de cobrança, tipo Ligar',
  ((:'l1')::jsonb ->> 'cobranca')::boolean and (:'l1')::jsonb ->> 'tipo' = 'ligar' and (:'l1')::jsonb ->> 'oque' like 'Cobrar o cliente%', left(:'l1', 400));
select sim.confere('os botões são Falar com o cliente e Já cobrei — sem o botão "Biometria"',
  exists (select 1 from jsonb_array_elements((:'l1')::jsonb -> 'acoes') y where y ->> 'a' = 'abrir' and (y ->> 'principal')::boolean and y ->> 'rotulo' = 'Falar com o cliente')
  and exists (select 1 from jsonb_array_elements((:'l1')::jsonb -> 'acoes') y where y ->> 'fn' = 'live2_baixa')
  and not exists (select 1 from jsonb_array_elements((:'l1')::jsonb -> 'acoes') y where y ->> 'rotulo' = 'Biometria'), (:'l1')::jsonb ->> 'acoes');
select sim.confere('cobrança nunca vale urgência "agora" (3) nem "cliente esperando" (4)', ((:'l1')::jsonb ->> 'urg')::int <= 2, (:'l1')::jsonb ->> 'urg');

-- 2) o cliente dá sinal, o time fala com ele: a cobrança sai sozinha e o lead fica em pausa, com hora de volta
select sim.como('servico');
select sim.cliente_escreve(:'c', 'Oi, ainda não consegui fazer', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Bruno! Conseguiu fazer a biometria pelo link da Nio?');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('o time falou → a cobrança sai da fila',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text and (x ->> 'cobranca')::boolean),
  coalesce((select x ->> 'oque' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), 'fora'));
select exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text) as resta \gset
select sim.confere('fora da fila, o lead está no Radar "em pausa" com a hora de volta',
  :'resta'::boolean or exists (select 1 from jsonb_array_elements((:'f')::jsonb #> '{radar,em_pausa}') x
                                where x ->> 'k' = sim.venda(:'c')::text and (x ->> 'volta_em')::timestamptz > now()),
  (:'f')::jsonb #>> '{radar,em_pausa}');
select sim.confere('a conta fecha com o "em pausa"',
  ((:'f')::jsonb #>> '{conta,vivos}')::int = ((:'f')::jsonb #>> '{conta,na_fila}')::int + ((:'f')::jsonb #>> '{conta,em_pausa}')::int
     + ((:'f')::jsonb #>> '{conta,com_mari}')::int + ((:'f')::jsonb #>> '{conta,esperando_cliente}')::int
     + ((:'f')::jsonb #>> '{conta,esperando_nio}')::int + ((:'f')::jsonb #>> '{conta,sem_lugar}')::int
  and ((:'f')::jsonb #>> '{conta,sem_lugar}')::int = 0, (:'f')::jsonb ->> 'conta');

-- 3) passam 25 h sem o cliente responder: a cobrança volta, agora com peso menor (já foi cobrado)
select sim.como('servico');
select sim.passa(:'c', '25 hours');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text and (x ->> 'cobranca')::boolean), '{}') as l3 \gset
select sim.confere('25 h depois sem resposta → a cobrança volta', (:'l3')::jsonb ->> 'tipo' = 'ligar', left(:'l3', 300));
select sim.confere('já cobrado uma vez → urgência 1', ((:'l3')::jsonb ->> 'urg')::int = 1, (:'l3')::jsonb ->> 'urg');

-- 4) "Já cobrei" (ligou por fora): baixa de 24 h; fora do backoffice recusa; chave inválida recusa
select public.live2_baixa(sim.venda(:'c')::text, 'cobrei') ->> 'resumo' as r4 \gset
select sim.confere('Já cobrei devolve o resumo com a hora da volta', :'r4' like '✓ Cobrança registrada%', :'r4');
select public.live2_fila()::text as f \gset
select sim.confere('com a baixa, a cobrança sai da fila',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text and (x ->> 'cobranca')::boolean), 'continua na fila');
select sim.confere('chave que não é de cliente é recusada', sim.recusa($$select public.live2_baixa('p:casar_pedido:1', 'cobrei')$$) is not null, 'aceitou');
select sim.confere('o teto é de 30 dias, mesmo pedindo mais (0429, Ricardo 27/11: era 7)',
  ((public.live2_baixa(sim.venda(:'c')::text, 'agora_nao', 9999) ->> 'ate')::timestamptz) <= now() + interval '30 days 1 minute', 'passou do teto');
select sim.como('servico');
select sim.confere('fora do backoffice/admin a baixa é recusada',
  sim.recusa(format($q$select public.live2_baixa(%L, 'cobrei')$q$, sim.venda(:'c')::text)) is not null, 'aceitou');

-- 5) o cliente escreve: a baixa cai na hora (a conversa volta a pedir alguém)
select sim.cliente_escreve(:'c', 'Oi, não achei o link da biometria', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('cliente escreveu → o lead está de volta na fila, apesar da baixa de 7 dias',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text),
  (:'f')::jsonb #>> '{radar,em_pausa}');

-- 6) 8 dias sem sinal do cliente: a cobrança vira Decidir (combinar data ou Saída) e pode ser adiada
select public.backoffice_responder(:'c', 'Bruno, mandei de novo o link. Qualquer coisa me chama.');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c', '8 days');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text and (x ->> 'cobranca')::boolean), '{}') as l6 \gset
select sim.confere('8 dias sem sinal → Decidir, com o número de dias no texto',
  (:'l6')::jsonb ->> 'tipo' = 'decidir' and (:'l6')::jsonb ->> 'oque' like 'Sem resposta do cliente há 8 dias%', left(:'l6', 300));
select sim.confere('a linha de venda pode ser adiada pela pausa (não tem "Em espera" de conversa)',
  ((:'l6')::jsonb ->> 'pode_pausar')::boolean and not ((:'l6')::jsonb ->> 'pode_adiar')::boolean, (:'l6')::jsonb ->> 'pode_pausar');
