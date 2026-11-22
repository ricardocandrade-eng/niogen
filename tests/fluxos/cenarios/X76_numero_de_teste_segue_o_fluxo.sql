-- id: X76
-- titulo: Telefone de teste segue o fluxo de venda (0350) — a fala da Mari não resolve a conversa só por ser "teste ou duplicada", e o #zerar não deixa conversas antigas presas no mesmo Chatwoot
-- tipo: atual
-- Caso do teste real do Ricardo (21/11 22h01–22h08, L-236, Chatwoot #1): a conversa foi resolvida a cada fala da Mari e, no handoff,
-- 14 linhas antigas do mesmo #1 voltaram para a Mari e tiraram o time.
insert into public.config_mari_textos (chave, texto) values ('telefones_teste', '5531999990076')
  on conflict (chave) do update set texto = coalesce(public.config_mari_textos.texto, '') || ',5531999990076';
select sim.lead_novo('Tito X76', 'Oi', '5531999990076') as c \gset
select sim.fila_rodar();
select sim._conv(:'c') as cw \gset
select sim.confere('telefone de teste fica em "Teste ou duplicada" (fora das contas, como sempre)',
  (select funil_destino from public.mari_conversas where id = :'c') = 'teste_duplicada',
  (select funil_destino from public.mari_conversas where id = :'c'));

-- (1) a Mari responde: nada manda resolver a conversa
select sim.cw_mudar(:'cw', '{"status":"open"}', 'cliente');
select max(id) as base from public.chatwoot_acoes \gset
insert into public.mari_turnos (conversa_id, papel, texto) values (:'c', 'mari', 'Me manda seu CEP?');
select sim.confere('fala da Mari com telefone de teste não pede para resolver a conversa',
  not exists (select 1 from public.chatwoot_acoes where id > :base and conversa_id = :'c' and tipo = 'resolver'),
  (select string_agg(momento || ':' || tipo, ' ') from public.chatwoot_acoes where id > :base and conversa_id = :'c'));

-- (2) #zerar e o cliente escreve de novo no mesmo Chatwoot: a conversa antiga sai do Chatwoot, fica só a nova
select public.mari_zerar_memoria('5531999990076', :'cw');
select sim.fila_rodar();
select sim.cw_mudar(:'cw', '{"status":"open"}', 'cliente');
select sim._servico();
select (public.mari_entrada('5531999990076', 'Tito X76', 'Oi de novo', 'whatsapp', null, :'cw') ->> 'conversa_id') as c2 \gset
select sim.confere('depois do #zerar a fala nova abre outra conversa', :'c2' <> :'c', :'c2');
select sim.confere('a conversa antiga deixa de apontar para o Chatwoot; só a nova fica nele',
  (select chatwoot_conversation_id from public.mari_conversas where id = :'c') is null
  and (select count(*) from public.mari_conversas where chatwoot_conversation_id = :'cw') = 1,
  (select string_agg(left(id::text, 8) || ' ' || status || ' ' || coalesce(chatwoot_conversation_id, '-'), ' · ')
     from public.mari_conversas where telefone = '5531999990076'));

-- (3) controle: cliente de verdade em Saída "Teste ou duplicada" (dada pelo time) continua sendo resolvido quando respondemos
select sim.lead_novo('Teo X76') as d \gset
select sim.como('backoffice');
select public.lead_sair(:'d', null, 'teste_duplicada');
select sim.fila_rodar();
select sim.como('servico');
select sim._conv(:'d') as cwd \gset
select sim.cw_mudar(:'cwd', '{"status":"open"}', 'cliente');
select max(id) as base2 from public.chatwoot_acoes \gset
insert into public.mari_turnos (conversa_id, papel, texto) values (:'d', 'humano', 'Oi, aqui é do time');
select sim.confere('telefone comum em Saída "Teste ou duplicada": nossa fala resolve a conversa de novo (como antes)',
  exists (select 1 from public.chatwoot_acoes where id > :base2 and conversa_id = :'d' and momento = 'refechar'),
  (select string_agg(momento || ':' || tipo, ' ') from public.chatwoot_acoes where id > :base2 and conversa_id = :'d'));
select sim.fila_rodar();
