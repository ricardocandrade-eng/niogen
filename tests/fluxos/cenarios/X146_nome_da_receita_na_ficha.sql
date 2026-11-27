-- id: X146
-- titulo: 0423 (Ricardo, 26/11, caso L-272 "Pera Ai"): o nome da Receita lido na consulta de crédito vai para a ficha — grava quando não há nome ou ele é provisório, completa quando o 1º nome é o mesmo, e NÃO troca um nome diferente (só guarda e avisa)
-- tipo: atual

-- A) Lead sem nome: a consulta automática da Mari grava o nome da Receita (normalizado) e ele passa a ser confiável
select sim.lead_pronto('Tmp X146') as a \gset
select sim._servico();
update public.mari_conversas set dados = dados - 'nome', nome_confiavel = false where id = :'a';
select public.mari_credito_gravar(:'a', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"], "nome_receita": "JULIO CESAR TEIXEIRA DA SILVA"}'::jsonb);
select sim.confere('sem nome: o nome da Receita foi gravado, com iniciais maiúsculas',
  (select dados ->> 'nome' from public.mari_conversas where id = :'a') = 'Julio Cesar Teixeira da Silva', (select dados ->> 'nome' from public.mari_conversas where id = :'a'));
select sim.confere('sem nome: nome_confiavel = true e a origem ficou anotada',
  (select nome_confiavel and dados ->> 'nome_origem' = 'receita' from public.mari_conversas where id = :'a'), null);
select sim.confere('sem nome: ficou a linha de sistema na conversa',
  exists (select 1 from public.mari_turnos where conversa_id = :'a' and papel = 'sistema' and texto like '[nome do titular gravado pela consulta de crédito%'), null);
select sim.confere('o crédito foi gravado como antes',
  (select credito_resultado from public.mari_conversas where id = :'a') = 'aprovado_todas', (select credito_resultado from public.mari_conversas where id = :'a'));

-- B) Nome provisório do atalho da Mari ("Pera Ai", L-272): a Receita troca e tira a marca de provisório
select sim.lead_pronto('Tmp X146') as b \gset
select sim._servico();
update public.mari_conversas set dados = dados || '{"nome": "Pera Ai", "nome_provisorio": true}'::jsonb where id = :'b';
select public.mari_credito_gravar(:'b', '{"resultado": "negado", "nome_receita": "MARIA APARECIDA LEANDRO"}'::jsonb);
select sim.confere('provisório: trocado pelo nome da Receita, sem a marca',
  (select dados ->> 'nome' = 'Maria Aparecida Leandro' and not (dados ? 'nome_provisorio') from public.mari_conversas where id = :'b'),
  (select dados::text from public.mari_conversas where id = :'b'));

-- C) O cliente disse só o 1º nome, com acento: a Receita completa
select sim.lead_pronto('Júlio') as c \gset
select sim._servico();
select public.mari_credito_gravar(:'c', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO"], "nome_receita": "JULIO TEIXEIRA"}'::jsonb);
select sim.confere('mesmo 1º nome: completado com o nome da Receita',
  (select dados ->> 'nome' from public.mari_conversas where id = :'c') = 'Julio Teixeira', (select dados ->> 'nome' from public.mari_conversas where id = :'c'));

-- D) Nome informado DIFERENTE do da Receita (CPF de um parente): o nome do cliente fica; o da Receita é guardado e o time é avisado
select sim.lead_pronto('Maria Souza X146') as d \gset
select sim._servico();
select public.mari_credito_gravar(:'d', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO"], "nome_receita": "JOAO PEDRO SOUZA"}'::jsonb);
select sim.confere('nome diferente: o nome informado pelo cliente não foi trocado',
  (select dados ->> 'nome' from public.mari_conversas where id = :'d') = 'Maria Souza X146', (select dados ->> 'nome' from public.mari_conversas where id = :'d'));
select sim.confere('nome diferente: o da Receita ficou guardado à parte e a conversa ganhou o aviso',
  (select dados ->> 'nome_receita' from public.mari_conversas where id = :'d') = 'Joao Pedro Souza'
  and exists (select 1 from public.mari_turnos where conversa_id = :'d' and papel = 'sistema' and texto like '%diferente do informado%'),
  (select dados ->> 'nome_receita' from public.mari_conversas where id = :'d'));

-- E) CPF consultado não é o CPF da conversa (máscara não bate): nada muda
select sim.lead_pronto('Tmp X146') as e \gset
select sim._servico();
update public.mari_conversas set dados = (dados - 'nome') || '{"cpf": "52998224725"}'::jsonb where id = :'e';
select public.mari_credito_gravar(:'e', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO"], "nome_receita": "OUTRA PESSOA DA SILVA", "cpf_mascara": "111.***.***-99"}'::jsonb);
select sim.confere('outro CPF: nenhum nome gravado',
  (select dados ->> 'nome' is null and dados ->> 'nome_receita' is null from public.mari_conversas where id = :'e'), (select dados::text from public.mari_conversas where id = :'e'));
select public.mari_credito_gravar(:'e', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO"], "nome_receita": "CARLA DIAS", "cpf_mascara": "529.***.***-25"}'::jsonb);
select sim.confere('mesmo CPF (máscara bate): grava',
  (select dados ->> 'nome' from public.mari_conversas where id = :'e') = 'Carla Dias', (select dados ->> 'nome' from public.mari_conversas where id = :'e'));

-- F) Resposta do operador sem nome (erro, popup antes da Receita): nada muda e a função não quebra
select sim.lead_pronto('Fica X146') as f \gset
select sim._servico();
select public.mari_credito_gravar(:'f', '{"resultado": "nao_classificado", "motivo": "Receita sem resposta"}'::jsonb);
select sim.confere('sem nome_receita: o nome da conversa fica como estava',
  (select dados ->> 'nome' from public.mari_conversas where id = :'f') = 'Fica X146', (select dados ->> 'nome' from public.mari_conversas where id = :'f'));

-- G) Tela Consulta com um lead escolhido: backoffice grava; sem lead escolhido, só registra a consulta
select sim.lead_pronto('Tmp X146') as g \gset
select sim._servico();
update public.mari_conversas set dados = dados - 'nome' where id = :'g';
select sim.como('backoffice');
select public.operador_consulta_registrar('credito', jsonb_build_object('conversa_id', :'g', 'resultado', 'aprovado_todas', 'nome_receita', 'ANA BEATRIZ LIMA'));
select sim._servico();
select sim.confere('tela Consulta com lead: o nome da Receita foi para a ficha',
  (select dados ->> 'nome' from public.mari_conversas where id = :'g') = 'Ana Beatriz Lima', (select dados ->> 'nome' from public.mari_conversas where id = :'g'));
select sim.como('backoffice');
select public.operador_consulta_registrar('credito', jsonb_build_object('resultado', 'aprovado_todas', 'nome_receita', 'CONSULTA AVULSA DA SILVA')) > 0 as avulsa \gset
select sim._servico();
select sim.confere('tela Consulta sem lead: a consulta é registrada e nenhuma conversa muda', :'avulsa' = 't'
  and not exists (select 1 from public.mari_conversas where dados ->> 'nome' = 'Consulta Avulsa da Silva'), null);
select sim.confere('o nome não fica no histórico de consultas (só a máscara do CPF)',
  not exists (select 1 from public.operador_consultas where conversa_id in (:'a', :'g') and (detalhe::text ilike '%beatriz%' or detalhe::text ilike '%teixeira%')), null);
