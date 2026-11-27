-- id: X155
-- titulo: 0433 (Ricardo, 27/11: "Preciso criar uma forma de incluir respostas automáticas no Niogen… Eu preciso cadastrar mais" → "Sim, constrói"): as respostas rápidas saem de config_mari_textos (rr_*, "Rótulo::texto", só por migration) e viram tabela própria, com tela; só o admin cadastra e só pelas funções; desativar não apaga; o uso fica registrado
-- tipo: atual

-- 1) as que já existiam vieram, com rótulo e texto separados, e a fonte antiga ficou vazia
select sim.como('admin');
select public.respostas_rapidas() as l0 \gset
select sim.confere('as respostas de antes vieram para a tabela nova',
  jsonb_array_length(:'l0'::jsonb) >= 7
  and exists (select 1 from jsonb_array_elements(:'l0'::jsonb) x where x->>'rotulo' = 'Crédito negado' and x->>'texto' like 'Não conseguimos%'), :'l0');
select sim.confere('rótulo e texto separados: nenhum "::" sobrou',
  not exists (select 1 from jsonb_array_elements(:'l0'::jsonb) x where x->>'rotulo' like '%::%' or x->>'texto' like (x->>'rotulo') || '::%'), :'l0');
select sim.confere('a ordem de antes foi mantida (Apresentação primeiro)',
  (:'l0'::jsonb -> 0 ->> 'rotulo') = 'Apresentação do consultor', :'l0'::jsonb -> 0 ->> 'rotulo');
select sim.confere('fonte única: config_mari_textos não tem mais rr_*',
  not exists (select 1 from public.config_mari_textos where chave like 'rr\_%'), null);

-- 2) o admin cadastra uma nova: entra no fim da lista
select public.resposta_rapida_salvar(null, 'Prazo de instalação', E'O prazo quem confirma é a Nio, na hora do agendamento.\nAssim que o pedido entrar eu te aviso.') as n1 \gset
select sim.confere('nova resposta gravada, ativa, com autor',
  (:'n1'::jsonb ->> 'id') is not null and (:'n1'::jsonb ->> 'ativo')::boolean
  and (select criada_por is not null from public.config_respostas_rapidas where id = (:'n1'::jsonb ->> 'id')::bigint), :'n1');
select sim.confere('entra no fim da lista, com a quebra de linha preservada',
  (select x->>'rotulo' = 'Prazo de instalação' and x->>'texto' like E'%\n%'
     from jsonb_array_elements(public.respostas_rapidas()) with ordinality t(x, n) order by n desc limit 1), null);

-- 3) recusas, com a frase
select sim.confere('rótulo repetido é recusado',
  sim.recusa($q$ select public.resposta_rapida_salvar(null, 'prazo de instalação', 'outro texto') $q$) like '%Já existe%', null);
select sim.confere('texto vazio é recusado',
  sim.recusa($q$ select public.resposta_rapida_salvar(null, 'Sem texto', '   ') $q$) like '%texto%', null);
select sim.confere('rótulo com mais de 40 caracteres é recusado',
  sim.recusa($q$ select public.resposta_rapida_salvar(null, repeat('x', 41), 'oi') $q$) like '%40%', null);
select sim.confere('texto com mais de 1000 caracteres é recusado',
  sim.recusa($q$ select public.resposta_rapida_salvar(null, 'Texto enorme', repeat('x', 1001)) $q$) like '%1000%', null);
select sim.confere('resposta que não existe não se edita',
  sim.recusa($q$ select public.resposta_rapida_salvar(-1, 'Fantasma', 'oi') $q$) like '%não encontrada%', null);

-- 4) editar: muda o texto e a ordem, guarda quem e o antes
select public.resposta_rapida_salvar((:'n1'::jsonb ->> 'id')::bigint, 'Prazo de instalação', 'Texto novo', 0) as n2 \gset
select sim.confere('edição grava o texto novo e sobe para o 1º lugar',
  (public.respostas_rapidas() -> 0 ->> 'texto') = 'Texto novo', public.respostas_rapidas() -> 0 ->> 'rotulo');
select sim.confere('histórico guarda a criação e a edição, com o texto de antes',
  (select count(*) from public.config_respostas_rapidas_hist where resposta_id = (:'n1'::jsonb ->> 'id')::bigint) = 2
  and exists (select 1 from public.config_respostas_rapidas_hist where resposta_id = (:'n1'::jsonb ->> 'id')::bigint
               and acao = 'editar' and antes ->> 'texto' like 'O prazo quem confirma%' and por is not null), null);

-- 5) backoffice lê e usa, mas não cadastra; vendedor não lê; a tela não grava direto
select sim.como('backoffice');
select sim.confere('backoffice lê a lista',
  jsonb_array_length(public.respostas_rapidas()) = jsonb_array_length(:'l0'::jsonb) + 1, null);
select sim.confere('backoffice não cadastra',
  sim.recusa($q$ select public.resposta_rapida_salvar(null, 'Do backoffice', 'oi') $q$) like '%Só o admin%', null);
select sim.confere('backoffice não desativa',
  sim.recusa(format('select public.resposta_rapida_apagar(%s)', (:'n1'::jsonb ->> 'id'))) like '%Só o admin%', null);
select sim.como('vendedor');
select sim.confere('vendedor recebe a lista vazia', public.respostas_rapidas() = '[]'::jsonb, null);
select sim.como('admin');
set role authenticated;
select sim.recusa($q$ update public.config_respostas_rapidas set texto = 'direto' $q$) as d1,
       sim.recusa($q$ insert into public.config_respostas_rapidas (rotulo, texto) values ('direto', 'x') $q$) as d2 \gset
reset role;
select sim.confere('nem o admin grava direto na tabela: só pelas funções',
  :'d1' like '%permission denied%' and :'d2' like '%permission denied%', :'d1');

-- 6) o uso fica registrado (e diz se o texto foi editado antes de sair) — nenhum estado de lead muda
select sim.como('backoffice');
select id as conv from public.mari_conversas order by id limit 1 \gset
select public.resposta_rapida_usada((:'n1'::jsonb ->> 'id')::bigint, :'conv', null, 'Texto novo');
select public.resposta_rapida_usada((:'n1'::jsonb ->> 'id')::bigint, :'conv', null, 'Texto novo, com um ajuste');
select sim.confere('dois usos gravados, com quem usou; o segundo marcado como editado',
  (select count(*) = 2 and count(*) filter (where editada) = 1 and bool_and(usuario_id is not null)
     from public.respostas_rapidas_uso where resposta_id = (:'n1'::jsonb ->> 'id')::bigint), null);

-- 7) desativar: some do menu da conversa, a linha e o uso ficam; o admin ainda a vê em Configurações e pode religar
select sim.como('admin');
select public.resposta_rapida_apagar((:'n1'::jsonb ->> 'id')::bigint) as a1 \gset
select sim.confere('desativada some do menu',
  not exists (select 1 from jsonb_array_elements(public.respostas_rapidas()) x where x->>'rotulo' = 'Prazo de instalação'), null);
select sim.confere('a linha e o uso continuam (não apaga)',
  exists (select 1 from public.config_respostas_rapidas where id = (:'n1'::jsonb ->> 'id')::bigint and not ativo)
  and (select count(*) from public.respostas_rapidas_uso where resposta_id = (:'n1'::jsonb ->> 'id')::bigint) = 2, null);
select sim.confere('em Configurações (todas) ela aparece como inativa',
  exists (select 1 from jsonb_array_elements(public.respostas_rapidas(true)) x where x->>'rotulo' = 'Prazo de instalação' and not (x->>'ativo')::boolean), null);
select public.resposta_rapida_salvar(null, 'Prazo de instalação', 'Outra com o mesmo rótulo') as n3 \gset
select sim.confere('rótulo de resposta desativada fica livre para uma nova', (:'n3'::jsonb ->> 'id') is not null, :'n3');
select sim.confere('religar a antiga com o rótulo já em uso é recusado',
  sim.recusa(format($q$ select public.resposta_rapida_salvar(%s, 'Prazo de instalação', 'Texto novo', null, true) $q$, (:'n1'::jsonb ->> 'id'))) like '%Já existe%', null);
