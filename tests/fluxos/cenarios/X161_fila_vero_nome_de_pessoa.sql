-- id: X161
-- titulo: 0439 (pendência do L-183, 18/11): a mensagem do clique da Fila Vero não chama empresa pelo 1º nome — "Farol Negócios LTDA" recebe "Oi, tudo bem!", pessoa segue recebendo o 1º nome; o texto do Chamar por fora segue a mesma regra
-- tipo: atual
select sim.como('servico');

-- a regra, direto na função
select sim.confere('pessoa: devolve o 1º nome com inicial maiúscula',
  public.nome_de_pessoa('MARIA APARECIDA DE SOUZA') = 'Maria' and public.nome_de_pessoa('  joão de sá ') = 'João',
  public.nome_de_pessoa('MARIA APARECIDA DE SOUZA') || ' / ' || coalesce(public.nome_de_pessoa('  joão de sá '), 'nulo'));
select sim.confere('empresa, nome com número, sem vogal e vazio: nulo',
  public.nome_de_pessoa('Farol Negócios LTDA') is null and public.nome_de_pessoa('FAROL NEGOCIOS LTDA') is null
  and public.nome_de_pessoa('Igreja Batista Central') is null and public.nome_de_pessoa('Mercado 2 Irmaos') is null
  and public.nome_de_pessoa('2 Irmaos Silva') is null and public.nome_de_pessoa('Maria Souza 2') = 'Maria'
  and public.nome_de_pessoa('Zzz') is null and public.nome_de_pessoa('') is null and public.nome_de_pessoa(null) is null,
  concat_ws(' / ', public.nome_de_pessoa('Farol Negócios LTDA'), public.nome_de_pessoa('Igreja Batista Central'),
            public.nome_de_pessoa('Mercado 2 Irmaos'), public.nome_de_pessoa('Zzz')));

-- o clique: empresa e pessoa
insert into sim.cw (conv, telefone, nome) values
  ('996101', '5531999610001', 'Farol Negocios Ltda'), ('996102', '5531999610002', 'Maria X161');
insert into public.fila_vero (nome, telefone, segmento, status, template, wamid, codigo)
values ('FAROL NEGOCIOS LTDA', '5531999610001', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X161A', 'x161a001'),
       ('MARIA APARECIDA X161', '5531999610002', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X161B', 'x161b002');
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x161a001'), true, '996101') ->> 'acao_id') as a \gset
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x161b002'), true, '996102') ->> 'acao_id') as b \gset

select sim.confere('empresa: o template do clique sai sem "Farol" e com "tudo bem"',
  (select to_jsonb(x)::text !~* 'farol' and to_jsonb(x)::text ~ 'tudo bem' from public.chatwoot_acoes x where x.id = (:'a')::bigint),
  (select left(to_jsonb(x)::text, 400) from public.chatwoot_acoes x where x.id = (:'a')::bigint));
select sim.confere('pessoa: o template do clique sai com o 1º nome',
  (select to_jsonb(x)::text ~ 'Oi, Maria!' from public.chatwoot_acoes x where x.id = (:'b')::bigint),
  (select left(to_jsonb(x)::text, 400) from public.chatwoot_acoes x where x.id = (:'b')::bigint));

-- 1 h depois sem resposta: o texto pronto do Chamar por fora segue a mesma regra
select sim.passa((select conversa_id from public.fila_vero where codigo = 'x161a001'), interval '61 minutes');
select sim.passa((select conversa_id from public.fila_vero where codigo = 'x161b002'), interval '61 minutes');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('Chamar por fora da empresa: texto sem "Farol"',
  (select (x -> 'acoes')::text !~* 'farol' and (x -> 'acoes')::text ~ 'Oi, tudo bem' from jsonb_array_elements((:'f')::jsonb -> 'fila') x
    where x ->> 'conversa_id' = (select conversa_id::text from public.fila_vero where codigo = 'x161a001')),
  (select left(x::text, 500) from jsonb_array_elements((:'f')::jsonb -> 'fila') x
    where x ->> 'conversa_id' = (select conversa_id::text from public.fila_vero where codigo = 'x161a001')));
select sim.confere('Chamar por fora da pessoa: texto com "Oi, Maria"',
  (select (x -> 'acoes')::text ~ 'Oi, Maria!' from jsonb_array_elements((:'f')::jsonb -> 'fila') x
    where x ->> 'conversa_id' = (select conversa_id::text from public.fila_vero where codigo = 'x161b002')),
  (select left(x::text, 500) from jsonb_array_elements((:'f')::jsonb -> 'fila') x
    where x ->> 'conversa_id' = (select conversa_id::text from public.fila_vero where codigo = 'x161b002')));
