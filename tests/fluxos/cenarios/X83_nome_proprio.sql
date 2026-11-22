-- id: X83
-- titulo: Ricardo (22/11): "cria uma regra para normalizar todos os nomes com apenas as iniciais maiúsculas" — a Receita devolve o nome em MAIÚSCULAS, o WhatsApp vem como o cliente escreveu; a regra é do banco (nome_proprio) e vale em todo caminho de gravação: ficha, extensão, Mari e venda
-- tipo: atual
select sim.confere('MAIÚSCULAS da Receita viram iniciais maiúsculas, com "de/da/dos" minúsculos',
  public.nome_proprio('CINTIA NAVES DE OLIVEIRA DOS SANTOS') = 'Cintia Naves de Oliveira dos Santos', public.nome_proprio('CINTIA NAVES DE OLIVEIRA DOS SANTOS'));
select sim.confere('minúsculas e espaços a mais', public.nome_proprio('  joão   da silva e souza ') = 'João da Silva e Souza', public.nome_proprio('  joão   da silva e souza '));
select sim.confere('acento, hífen e apóstrofo', public.nome_proprio('ANA-MARIA D''ÁVILA') = 'Ana-Maria D''Ávila', public.nome_proprio('ANA-MARIA D''ÁVILA'));
select sim.confere('partícula no começo do nome ganha maiúscula', public.nome_proprio('DA SILVA comercio') = 'Da Silva Comercio', public.nome_proprio('DA SILVA comercio'));
select sim.confere('sigla de empresa fica em maiúsculas', public.nome_proprio('dharma telecom ltda') = 'Dharma Telecom LTDA', public.nome_proprio('dharma telecom ltda'));
select sim.confere('vazio e nulo não quebram', public.nome_proprio(null) is null and public.nome_proprio('   ') = '', null);
select sim.confere('aplicar duas vezes dá o mesmo', public.nome_proprio(public.nome_proprio('MARIA DAS DORES E SILVA')) = public.nome_proprio('MARIA DAS DORES E SILVA'), null);

-- lead: o nome gravado pela ficha (lápis) e o lido do portal entram normalizados
select sim.lead_pronto('Nome X83') as c \gset
select sim.como('backoffice');
select public.lead_corrigir(:'c', '{"nome":"MARIA APARECIDA DOS SANTOS"}'::jsonb);
select sim.confere('nome digitado em maiúsculas na ficha do lead fica normalizado',
  (select dados ->> 'nome' from public.mari_conversas where id = :'c') = 'Maria Aparecida dos Santos', (select dados ->> 'nome' from public.mari_conversas where id = :'c'));
select sim._servico();
update public.mari_conversas set nome_contato = 'jOSÉ da SILVA' where id = :'c';
select sim.confere('o nome do WhatsApp também', (select nome_contato from public.mari_conversas where id = :'c') = 'José da Silva', (select nome_contato from public.mari_conversas where id = :'c'));

-- venda: nasce com o nome normalizado e continua assim quando alguém troca
select sim.lead_pronto('Venda X83') as v \gset
select sim._servico();
update public.mari_conversas set dados = dados || '{"nome":"PEDRO HENRIQUE DE ALMEIDA"}'::jsonb where id = :'v';
select sim.mari_handoff(:'v', 'dados_completos', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('a venda nasce com o nome normalizado', (select cliente_nome from public.vendas where id = sim.venda(:'v')) = 'Pedro Henrique de Almeida',
  (select cliente_nome from public.vendas where id = sim.venda(:'v')));
select sim._servico();
update public.vendas set cliente_nome = 'PEDRO HENRIQUE DE ALMEIDA JUNIOR', contato_nome = 'ana paula' where id = sim.venda(:'v');
select sim.confere('nome trocado na venda continua normalizado (titular e contato)',
  (select cliente_nome = 'Pedro Henrique de Almeida Junior' and contato_nome = 'Ana Paula' from public.vendas where id = sim.venda(:'v')),
  (select cliente_nome || ' · ' || contato_nome from public.vendas where id = sim.venda(:'v')));

-- o que já estava gravado foi acertado pela migration
select sim.confere('nenhuma venda, conversa ou linha da Fila Vero ficou fora da regra',
  not exists (select 1 from public.vendas where cliente_nome is distinct from public.nome_proprio(cliente_nome))
  and not exists (select 1 from public.mari_conversas where nome_contato is distinct from public.nome_proprio(nome_contato))
  and not exists (select 1 from public.fila_vero where nome is distinct from public.nome_proprio(nome)), null);
