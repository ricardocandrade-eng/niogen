-- id: X159
-- titulo: 0437 (Ricardo, 27/11, caso L-456): conversa da Mari em que o cliente já deu alguma coisa do endereço, não há CEP e ele se calou depois da fala dela aparece no Reforço como "travou" (não é tarefa, não entra na fila); quem só mandou a 1ª mensagem ou um botão, quem já tem CEP e quem falou há pouco não entram; e a Mari recebe a cidade do cadastro da Fila Vero (cidade_cadastro) enquanto a conversa não tem cidade
-- tipo: atual
select sim.como('servico');

-- ───────── 1) deu rua e bairro, a Mari respondeu, ele se calou ─────────
select sim.lead_novo('Ana X159') as a \gset
select sim.cliente_escreve(:'a', '🏡 Pra minha casa', false);
select sim.mari_fala(:'a', 'Perfeito, residencial então. Me manda a rua e o bairro (ou o CEP) que eu confiro se a fibra passa aí.');
select sim.cliente_escreve(:'a', 'Rua das perolas ,Marilândia', false);
select sim.mari_fala(:'a', 'Achei a Rua das Pérolas. Em qual cidade fica?');
select sim.fila_rodar();
select sim.confere('a conversa está com a Mari, sem CEP, e a Mari falou por último',
  (select coalesce(cep, '') = '' and ultima_msg_mari_at >= ultima_msg_lead_at from public.mari_conversas where id = :'a'),
  (select row(cep, ultima_msg_lead_at, ultima_msg_mari_at)::text from public.mari_conversas where id = :'a'));

-- antes de 20 min: ainda não
select sim.como('backoffice');
select public.live2_fila()::text as k \gset
select sim.confere('antes de 20 min calado, não é Reforço "travou"',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'a' and x -> 'sinais' ? 'travou'),
  (select x ->> 'sinais' from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'a'));

select sim.como('servico');
select sim.passa(:'a', interval '40 minutes');
select sim.como('backoffice');
select public.live2_fila()::text as k \gset
select coalesce((select x::text from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'a'), '{}') as rf \gset
select sim.confere('40 min calado depois de dar o endereço → aparece no Reforço como "travou"',
  (:'rf')::jsonb -> 'sinais' ? 'travou' and (:'rf')::jsonb ->> 'sinal' = 'travou', left(:'rf', 400));
select sim.confere('com o motivo e a última fala do cliente',
  (:'rf')::jsonb ->> 'porque' ~* 'antes do CEP' and (:'rf')::jsonb ->> 'fala' like 'Rua das perolas%', left(:'rf', 400));
select sim.confere('o Reforço não é tarefa: a conversa não entra na fila por causa dele',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a' and (x ->> 'fonte' = 'reforco' or x ->> 'fontes' like '%reforco%')), 'entrou');

-- "Agora não" tira do Reforço, como nos outros sinais
select public.reforco_registrar(:'a', 'travou', 'agora_nao', 'nao_vale');
select public.live2_fila()::text as k \gset
select sim.confere('"Agora não" tira a conversa do Reforço',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'a'), null);

-- ───────── 2) quem não entra ─────────
select sim.como('servico');
-- só a 1ª mensagem e um botão: não deu nada do endereço
select sim.lead_novo('Bia X159') as b \gset
select sim.cliente_escreve(:'b', '🏡 Pra minha casa', false);
select sim.mari_fala(:'b', 'Perfeito! Me manda a rua e o bairro, ou o CEP.');
select sim.fila_rodar();
select sim.passa(:'b', interval '40 minutes');
-- deu o endereço e já tem CEP: não travou
select sim.lead_novo('Caio X159') as c \gset
select sim.cliente_escreve(:'c', 'Rua Halfeld, 500, Centro', false);
select sim.mari_fala(:'c', 'Achei: Rua Halfeld, Centro, CEP 36010-020. É esse?');
select sim._servico();
update public.mari_conversas set cep = '36010020', numero = '500', cidade = 'Juiz de Fora', uf = 'MG' where id = :'c';
select sim.fila_rodar();
select sim.passa(:'c', interval '40 minutes');
select sim.como('backoffice');
select public.live2_fila()::text as k \gset
select sim.confere('quem só abriu a conversa e tocou num botão não é "travou"',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'b' and x -> 'sinais' ? 'travou'),
  (select x::text from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'b'));
select sim.confere('quem já tem CEP não é "travou"',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'c' and x -> 'sinais' ? 'travou'),
  (select x::text from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'c'));

-- ───────── 3) a Mari recebe a cidade do cadastro da Fila Vero ─────────
select sim.como('servico');
insert into sim.cw (conv, telefone, nome) values ('995901', '5532999590001', 'Duda X159');
insert into public.fila_vero (nome, telefone, segmento, status, template, wamid, codigo, cidade, bairro)
values ('Duda X159', '5532999590001', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X159D', 'x159d001', 'JUIZ DE FORA', 'INDUSTRIAL');
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x159d001'), true, '995901') ->> 'conversa_id') as d \gset
select sim.fila_rodar();
select sim.confere('o lead da Fila Vero nasceu sem cidade na conversa',
  (select origem = 'fila_vero' and coalesce(cidade, '') = '' from public.mari_conversas where id = :'d'),
  (select row(origem, cidade)::text from public.mari_conversas where id = :'d'));
select sim.confere('o contexto da Mari traz a cidade do cadastro (Juiz de Fora)',
  lower(public.mari_contexto(:'d') ->> 'cidade_cadastro') = 'juiz de fora', public.mari_contexto(:'d') ->> 'cidade_cadastro');
select sim._servico();
update public.mari_conversas set cidade = 'Barbacena', uf = 'MG' where id = :'d';
select sim.confere('com a cidade já na conversa, o cadastro não é mais usado',
  public.mari_contexto(:'d') ->> 'cidade_cadastro' is null, public.mari_contexto(:'d') ->> 'cidade_cadastro');
select sim.confere('lead que não veio da Fila Vero não recebe cidade de cadastro',
  public.mari_contexto(:'a') ->> 'cidade_cadastro' is null, public.mari_contexto(:'a') ->> 'cidade_cadastro');
