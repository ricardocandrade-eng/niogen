-- id: X131
-- titulo: 0401 (caso L-377): quando a Mari aciona o time por urgência (pressa na instalação, ameaça de desistir), o lead entra em 1º na fila da Live 2.0 — "Venda em risco", urgência 5, na frente de quem já esperava — e sai dessa regra quando uma pessoa responde; live2_resgates mede em quantos minutos responderam
-- tipo: atual
-- um lead que já está na fila com o cliente esperando (urgência 4): o risco tem de passar na frente dele
select sim.lead_novo('Bia X131') as b \gset
select sim.mari_handoff(:'b', 'pedido_humano');
select sim.fila_rodar();
select sim.lead_novo('Caio X131') as c \gset

-- 1) antes de a Mari acionar o time, ninguém está marcado como venda em risco
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('antes do handoff de urgência, nenhuma venda em risco',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where (x ->> 'risco')::boolean)
  and ((:'f')::jsonb -> 'conta' ->> 'em_risco')::int = 0, left((:'f')::jsonb ->> 'conta', 300));

-- 2) a Mari aciona o time por urgência (o 7 · Extrair grava dados.risco_venda e chama mari_handoff)
select sim.como('servico');
update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || '{"risco_venda": "pressa"}'::jsonb where id = :'c';
select sim.mari_handoff(:'c', 'urgencia_alta');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce(((:'f')::jsonb -> 'fila' -> 0)::text, '{}') as l1 \gset
select sim.confere('a venda em risco é a 1ª da fila, na frente de quem já esperava',
  (:'l1')::jsonb ->> 'conversa_id' = :'c' and jsonb_array_length((:'f')::jsonb -> 'fila') >= 2, left(:'l1', 300));
select sim.confere('urgência 5, tipo Responder e o texto "Venda em risco"',
  ((:'l1')::jsonb ->> 'risco')::boolean and ((:'l1')::jsonb ->> 'urg')::int = 5 and (:'l1')::jsonb ->> 'tipo' = 'responder'
  and (:'l1')::jsonb ->> 'oque' like 'Venda em risco · o cliente quer a instalação para já%', left(:'l1', 400));
select sim.confere('a conta diz quantas vendas estão em risco', ((:'f')::jsonb -> 'conta' ->> 'em_risco')::int = 1, (:'f')::jsonb ->> 'conta');
select sim.confere('o outro lead continua na fila, sem a marca de risco',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'b' and not (x ->> 'risco')::boolean), 'lead Bia');

-- 3) a medição enxerga o resgate ainda sem resposta
select public.live2_resgates(30)::text as m \gset
select coalesce((select x::text from jsonb_array_elements((:'m')::jsonb -> 'lista') x where x ->> 'conversa_id' = :'c'), '{}') as r1 \gset
select sim.confere('o resgate aparece na medição, ainda sem resposta',
  (:'r1')::jsonb ->> 'tipo' = 'pressa' and (:'r1')::jsonb ->> 'minutos' is null and ((:'m')::jsonb ->> 'sem_resposta')::int >= 1, left(:'m', 300));

-- 4) uma pessoa responde: deixa de ser "em risco" e a medição marca os minutos
select public.backoffice_responder(:'c', 'Oi, Caio! Vou tentar encaixar a sua instalação pra hoje.');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('respondido, o lead sai da regra do risco',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'c' and (x ->> 'risco')::boolean)
  and ((:'f')::jsonb -> 'conta' ->> 'em_risco')::int = 0, (:'f')::jsonb ->> 'conta');
select public.live2_resgates(30)::text as m \gset
select coalesce((select x::text from jsonb_array_elements((:'m')::jsonb -> 'lista') x where x ->> 'conversa_id' = :'c'), '{}') as r2 \gset
select sim.confere('a medição marca em quantos minutos a pessoa respondeu',
  ((:'r2')::jsonb ->> 'minutos')::int between 0 and 5 and ((:'m')::jsonb ->> 'ate_5min')::int >= 1 and (:'r2')::jsonb ->> 'deu' = 'em_andamento', left(:'m', 300));

-- 5) as falas da Mari ficam na configuração (trocáveis sem deploy)
select sim.confere('as duas falas estão em config_mari_textos',
  (select count(*) from public.config_mari_textos where chave in ('risco_pressa_fala', 'risco_desiste_fala') and texto like '%atendente%{prazo}%') = 2, 'config_mari_textos');
