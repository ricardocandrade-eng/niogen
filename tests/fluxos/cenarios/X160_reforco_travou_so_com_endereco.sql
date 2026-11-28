-- id: X160
-- titulo: 0438 (Ricardo, 28/11: "Sim, aperta"): o sinal "travou" do Reforço só vale quando alguma fala do cliente tem cara de endereço (rua, avenida, bairro…) e a última fala dele não é recusa nem "já tenho internet"; quem só conversou, quem pediu outro ponto e quem recusou depois de dar a rua não entram; quem deu rua ou avenida continua entrando
-- tipo: atual
select sim.como('servico');

-- ───────── 1) falou bastante, mas não deu endereço: "já tenho internet" ─────────
select sim.lead_novo('Eva X160') as a \gset
select sim.cliente_escreve(:'a', '🏡 Pra minha casa', false);
select sim.mari_fala(:'a', 'Perfeito, residencial então. Me manda a rua e o bairro (ou o CEP) que eu confiro se a fibra passa aí.');
select sim.cliente_escreve(:'a', 'Mariana, ja tenho internet, amiga. Obrigada', false);
select sim.mari_fala(:'a', 'Entendi! Se um dia quiser comparar, é só me chamar aqui.');
select sim.fila_rodar();
select sim.passa(:'a', interval '40 minutes');

-- ───────── 2) pediu outra coisa, sem endereço ─────────
select sim.lead_novo('Fabio X160') as b \gset
select sim.cliente_escreve(:'b', '🏡 Pra minha casa', false);
select sim.mari_fala(:'b', 'Perfeito! Me manda a rua e o bairro, ou o CEP, que eu confiro.');
select sim.cliente_escreve(:'b', 'Só quero outro ponto', false);
select sim.mari_fala(:'b', 'Você já é cliente Nio? Me conta um pouco mais do que precisa.');
select sim.fila_rodar();
select sim.passa(:'b', interval '40 minutes');

-- ───────── 3) deu a rua e depois recusou ─────────
select sim.lead_novo('Gil X160') as c \gset
select sim.cliente_escreve(:'c', '🏡 Pra minha casa', false);
select sim.mari_fala(:'c', 'Perfeito, residencial. Me manda a rua e o bairro (ou o CEP).');
select sim.cliente_escreve(:'c', 'Rua Halfeld 500 centro', false);
select sim.mari_fala(:'c', 'Achei a Rua Halfeld, no Centro. Qual é a cidade?');
select sim.cliente_escreve(:'c', 'Deixa pra lá, não quero mais', false);
select sim.mari_fala(:'c', 'Tudo bem! Fico por aqui se mudar de ideia.');
select sim.fila_rodar();
select sim.passa(:'c', interval '40 minutes');

-- ───────── 4) deu avenida e número e se calou: continua valendo ─────────
select sim.lead_novo('Hugo X160') as d \gset
select sim.cliente_escreve(:'d', '🏡 Pra minha casa', false);
select sim.mari_fala(:'d', 'Perfeito, é pra casa. Me manda a rua e o bairro (ou o CEP) pra eu conferir a fibra.');
select sim.cliente_escreve(:'d', 'Avenida Rio Branco 1200, Centro', false);
select sim.mari_fala(:'d', 'Achei a Avenida Rio Branco. Em qual cidade ela fica?');
select sim.fila_rodar();
select sim.passa(:'d', interval '40 minutes');

select sim.confere('as quatro conversas estão com a Mari, sem CEP',
  (select count(*) = 4 from public.mari_conversas m join public.lead_estado e on e.conversa_id = m.id and e.situacao = 'mari_atendendo'
    where m.id in (:'a', :'b', :'c', :'d') and coalesce(m.cep, '') = ''),
  (select string_agg(e.situacao || '/' || coalesce(m.cep, '-'), ' ') from public.mari_conversas m join public.lead_estado e on e.conversa_id = m.id
    where m.id in (:'a', :'b', :'c', :'d')));

select sim.como('backoffice');
select public.live2_fila()::text as k \gset
select sim.confere('"já tenho internet" não é "travou" (não deu endereço e é recusa)',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'a' and x -> 'sinais' ? 'travou'),
  (select left(x::text, 300) from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'a'));
select sim.confere('"só quero outro ponto" não é "travou" (não deu endereço)',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'b' and x -> 'sinais' ? 'travou'),
  (select left(x::text, 300) from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'b'));
select sim.confere('deu a rua e depois recusou: não é "travou"',
  not exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'c' and x -> 'sinais' ? 'travou'),
  (select left(x::text, 300) from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'c'));
select sim.confere('deu avenida e número e se calou: continua "travou"',
  exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'d' and x -> 'sinais' ? 'travou'),
  (select left(x::text, 300) from jsonb_array_elements((:'k')::jsonb -> 'reforco') x where x ->> 'conversa_id' = :'d'));
select sim.confere('as palavras de endereço e as de "fora" ficam em config (regra 15)',
  (select valor ? 'travou_endereco_regex' and valor ? 'travou_fora_regex' from public.config_regras where chave = 'reforco_sinais'),
  (select left(valor::text, 300) from public.config_regras where chave = 'reforco_sinais'));
