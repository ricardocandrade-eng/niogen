-- id: X86
-- titulo: 0360 (regra 19, 22/11): conversas_lista() e leads_lista() devolvem ao backoffice exatamente as linhas e colunas da v_conversas e da v_leads; quem não é do backoffice/admin não recebe nada (a tela usa a visão, com o RLS de sempre)
-- tipo: atual
select sim.como('servico');
select sim.lead_novo('Ivo X86') as a \gset
select sim.mari_fala(:'a', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.lead_novo('Jade X86') as b \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'b', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'b', 'Oi, Jade! Me passa o seu CEP?');
select sim.fila_rodar();
select sim.venda_pronta('Kai X86', true) as c \gset

select sim.como('backoffice');
select sim.confere('conversas_lista() traz as conversas do cenário',
  (select count(*) from public.conversas_lista() where id in (:'a', :'b', :'c')) = 3,
  (select count(*)::text from public.conversas_lista()));
select sim.confere('conversas_lista() = v_conversas (mesmas linhas, mesmas colunas, mesmos valores)',
  (select jsonb_agg(to_jsonb(x) order by x.id) from public.v_conversas x)
    = (select jsonb_agg(to_jsonb(y) order by y.id) from public.conversas_lista() y),
  (select count(*)::text from public.v_conversas) || ' na visão / ' || (select count(*)::text from public.conversas_lista()) || ' na função');
select sim.confere('leads_lista() traz os leads do cenário',
  (select count(*) from public.leads_lista() where conversa_id in (:'a', :'b', :'c')) = 3,
  (select count(*)::text from public.leads_lista()));
select sim.confere('leads_lista() = v_leads (mesmas linhas, mesmas colunas, mesmos valores)',
  (select jsonb_agg(to_jsonb(x) order by x.lead_id) from public.v_leads x)
    = (select jsonb_agg(to_jsonb(y) order by y.lead_id) from public.leads_lista() y),
  (select count(*)::text from public.v_leads) || ' na visão / ' || (select count(*)::text from public.leads_lista()) || ' na função');
select sim.confere('a coluna "meu" segue quem chamou (a conversa que o backoffice assumiu é dele)',
  (select bool_or(meu) from public.leads_lista() where conversa_id = :'b') is not distinct from (select bool_or(meu) from public.v_leads where conversa_id = :'b'),
  'diferente da visão');
select sim.como('servico');
select sim.confere('fora do backoffice/admin as duas funções não devolvem nada',
  (select count(*) from public.conversas_lista()) = 0 and (select count(*) from public.leads_lista()) = 0, 'veio linha');
