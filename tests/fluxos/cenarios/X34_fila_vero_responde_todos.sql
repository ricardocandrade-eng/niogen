-- id: X34
-- titulo: Fila Vero (0300): o número do disparo responde a todo mundo com o WhatsApp da Mari — fora da lista, quem saiu, quem escreve de novo — 1 vez a cada 24 h; "Não tenho interesse" não recebe nada
-- tipo: atual
-- Ricardo, 18/11: "Se o cliente enviar qualquer mensagem pro 28880150, nada acontece. Ele é um número mudo" → "Sim, faça".
select sim.como('servico');
insert into public.fila_vero (nome, telefone, segmento, status, template, wamid, codigo)
values ('Ana X34', '5531999340001', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X34A', 'x34a0001'),
       ('Bia X34', '5531999340002', 'instalado', 'opt_out', 'nio_fv_a1', 'wamid.X34B', 'x34b0002');
select public.fila_vero_webhook(jsonb_build_object('metadata', jsonb_build_object('phone_number_id', '1124589070738034'),
  'messages', jsonb_build_array(
    jsonb_build_object('from', '5531999340009', 'type', 'text', 'text', jsonb_build_object('body', 'Oi, quem é?')),
    jsonb_build_object('from', '5531999340001', 'type', 'text', 'text', jsonb_build_object('body', 'Quero saber mais')),
    jsonb_build_object('from', '5531999340002', 'type', 'text', 'text', jsonb_build_object('body', 'Oi')),
    jsonb_build_object('from', '5531999340008', 'type', 'text', 'text', jsonb_build_object('body', 'Não tenho interesse')))));
select sim.confere('quem está fora da lista entra na fila da resposta avulsa',
  exists (select 1 from public.fila_vero_avulsos where telefone = '5531999340009'), (select string_agg(telefone, ', ') from public.fila_vero_avulsos));
select sim.confere('quem saiu da lista e escreve "Oi" também entra',
  exists (select 1 from public.fila_vero_avulsos where telefone = '5531999340002'), (select string_agg(telefone, ', ') from public.fila_vero_avulsos));
select sim.confere('quem está na lista e escreve pela 1ª vez segue o caminho antigo (link da oferta), sem resposta avulsa',
  not exists (select 1 from public.fila_vero_avulsos where telefone = '5531999340001')
  and exists (select 1 from public.fila_vero_auto_respostas() a where a.telefone = '5531999340001'),
  (select string_agg(telefone, ', ') from public.fila_vero_avulsos));
select sim.confere('"Não tenho interesse" de quem está fora da lista não recebe nada',
  not exists (select 1 from public.fila_vero_avulsos where telefone = '5531999340008'), (select string_agg(telefone, ', ') from public.fila_vero_avulsos));
select sim.confere('mensagem de outro número da Nio é ignorada',
  public.fila_vero_webhook(jsonb_build_object('metadata', jsonb_build_object('phone_number_id', '1342993658907403'),
    'messages', jsonb_build_array(jsonb_build_object('from', '5531999340007', 'type', 'text', 'text', jsonb_build_object('body', 'Oi'))))) ->> 'ignorado' = 'outro número'
  and not exists (select 1 from public.fila_vero_avulsos where telefone = '5531999340007'), 'entrou');
select sim.confere('a rodada monta o texto com o WhatsApp da Mari para os dois',
  (select count(*) from jsonb_array_elements(public.fila_vero_rodada(10) -> 'itens') x
    where x ->> 'id' in ('a:5531999340009', 'a:5531999340002') and x ->> 'tipo' = 'texto' and x ->> 'texto' like '%wa.me/553128881265%') = 2,
  (select string_agg(telefone, ', ') from public.fila_vero_avulsos_pendentes()));
select public.fila_vero_resultado(jsonb_build_array(
  jsonb_build_object('id', 'a:5531999340009', 'tipo', 'texto', 'wamid', 'wamid.X34R1'),
  jsonb_build_object('id', 'a:5531999340002', 'tipo', 'texto', 'wamid', null, 'erro_codigo', '131047', 'erro_msg', 'janela fechada')));
select sim.confere('enviada, sai da fila; falhou, conta a tentativa e tenta de novo',
  (select respondido_em is not null from public.fila_vero_avulsos where telefone = '5531999340009')
  and (select tentativas = 1 and erro like '131047%' from public.fila_vero_avulsos where telefone = '5531999340002')
  and not exists (select 1 from public.fila_vero_avulsos_pendentes() p where p.telefone = '5531999340009')
  and exists (select 1 from public.fila_vero_avulsos_pendentes() p where p.telefone = '5531999340002'),
  (select string_agg(telefone || ' r=' || coalesce(respondido_em::text, '-') || ' t=' || tentativas, ' | ') from public.fila_vero_avulsos));
select public.fila_vero_webhook(jsonb_build_object('metadata', jsonb_build_object('phone_number_id', '1124589070738034'),
  'messages', jsonb_build_array(jsonb_build_object('from', '5531999340009', 'type', 'text', 'text', jsonb_build_object('body', 'Alô?')))));
select sim.confere('quem já recebeu e escreve de novo antes de 24 h não recebe outra vez',
  not exists (select 1 from public.fila_vero_avulsos_pendentes() p where p.telefone = '5531999340009'), 'recebeu de novo');
update public.fila_vero_avulsos set respondido_em = now() - interval '25 hours' where telefone = '5531999340009';
select sim.confere('depois de 24 h, a nova mensagem recebe a resposta de novo',
  exists (select 1 from public.fila_vero_avulsos_pendentes() p where p.telefone = '5531999340009'), 'não recebeu');
select public.fila_vero_resultado(jsonb_build_array(
  jsonb_build_object('id', 'a:5531999340002', 'tipo', 'texto', 'wamid', null, 'erro_codigo', '131047'),
  jsonb_build_object('id', 'a:5531999340002', 'tipo', 'texto', 'wamid', null, 'erro_codigo', '131047')));
select sim.confere('3 falhas seguidas: para de tentar',
  not exists (select 1 from public.fila_vero_avulsos_pendentes() p where p.telefone = '5531999340002'), 'continuou tentando');
-- quem está na lista, já recebeu o link da oferta e escreve de novo → agora recebe a resposta avulsa
select public.fila_vero_auto_respondida(id) from public.fila_vero where telefone = '5531999340001';
select public.fila_vero_webhook(jsonb_build_object('metadata', jsonb_build_object('phone_number_id', '1124589070738034'),
  'messages', jsonb_build_array(jsonb_build_object('from', '5531999340001', 'type', 'text', 'context', jsonb_build_object('id', 'wamid.X34A'),
                                                   'text', jsonb_build_object('body', 'E aí?')))));
select sim.confere('quem já recebeu o link da oferta e escreve de novo recebe o WhatsApp da Mari',
  exists (select 1 from public.fila_vero_avulsos_pendentes() p where p.telefone = '5531999340001')
  and (select fila_id is not null from public.fila_vero_avulsos where telefone = '5531999340001'), 'ficou mudo');
select public.fila_vero_webhook(jsonb_build_object('metadata', jsonb_build_object('phone_number_id', '1124589070738034'),
  'messages', jsonb_build_array(jsonb_build_object('from', '5531999340001', 'type', 'button', 'button', jsonb_build_object('text', 'Não tenho interesse')))));
select sim.confere('o botão "Não tenho interesse" de quem está na lista continua tirando da lista',
  (select status = 'opt_out' from public.fila_vero where telefone = '5531999340001'),
  (select status from public.fila_vero where telefone = '5531999340001'));
