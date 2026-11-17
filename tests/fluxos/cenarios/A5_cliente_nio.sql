-- id: A5
-- titulo: Cliente que já é Nio: a Mari encerra com os canais oficiais; se ele insistir, a conversa é silenciada, sem dono
-- tipo: atual
-- Regra do Ricardo (17/11): "Cliente já é Nio, em qualquer situação, educadamente a Mari encerra a conversa, pedindo para procurar
-- os canais oficiais. Se depois de alguns minutos o cliente insistir, silencie a conversa. Somos uma revenda da Nio."
select sim.lead_novo('Lia A5', 'Oi, sou cliente Nio e minha internet caiu') as c \gset
select sim.mari_handoff(:'c', 'ja_cliente_nio', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('Saída "Já é cliente Nio"', sim.lead_de(:'c') ->> 'destino' = 'saida' and sim.lead_de(:'c') ->> 'saida' = 'ja_cliente_nio', sim.lead_de(:'c')::text);
select sim.confere('conversa resolvida, sem dono e sem time', sim.cw_de(:'c') ->> 'status' in ('resolved', 'snoozed') and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null,
  sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'mas eu preciso de ajuda, ninguém da Nio me atende!', true, '5 minutes') as r \gset
select sim.fila_rodar();
select sim.confere('insistiu: a Mari não responde', :'r' like 'calada%', :'r');
select sim.confere('insistiu: a conversa foi silenciada', (select quadro_encerrada_motivo from public.mari_conversas where id = :'c') = 'suporte_nio',
  coalesce((select quadro_encerrada_motivo from public.mari_conversas where id = :'c'), 'não silenciada'));
select sim.confere('silenciada sem dono e sem time (ninguém atende)', sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null
  and sim.cw_de(:'c') ->> 'status' in ('resolved', 'snoozed'), sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'alô???', true, '1 hour') as r2 \gset
select sim.fila_rodar();
select sim.espera(:'c', '5 minutes');   -- a nova adiada sai 1 min depois (espera o Chatwoot reabrir)
select sim.confere('escreve de novo: continua calada e fechada', :'r2' like 'calada%' and sim.cw_de(:'c') ->> 'status' in ('resolved', 'snoozed'), :'r2' || ' · ' || sim.cw_de(:'c')::text);
