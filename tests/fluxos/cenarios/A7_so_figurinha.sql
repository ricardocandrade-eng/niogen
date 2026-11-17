-- id: A7
-- titulo: Cliente manda só figurinha ou imagem: conta como escreveu e a Mari responde
-- tipo: atual
select sim.lead_novo('Caio A7') as c \gset
select sim.cliente_escreve(:'c', '', true, '3 minutes', '[{"tipo":"sticker"}]') as r \gset
select sim.confere('a Mari respondeu à figurinha', :'r' = 'respondeu', :'r');
select sim.confere('o lead segue em andamento com a vez da Mari', sim.lead_de(:'c') ->> 'vez' = 'mari', sim.lead_de(:'c')::text);
