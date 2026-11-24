-- id: X35
-- titulo: Medidor de canais (0302): lead sem marca nasce "desconhecida" (não "direto"), com referral do anúncio nasce Meta Ads, o referral que chega depois corrige, o backoffice corrige a origem e o Conferir limpa; custo à mão só do admin e nunca da Meta
-- tipo: atual
-- premissa (24/11, portão da 0378/0379): a cópia do banco vem do backup do dia e já traz a coleta real do Google — o cenário
-- começa sem ela (o banco do cenário é descartável)
delete from public.google_ads_diario; delete from public.google_ads_palavras; delete from public.google_ads_campanhas; delete from public.google_ads_conta;
-- 1) sem marca no texto e sem referral → desconhecida, e aparece no Conferir
select sim.lead_novo('Orin X35', 'Oi, quero saber da internet') as c \gset
select sim.confere('sem marca e sem referral, a origem é desconhecida (não mais direto)',
  (select origem from public.mari_conversas where id = :'c') = 'desconhecida', (select origem from public.mari_conversas where id = :'c'));
select sim.como('backoffice');
select sim.confere('o Conferir aponta o lead sem origem',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens()) x
           where x ->> 'codigo' = 'origem_desconhecida' and x ->> 'nivel' = 'atencao' and x ->> 'texto' like '%Orin X35%'),
  (select x::text from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'origem_desconhecida'));

-- 2) o backoffice pergunta ao cliente e corrige: sai do Conferir, fica na trilha com o autor
select (public.conversa_origem_corrigir(:'c', 'gmn', 'achou no Google')) ->> 'para' as para \gset
select sim.confere('a origem foi corrigida para Google Meu Negócio', (select origem from public.mari_conversas where id = :'c') = 'gmn', :'para');
select sim.confere('a correção fica na trilha da conversa',
  exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'sistema' and t.texto like '[origem corrigida de "desconhecida"%'), '');
select sim.confere('corrigido, o lead sai do Conferir',
  not exists (select 1 from jsonb_array_elements(public.conferencia_itens()) x
               where x ->> 'codigo' = 'origem_desconhecida' and x ->> 'texto' like '%Orin X35%'), '');
select sim.confere('não dá para "corrigir" para desconhecida',
  sim.recusa(format($q$select public.conversa_origem_corrigir(%L, 'desconhecida')$q$, :'c')) is not null, '');
select sim.confere('o card conta a conversa no canal novo',
  (select conversas from public.canais_resumo(7) where canal = 'gmn') >= 1, '');

-- 3) o anúncio deixou o referral antes da 1ª mensagem → Meta Ads
select sim.como('servico');
select '55319' || lpad((70000000 + floor(random() * 9999999))::bigint::text, 8, '0') as tel \gset
insert into public.meta_referrals (wamid, telefone, ad_id, source_type, recebido_em) values ('wamid.x35a', :'tel', '120000000000001', 'ad', now());
select sim.lead_novo('Ana X35', 'Oi! Quero saber se chega na minha rua', :'tel') as c2 \gset
select sim.confere('com o referral do anúncio, nasce Meta Ads', (select origem from public.mari_conversas where id = :'c2') = 'meta_ads',
  (select origem from public.mari_conversas where id = :'c2'));

-- 4) o referral chega DEPOIS da 1ª mensagem → a conversa é corrigida para Meta Ads
select sim.lead_novo('Bia X35', 'Oi, tudo bem?') as c3 \gset
select sim.confere('sem referral ainda, desconhecida', (select origem from public.mari_conversas where id = :'c3') = 'desconhecida', '');
select sim.como('servico');
select public.meta_referral_gravar(jsonb_build_object('messages', jsonb_build_array(jsonb_build_object(
  'id', 'wamid.x35b', 'from', (select telefone from public.mari_conversas where id = :'c3'),
  'timestamp', floor(extract(epoch from now()))::bigint::text,
  'referral', jsonb_build_object('source_type', 'ad', 'source_id', '120000000000002')))));
select sim.confere('o referral que chegou depois corrige para Meta Ads', (select origem from public.mari_conversas where id = :'c3') = 'meta_ads',
  (select origem from public.mari_conversas where id = :'c3'));

-- 5) custo por canal: só o admin digita, e nunca o da Meta (vem do meta_ads_diario)
select sim.como('backoffice');
select sim.confere('backoffice não grava custo',
  sim.recusa($q$select public.canal_custo_gravar('google_ads', current_date, 50)$q$) is not null, '');
select sim.como('admin');
select public.canal_custo_gravar('google_ads', (now() at time zone 'America/Sao_Paulo')::date, 50);
select sim.confere('o admin grava o custo do Google e ele entra no card',
  (select gasto from public.canais_resumo(7) where canal = 'google_ads') >= 50, '');
select sim.confere('custo da Meta não se digita',
  sim.recusa($q$select public.canal_custo_gravar('meta_ads', current_date, 10)$q$) is not null, '');
select sim.confere('o card fecha com a v_margem_canal',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'canais_conta' and x ->> 'nivel' = 'ok'),
  (select x::text from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'canais_conta'));
select sim.como('servico');
