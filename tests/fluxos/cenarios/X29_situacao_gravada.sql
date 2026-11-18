-- id: X29
-- titulo: Fase 2, passo 2 (0293): a situação fica GRAVADA a cada evento da porta — entra, passa ao time, sai e volta, sempre igual à calculada
-- tipo: atual
-- A situação era só calculada (v_lead_situacao). Agora todo evento da porta grava, no fim da transação, a situação do lead em
-- lead_estado; v_lead_estado_divergencias lista o que mudou sem passar pela porta.
select sim.lead_novo('Gil X29') as c \gset
select sim.confere('lead novo já tem a situação gravada (Mari atendendo)',
  (select situacao from public.lead_estado where conversa_id = :'c') = 'mari_atendendo',
  coalesce((select situacao || ' · ' || coalesce(evento, '-') from public.lead_estado where conversa_id = :'c'), 'nada gravado'));
select sim.mari_handoff(:'c', 'pedido_humano');
select sim.fila_rodar();
select sim.confere('passou ao time: a gravada acompanha (Com o time)',
  (select situacao from public.lead_estado where conversa_id = :'c') = (select situacao from public.v_lead_situacao where conversa_id = :'c'),
  (select e.situacao || ' gravada × ' || l.situacao || ' calculada · ' || coalesce(e.evento, '-')
     from public.v_lead_situacao l left join public.lead_estado e on e.lead_id = l.lead_id where l.conversa_id = :'c'));
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.confere('Saída: gravada = Saída pode voltar, com o evento da Saída',
  (select situacao = 'saida_pode_voltar' and evento like 'saida:%' from public.lead_estado where conversa_id = :'c'),
  (select situacao || ' · ' || coalesce(evento, '-') from public.lead_estado where conversa_id = :'c'));
select sim.cliente_escreve(:'c', 'pensei melhor, quero sim');
select sim.fila_rodar();
select sim.confere('o cliente voltou: a gravada voltou junto',
  (select situacao from public.lead_estado where conversa_id = :'c') = (select situacao from public.v_lead_situacao where conversa_id = :'c'),
  (select e.situacao || ' gravada × ' || l.situacao || ' calculada · ' || coalesce(e.evento, '-')
     from public.v_lead_situacao l left join public.lead_estado e on e.lead_id = l.lead_id where l.conversa_id = :'c'));
select sim.confere('nenhuma divergência para este lead',
  not exists (select 1 from public.v_lead_estado_divergencias where conversa_id = :'c'),
  (select string_agg(coalesce(gravada, '-') || ' × ' || calculada, ' · ') from public.v_lead_estado_divergencias where conversa_id = :'c'));
-- (a cópia roda como superusuário, sem RLS: "só a porta grava" não se testa aqui — vale pela política da tabela)
