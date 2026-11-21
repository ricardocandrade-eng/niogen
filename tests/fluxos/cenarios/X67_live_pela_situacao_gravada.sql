-- id: X67
-- titulo: Fase 2, passo 4b (d) (0342): a Live lê a situação gravada pela porta — o lead com a vez do time aparece com o nome da situação, o texto e o botão dela; o da Mari não tem a vez do time; quem não é do backoffice não lê
-- tipo: atual
-- Debate da Live com o Ricardo (21/11): Para fazer = vez do time na situação gravada (+ os alarmes da v_jornada); coluna = as 15
-- situações; texto e botão da situação.
select sim.lead_novo('Iara X67') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Bom dia, Iara! Vamos dar continuidade?');
select sim.fila_rodar();
select sim.cliente_escreve(:'c', 'oi, pode sim') as r \gset
select sim.fila_rodar();

-- a Live (backoffice) lê a situação gravada desta conversa
select sim.como('backoffice');
select coalesce((select e from jsonb_array_elements(public.live_situacoes()) e where e ->> 'conversa_id' = :'c'), '{}'::jsonb)::text as l1 \gset
select sim.confere('o cliente escreveu: a Live lê a vez do time na situação gravada',
  :'l1'::jsonb ->> 'situacao' = 'time_agora' and :'l1'::jsonb ->> 'vez' = 'time', :'l1');
select sim.confere('a linha traz o nome da situação, o texto e o botão',
  :'l1'::jsonb ->> 'nome' = 'Com o time — responder agora' and :'l1'::jsonb ->> 'o_que_fazer' = 'Responder o cliente'
  and :'l1'::jsonb ->> 'botao' = 'responder', :'l1');
select sim.como('servico');
select sim.confere('o que a Live lê é o que a porta gravou (lead_estado = situação de agora)',
  (select situacao from public.v_lead_situacao where conversa_id = :'c') = :'l1'::jsonb ->> 'situacao',
  (select situacao from public.v_lead_situacao where conversa_id = :'c'));

-- lead com a Mari: a vez não é do time
select sim.lead_novo('Davi X67') as c2 \gset
select sim.mari_fala(:'c2', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select coalesce((select e from jsonb_array_elements(public.live_situacoes()) e where e ->> 'conversa_id' = :'c2'), '{}'::jsonb)::text as l2 \gset
select sim.confere('lead com a Mari: situação "Mari atendendo", a vez não é do time',
  :'l2'::jsonb ->> 'situacao' = 'mari_atendendo' and coalesce(:'l2'::jsonb ->> 'vez', '') <> 'time', :'l2');

-- vendedor não lê a situação de todos os leads
select sim.como('vendedor');
select sim.confere('vendedor: a leitura da Live vem vazia', jsonb_array_length(public.live_situacoes()) = 0, public.live_situacoes()::text);
select sim.como('servico');
select sim.confere('as 15 situações têm texto e botão', not exists (select 1 from public.config_situacao where o_que_fazer is null or botao is null),
  (select string_agg(codigo, ', ') from public.config_situacao where o_que_fazer is null or botao is null));
