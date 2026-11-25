-- id: X103
-- titulo: 0379 agenda de retornos (Ricardo 24/11: "Mari retoma, alerta só na Live, detector só sugere"): o time marca dia e hora e o 🔔 aparece na Live 15 min antes, ⏰ atrasado depois de 1 h e na conferência, Feito tira; com a Mari, o retorno combinado sai na hora mesmo com a espera; com o time, a fala do cliente "me liga amanhã às 15h" vira sugestão que se confirma ou descarta; com a Mari o detector não mexe
-- tipo: atual
-- premissa: horário dos toques cobre o dia todo (o cenário não depende da hora em que o portão roda)
update public.config_regras set valor = '{"abre": "00:00", "fecha": "24:00", "todos_os_dias": true}'::jsonb where chave = 'mari_horario_toques';
select (now() at time zone 'America/Sao_Paulo')::date as hoje \gset
-- 25/11 (sessão da agência, 0406): a cópia traz os retornos REAIS do backup; um que passou da hora deixava a conferência amarela e
-- o "volta ao verde" falhava conforme a hora do portão. O cenário só confere os retornos que ele mesmo cria.
update public.retornos set estado = 'cancelado' where estado = 'marcado';

-- 0) o leitor
select sim.confere('leitor: "me liga amanhã às 15h"', to_char((public._retorno_ler_quando('me liga amanhã às 15h', now()) ->> 'quando')::timestamptz at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI')
  = to_char(:'hoje'::date + 1, 'YYYY-MM-DD') || ' 15:00', coalesce(public._retorno_ler_quando('me liga amanhã às 15h', now())::text, 'nada'));
select sim.confere('leitor: "te dou a resposta amanhã" (sem hora → 9h)', (public._retorno_ler_quando('vou ver e amanhã te dou a resposta', now()) ->> 'tem_hora') = 'false'
  and to_char((public._retorno_ler_quando('vou ver e amanhã te dou a resposta', now()) ->> 'quando')::timestamptz at time zone 'America/Sao_Paulo', 'HH24:MI') = '09:00',
  coalesce(public._retorno_ler_quando('vou ver e amanhã te dou a resposta', now())::text, 'nada'));
select sim.confere('leitor: "pode ligar às 3 da tarde amanhã" = 15h', to_char((public._retorno_ler_quando('pode ligar às 3 da tarde amanhã', now()) ->> 'quando')::timestamptz at time zone 'America/Sao_Paulo', 'HH24:MI') = '15:00',
  coalesce(public._retorno_ler_quando('pode ligar às 3 da tarde amanhã', now())::text, 'nada'));
select sim.confere('leitor: conversa comum não é pedido de retorno', public._retorno_ler_quando('Quanto custa o plano de 1 giga?', now()) is null
  and public._retorno_ler_quando('Paguei dia 5', now()) is null, 'leu retorno onde não há');

-- 1) o time marca um retorno numa conversa que ele conduz
select sim.lead_novo('Tito X103') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c'));
select public.retorno_marcar(:'c', now() + interval '1 day 2 hours', 'ligar depois do almoço') ->> 'quem' as q1 \gset
select sim.confere('com o time: quem chama é o time', :'q1' = 'time', :'q1');
select sim.confere('o lead sai da Live até 15 min antes da hora',
  (select abs(extract(epoch from espera_ate - (now() + interval '1 day 1 hour 45 minutes'))) < 120 from public.mari_conversas where id = :'c'),
  (select coalesce(espera_ate::text, 'sem espera') from public.mari_conversas where id = :'c'));
select sim.confere('antes da hora: nada na Live › Conferir',
  not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'conversa_id' = :'c' and x ->> 'tipo' like 'retorno%'), '');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c', '1 day 1 hour 50 minutes');
select sim.como('backoffice');
select coalesce((select x ->> 'texto' from jsonb_array_elements(public.live_conferir()) x where x ->> 'conversa_id' = :'c' and x ->> 'tipo' = 'retorno_agora'), 'nada') as t1 \gset
select sim.confere('10 min antes da hora: 🔔 na Live com o combinado', :'t1' like '🔔%ligar depois do almoço%', :'t1');
select sim.como('servico');
select sim.passa(:'c', '1 hour 30 minutes');
select sim.como('backoffice');
select coalesce((select x ->> 'texto' from jsonb_array_elements(public.live_conferir()) x where x ->> 'conversa_id' = :'c' and x ->> 'tipo' = 'retorno_agora'), 'nada') as t2 \gset
select sim.confere('1 h depois sem ninguém falar: ⏰ ATRASADO', :'t2' like '⏰ ATRASADO%', :'t2');
select coalesce((select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens('dharma')) x where x ->> 'codigo' = 'retornos_perdidos'), 'sem item') as n1 \gset
select sim.confere('a conferência acusa o retorno perdido', :'n1' = 'atencao', :'n1');
select id as r1 from public.retornos where conversa_id = :'c' and estado = 'marcado' \gset
select public.retorno_fechar(:'r1', 'feito', 'liguei, ele vai fechar amanhã');
select sim.confere('Feito tira da Live', not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'conversa_id' = :'c' and x ->> 'tipo' like 'retorno%'), '');
select coalesce((select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens('dharma')) x where x ->> 'codigo' = 'retornos_perdidos'), 'sem item') as n2 \gset
select sim.confere('e a conferência volta ao verde', :'n2' = 'ok', :'n2');

-- 2) com a Mari: "me chama amanhã às 15h" → retorno com hora; a Mari chama na hora, mesmo com a espera marcada
select sim.como('servico');
select sim.lead_novo('Mel X103') as m \gset
select sim.mari_fala(:'m', 'Oi! Sou a Mari, da Nio. Qual o seu CEP?');
select sim.cliente_escreve(:'m', 'agora não dá, me chama amanhã às 15h', false);
select sim.mari_handoff(:'m', 'multiplos_decisores', jsonb_build_object('agendamento_retorno', to_char(:'hoje'::date + 1, 'YYYY-MM-DD') || 'T15:00:00-03:00'));
select sim.confere('retorno da Mari registrado, com hora', exists (select 1 from public.retornos r where r.conversa_id = :'m' and r.estado = 'marcado'
  and r.quem = 'mari' and r.origem = 'mari' and to_char(r.quando at time zone 'America/Sao_Paulo', 'HH24:MI') = '15:00'),
  (select coalesce(string_agg(r.quem || ' ' || r.estado || ' ' || r.quando::text, ' | '), 'nenhum') from public.retornos r where r.conversa_id = :'m'));
select sim.confere('a espera vai até 2 h depois (17h)', (select to_char(espera_ate at time zone 'America/Sao_Paulo', 'HH24:MI') = '17:00' from public.mari_conversas where id = :'m'),
  (select coalesce(espera_ate::text, 'sem espera') from public.mari_conversas where id = :'m'));
select sim.passa(:'m', '1 day');
select count(*) from sim.cadencia(sim.hora('14:00'));
select sim.confere('antes da hora a Mari não chama', (select count(*) from sim.envios where conversa = :'m' and por = 'cadencia:RETORNO') = 0,
  (select coalesce(string_agg(por, ' '), 'nada') from sim.envios where conversa = :'m'));
select count(*) from sim.cadencia(sim.hora('15:05'));
select sim.confere('na hora, com a espera ainda valendo, a Mari chama (RETORNO)', (select count(*) from sim.envios where conversa = :'m' and por = 'cadencia:RETORNO') = 1,
  (select coalesce(string_agg(por, ' '), 'nada') from sim.envios where conversa = :'m'));

-- 3) com o time: a fala do cliente vira sugestão; confirmar marca o retorno
select sim.lead_novo('Dora X103') as d \gset
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'d'));
select sim.como('servico');
select sim.cliente_escreve(:'d', 'Agora estou no trabalho, pode me ligar amanhã às 15h?', false);
select sim.confere('a fala virou sugestão (amanhã 15h)', exists (select 1 from public.retornos r where r.conversa_id = :'d' and r.estado = 'sugerido'
  and r.origem = 'detector' and to_char(r.quando at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI') = to_char(:'hoje'::date + 1, 'YYYY-MM-DD') || ' 15:00'),
  (select coalesce(string_agg(r.estado || ' ' || r.quando::text, ' | '), 'nenhuma') from public.retornos r where r.conversa_id = :'d'));
select sim.confere('a sugestão não muda o lead (sem espera)', (select espera_ate is null from public.mari_conversas where id = :'d'), '');
select sim.como('backoffice');
select sim.confere('a sugestão aparece na Live › Conferir', exists (select 1 from jsonb_array_elements(public.live_conferir()) x
  where x ->> 'conversa_id' = :'d' and x ->> 'tipo' = 'retorno_sugerido'), '');
select id as s1 from public.retornos where conversa_id = :'d' and estado = 'sugerido' \gset
select public.retorno_fechar(:'s1', 'confirmar') ->> 'quem' as q3 \gset
select sim.confere('confirmar marca o retorno (o time chama)', :'q3' = 'time'
  and exists (select 1 from public.retornos r where r.conversa_id = :'d' and r.estado = 'marcado' and r.origem = 'time')
  and not exists (select 1 from public.retornos r where r.conversa_id = :'d' and r.estado = 'sugerido'), :'q3');

-- 4) descartar a sugestão
select sim.lead_novo('Gil X103') as g \gset
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'g'));
select sim.como('servico');
select sim.cliente_escreve(:'g', 'me liga sexta de tarde', false);
select sim.como('backoffice');
select id as s2 from public.retornos where conversa_id = :'g' and estado = 'sugerido' \gset
select public.retorno_fechar(:'s2', 'descartar', 'ele já fechou pelo site');
select sim.confere('descartada, some da Live', not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'conversa_id' = :'g' and x ->> 'tipo' like 'retorno%'), '');

-- 5) com a Mari, o detector não mexe (quem lê o pedido é ela)
select sim.como('servico');
select sim.lead_novo('Bia X103') as b \gset
select sim.cliente_escreve(:'b', 'me liga amanhã às 10h', false);
select sim.confere('conversa com a Mari: sem sugestão do detector', not exists (select 1 from public.retornos r where r.conversa_id = :'b'), '');

-- 6) só admin e backoffice marcam
select sim.como('vendedor');
select sim.confere('vendedor não marca retorno', sim.recusa(format('select public.retorno_marcar(%L, now() + interval ''2 days'', null)', :'b')) is not null, '');
