-- id: X102
-- titulo: 0378 (L-276, Nelma, #241): Saída "Cidade não atendida" manda o texto próprio da cidade (com o nome que a Mari marcou), não o de "a fibra não chega no seu endereço"; volta do cliente idem; Fachada não muda
-- tipo: atual
-- 1) Nelma: a Mari marcou a cidade pelo texto (Cabo Frio), o time dá a Saída "Cidade não atendida"
select sim.lead_novo('Nelma X102') as c \gset
select sim.mari_fala(:'c', 'Entendi, Cabo Frio!');
select sim.como('servico');
update public.mari_turnos set tags = coalesce(tags, '{}'::jsonb) || '{"cidade_detectada": "Cabo Frio"}'::jsonb
 where id = (select max(id) from public.mari_turnos where conversa_id = :'c' and papel = 'mari');
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'cidade_nao_atendida');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select a.payload ->> 'texto_chave' || ' | ' || (a.payload ->> 'content') from public.chatwoot_acoes a
  where a.conversa_id = :'c' and a.tipo = 'mensagem' order by a.id desc limit 1), 'nada') as m \gset
select sim.confere('o cliente recebe o texto da cidade', :'m' like 'saida_cidade_nao_atendida%', :'m');
select sim.confere('o texto diz a cidade que a Mari marcou', :'m' like '%Cabo Frio ainda não está entre elas%', :'m');
select sim.confere('não fala de rua nem de "fibra não chega no endereço"', :'m' not like '%chega no seu endereço%', :'m');

-- no dia seguinte ela escreve de novo: resposta da cidade, não da rua
select sim.passa(:'c', '1 day');
select sim.cliente_escreve(:'c', 'Mas não tem mesmo?') as r1 \gset
select sim.fila_rodar();
select coalesce((select a.payload ->> 'texto_chave' from public.chatwoot_acoes a
  where a.conversa_id = :'c' and a.tipo = 'mensagem' order by a.id desc limit 1), 'nada') as k1 \gset
select sim.confere('a volta recebe o texto da cidade', :'k1' = 'saida_cidade_nao_atendida', :'k1');
select sim.confere('o lead continua em Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);

-- 2) sem cidade conhecida → "a sua cidade"
select sim.lead_novo('Sem cidade X102') as c2 \gset
select sim.como('backoffice');
select public.lead_sair(:'c2', null, 'cidade_nao_atendida');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select a.payload ->> 'content' from public.chatwoot_acoes a
  where a.conversa_id = :'c2' and a.tipo = 'mensagem' order by a.id desc limit 1), 'nada') as m2 \gset
select sim.confere('sem cidade, diz "a sua cidade"', :'m2' like '%e a sua cidade ainda não está entre elas%', :'m2');

-- 3) Fachada não atendida continua com o texto de sempre
select sim.lead_com_venda('Fachada X102') as c3 \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c3'), 'viabilidade', '{"resultado":"sem_viabilidade"}');
select public.lead_sair(:'c3', null, 'fachada_nao_atendida');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('fachada: texto de sempre', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c3'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' in ('saida_sem_cobertura', 'saida_sem_cobertura_indicacao')),
  (select coalesce(string_agg(a.payload ->> 'texto_chave', ', '), 'nada') from public.chatwoot_acoes a where a.conversa_id = :'c3' and a.tipo = 'mensagem'));
