-- id: X84
-- titulo: 0358 (regra 19, 22/11): a Live carrega as 8 leituras num pacote só (live_carga) — cada parte é igual à leitura que a tela fazia antes; quem não é do backoffice recebe null (a tela usa o caminho antigo)
-- tipo: atual
select sim.como('servico');
select sim.lead_novo('Fabi X84') as a \gset
select sim.mari_fala(:'a', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.lead_novo('Gal X84') as b \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'b', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'b', 'Oi, Gal! Me passa o seu CEP?');
select sim.fila_rodar();
select sim.venda_pronta('Hel X84', true) as c \gset

select sim.como('backoffice');
select public.live_carga()::text as k \gset
select sim.confere('o pacote vem para o backoffice, com as 8 partes',
  (:'k')::jsonb ?& array['pendencias', 'leads', 'mira', 'conferir', 'os', 'vendas', 'feitos', 'situacoes'], left(:'k', 200));
select sim.confere('situacoes = live_situacoes()',
  (:'k')::jsonb -> 'situacoes' = public.live_situacoes(), 'diferente');
select sim.confere('mira = live_na_mira() e conferir = live_conferir()',
  (:'k')::jsonb -> 'mira' = coalesce(public.live_na_mira(), '[]') and (:'k')::jsonb -> 'conferir' = coalesce(public.live_conferir(), '[]'), 'diferente');
select sim.confere('leads = as mesmas linhas da v_leads que a tela lia',
  (select count(*) from jsonb_array_elements((:'k')::jsonb -> 'leads')) = (select count(*) from public.v_leads)
  and exists (select 1 from jsonb_array_elements((:'k')::jsonb -> 'leads') x where x ->> 'conversa_id' = :'b'),
  (select count(*)::text from jsonb_array_elements((:'k')::jsonb -> 'leads')) || ' / ' || (select count(*)::text from public.v_leads));
select sim.confere('vendas = as vendas vivas da v_vendas',
  (select count(*) from jsonb_array_elements((:'k')::jsonb -> 'vendas'))
    = (select count(*) from public.v_vendas where status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')),
  (select count(*)::text from jsonb_array_elements((:'k')::jsonb -> 'vendas')));
select sim.confere('feitos conta as ações de hoje de quem chamou, pela porta',
  ((:'k')::jsonb ->> 'feitos')::int = (select count(*) from public.porta_sombra where por = auth.uid()
     and em >= (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')),
  (:'k')::jsonb ->> 'feitos');
select sim.como('servico');
select sim.confere('fora do backoffice/admin o pacote é null', public.live_carga() is null, 'veio pacote');
