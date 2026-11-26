-- id: X135
-- titulo: 0406 (Ricardo 25/11): a agência só vê as campanhas que o admin liberou (nada liberado = nada), Google Ads não é dela, campanha nova entra sem dono e avisa o admin (1 vez, 8h–21h), gráficos e atendimento só em contagens, a prévia do admin dá o mesmo número que a agência vê
-- tipo: atual
select sim.como('servico');
update public.usuarios set perfil = 'agencia', ativo = true
 where id = (select id from public.usuarios where perfil = 'vendedor' and not ativo order by id limit 1);

-- as campanhas que já existiam ficaram com a Dharma
select sim.confere('toda campanha que já existia na cópia ficou com dono Dharma',
  not exists (select 1 from (select campanha_id from public.meta_ads_diario union select campanha_id from public.meta_ads_anuncios) x
               where x.campanha_id is not null
                 and not exists (select 1 from public.meta_ads_campanhas_dono d where d.campanha_id = x.campanha_id and d.dono = 'dharma')),
  (select count(*)::text from public.meta_ads_campanhas_dono));

-- a agência sobe uma campanha nova: a coleta grava o anúncio e o gasto; a campanha entra SEM dono
insert into public.meta_ads_anuncios (ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, status_efetivo, atualizado_em)
values ('adX135', 'AG_anuncio_X135', 'asX135', 'AG_conjunto_X135', 'cX135', 'AG_campanha_X135', 'ACTIVE', now());
insert into public.meta_ads_diario (dia, ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, gasto, impressoes, alcance, cliques, conversas, atualizado_em)
values ((now() at time zone 'America/Sao_Paulo')::date, 'adX135', 'AG_anuncio_X135', 'asX135', 'AG_conjunto_X135', 'cX135', 'AG_campanha_X135', 50, 4000, 3000, 80, 3, now());
select sim.confere('campanha nova da coleta entra na lista SEM dono (nunca liberada sozinha)',
  (select dono is null and campanha_nome = 'AG_campanha_X135' from public.meta_ads_campanhas_dono where campanha_id = 'cX135'), 'não entrou ou entrou com dono');

-- um lead que veio desse anúncio
select sim.lead_novo('Gil X135', 'Oi, vi o anúncio', '5531990001350') as g \gset
update public.mari_conversas set origem = 'meta_ads' where id = :'g';
insert into public.meta_referrals (parceiro_id, wamid, telefone, ad_id, source_type, recebido_em)
select 'dharma', 'wamid.X135', telefone, 'adX135', 'ad', created_at from public.mari_conversas where id = :'g';
select sim.confere('o lead aparece atribuído à campanha nova', exists (select 1 from public.v_mari_conversa_anuncio where conversa_id = :'g' and campanha_id = 'cX135'), 'sem atribuição');

-- o que cada um lê, com o RLS valendo
create temp table _x135 (k text primary key, v text);
grant all on _x135 to authenticated;
create or replace function pg_temp.le(p text) returns void language plpgsql as $$
declare q bigint;
begin
  insert into _x135 values (p || ':diario', (select count(*) from public.meta_ads_diario)::text),
                           (p || ':diario_x135', (select count(*) from public.meta_ads_diario where campanha_id = 'cX135')::text),
                           (p || ':anuncios', (select count(*) from public.meta_ads_anuncios)::text),
                           (p || ':conjuntos', (select count(*) from public.meta_ads_conjuntos)::text),
                           (p || ':posic', (select count(*) from public.meta_ads_posicionamento_diario)::text),
                           (p || ':google', ((select count(*) from public.google_ads_diario) + (select count(*) from public.google_ads_campanhas) + (select count(*) from public.google_ads_palavras))::text),
                           (p || ':google_dia', (select count(*) from public.google_ads_dia())::text),
                           (p || ':res', public.meta_ads_resultado()::text),
                           (p || ':graf', public.meta_ads_graficos(null, null)::text),
                           (p || ':atend', public.meta_ads_atendimento(null, null)::text),
                           (p || ':mot', public.meta_ads_motivos_saida(null, null)::text),
                           (p || ':dia_ag', (select coalesce(sum(gasto), 0) from public.meta_ads_dia(true))::text),
                           (p || ':dia_conta', (select coalesce(sum(gasto), 0) from public.meta_ads_dia())::text);
  begin
    q := (select count(*) from public.meta_ads_campanhas_dono);
  exception when others then q := -1;
  end;
  insert into _x135 values (p || ':donos', q::text);
end $$;

-- 1) nada liberado ainda: a agência não vê campanha nenhuma
select sim.como('agencia');
set session authorization authenticator; set role authenticated;
select pg_temp.le('ag0');
reset role; reset session authorization;
select sim.como('servico');
select sim.confere('sem campanha liberada, a agência não lê nenhuma linha da Meta nem do Google',
  (select string_agg(v, ',' order by k) from _x135 where k in ('ag0:diario', 'ag0:anuncios', 'ag0:conjuntos', 'ag0:posic', 'ag0:google', 'ag0:google_dia')) = '0,0,0,0,0,0',
  (select string_agg(k || '=' || v, ', ' order by k) from _x135 where k like 'ag0:%' and k not in ('ag0:res', 'ag0:graf', 'ag0:atend', 'ag0:mot')));
select sim.confere('sem campanha liberada, as funções da tela devolvem vazio à agência',
  jsonb_array_length((select v from _x135 where k = 'ag0:res')::jsonb -> 'conversas') = 0
    and jsonb_array_length((select v from _x135 where k = 'ag0:graf')::jsonb -> 'midia') = 0
    and ((select v from _x135 where k = 'ag0:atend')::jsonb -> 'total' ->> 'conversas')::int = 0
    and jsonb_array_length((select v from _x135 where k = 'ag0:mot')::jsonb -> 'leads') = 0,
  left((select v from _x135 where k = 'ag0:atend'), 200));
select sim.confere('a agência não lê a lista de donos das campanhas', (select v from _x135 where k = 'ag0:donos') in ('0', '-1'), (select v from _x135 where k = 'ag0:donos'));
select sim.confere('0409: sem o Placar, nem o dia a dia da conta inteira vai à agência (meta_ads_dia() sempre com o recorte)',
  (select v from _x135 where k = 'ag0:dia_conta')::numeric = 0, (select v from _x135 where k = 'ag0:dia_conta'));

-- quem não é admin não decide de quem é a campanha
select sim.como('agencia');
do $$ begin perform public.meta_ads_campanha_dono('cX135', 'agencia'); raise exception 'PASSOU'; exception when others then
  insert into _x135 values ('ag_dono', sqlerrm); end $$;
select sim.como('backoffice');
do $$ begin perform public.meta_ads_campanha_dono('cX135', 'agencia'); raise exception 'PASSOU'; exception when others then
  insert into _x135 values ('bo_dono', sqlerrm); end $$;
select sim.como('servico');
select sim.confere('agência e backoffice não mudam o dono da campanha (só o admin)',
  (select v from _x135 where k = 'ag_dono') <> 'PASSOU' and (select v from _x135 where k = 'bo_dono') <> 'PASSOU',
  (select v from _x135 where k = 'ag_dono') || ' / ' || (select v from _x135 where k = 'bo_dono'));

-- 2) o admin libera a campanha da agência
select sim.como('admin');
select public.meta_ads_campanha_dono('cX135', 'agencia') ->> 'dono' as dono_novo \gset
select (select count(*) from jsonb_array_elements(public.meta_ads_campanhas_lista()) x where x ->> 'campanha_id' = 'cX135' and (x ->> 'parece_agencia')::boolean) as lista_ok \gset
select sim.como('agencia');
set session authorization authenticator; set role authenticated;
select pg_temp.le('ag1');
reset role; reset session authorization;
-- a prévia do admin ("Ver como a agência") pede o mesmo recorte
select sim.como('admin');
set session authorization authenticator; set role authenticated;
select public.meta_ads_resultado(true)::text as pv_res, public.meta_ads_graficos(null, null, true)::text as pv_graf,
       public.meta_ads_atendimento(null, null, true)::text as pv_atend, public.meta_ads_motivos_saida(null, null, true)::text as pv_mot,
       (select coalesce(sum(gasto), 0) from public.meta_ads_dia(true))::text as pv_dia,
       public.meta_ads_resultado()::text as ad_res \gset
reset role; reset session authorization;
select sim.como('servico');
select sim.confere('o admin libera e a lista de Configurações mostra a campanha com a sugestão "parece da agência"', :'dono_novo' = 'agencia' and :lista_ok = 1, :'dono_novo');
select sim.confere('liberada, a agência lê só as linhas da campanha dela',
  (select v from _x135 where k = 'ag1:diario') = (select v from _x135 where k = 'ag1:diario_x135')
    and (select v from _x135 where k = 'ag1:diario')::int = (select count(*) from public.meta_ads_diario where campanha_id = 'cX135')
    and (select v from _x135 where k = 'ag1:anuncios')::int = 1,
  (select string_agg(k || '=' || v, ', ' order by k) from _x135 where k in ('ag1:diario', 'ag1:diario_x135', 'ag1:anuncios')));
select sim.confere('o resultado da agência conta só a conversa do anúncio dela',
  (select sum((x ->> 'n')::int) from jsonb_array_elements((select v from _x135 where k = 'ag1:res')::jsonb -> 'conversas') x) = 1
    and ((select v from _x135 where k = 'ag1:atend')::jsonb -> 'total' ->> 'conversas')::int = 1
    and (select sum((x ->> 'gasto')::numeric) from jsonb_array_elements((select v from _x135 where k = 'ag1:graf')::jsonb -> 'midia') x) = 50
    and (select v from _x135 where k = 'ag1:dia_ag')::numeric = 50,
  left((select v from _x135 where k = 'ag1:atend'), 200));
select sim.confere('a prévia do admin dá exatamente o número da agência',
  :'pv_res'::jsonb = (select v from _x135 where k = 'ag1:res')::jsonb and :'pv_graf'::jsonb = (select v from _x135 where k = 'ag1:graf')::jsonb
    and :'pv_atend'::jsonb = (select v from _x135 where k = 'ag1:atend')::jsonb and :'pv_mot'::jsonb = (select v from _x135 where k = 'ag1:mot')::jsonb
    and :'pv_dia'::numeric = (select v from _x135 where k = 'ag1:dia_ag')::numeric, 'diferente');
select sim.confere('o admin sem a prévia continua vendo todas as conversas de anúncio',
  (select sum((x ->> 'n')::int) from jsonb_array_elements(:'ad_res'::jsonb -> 'conversas') x) = (select count(*) from public.mari_conversas where origem = 'meta_ads'),
  (select sum((x ->> 'n')::int)::text from jsonb_array_elements(:'ad_res'::jsonb -> 'conversas') x));
select sim.confere('gráficos, atendimento e motivos vão à agência sem identificador (id de conversa, telefone, nome)',
  (select string_agg(v, ' ') from _x135 where k in ('ag1:graf', 'ag1:atend', 'ag1:mot', 'ag1:res'))
    !~* ('(telefone|conversa_id|lead_id|venda_id|Gil X135|5531990001350|' || :'g' || ')'),
  (select string_agg(substring(v from '(telefone|conversa_id|lead_id|venda_id|Gil X135|5531990001350)'), ',') from _x135 where k in ('ag1:graf', 'ag1:atend', 'ag1:mot', 'ag1:res')));
select sim.confere('Google Ads continua fora da agência mesmo com campanha liberada',
  (select v from _x135 where k = 'ag1:google') = '0' and (select v from _x135 where k = 'ag1:google_dia') = '0', 'leu Google');

-- 3) aviso ao admin: campanha nova sem dono → 1 aviso no celular (das 8h às 21h), nunca dois
insert into public.meta_ads_diario (dia, ad_id, ad_nome, adset_id, adset_nome, campanha_id, campanha_nome, gasto, impressoes, cliques, conversas, atualizado_em)
values ((now() at time zone 'America/Sao_Paulo')::date, 'adX135b', 'AG_b', 'asX135b', 'AG_b', 'cX135b', 'AG_campanha_X135_b', 5, 100, 2, 0, now());
insert into public.push_subscriptions (perfil, endpoint, keys, ativo)
select id, 'https://push.invalid/X135', '{"p256dh":"x","auth":"y"}'::jsonb, true from public.usuarios where perfil = 'admin' and ativo order by id limit 1
on conflict do nothing;
select extract(hour from now() at time zone 'America/Sao_Paulo')::int between 8 and 20 as no_horario \gset
select sim.como('servico');
select (select count(*) from jsonb_array_elements(public.push_pendentes()) x where x -> 'payload' ->> 'gatilho' = 'campanha_nova' and x -> 'payload' ->> 'tag' = 'campanha_nova:cX135b') as push1 \gset
select (select count(*) from jsonb_array_elements(public.push_pendentes()) x where x -> 'payload' ->> 'gatilho' = 'campanha_nova' and x -> 'payload' ->> 'tag' = 'campanha_nova:cX135b') as push2 \gset
select sim.confere('campanha nova avisa o admin no celular uma vez, em cada aparelho dele (das 8h às 21h; fora disso, nada até as 8h)',
  case when :'no_horario'::boolean then :push1 >= 1 and :push1 = (select count(*) from public.push_subscriptions s join public.usuarios x on x.id = s.perfil where s.ativo and x.ativo and x.perfil = 'admin') and :push2 = 0 and (select avisada_em is not null from public.meta_ads_campanhas_dono where campanha_id = 'cX135b')
       else :push1 = 0 and :push2 = 0 end,
  :'push1' || ' / ' || :'push2' || ' · no horário: ' || :'no_horario');
select sim.como('admin');
select public.meta_ads_campanhas_sem_dono() as menu_admin \gset
select sim.como('backoffice');
select public.meta_ads_campanhas_sem_dono() as menu_bo \gset
select sim.como('servico');
select sim.confere('o menu do admin conta as campanhas sem dono; o do backoffice não', :menu_admin >= 1 and :menu_bo = 0, :'menu_admin' || ' / ' || :'menu_bo');

-- 4) conferência
select sim.como('servico');
select sim.confere('conferência: agência continua sem leitura indevida (com o recorte por campanha)', public.agencia_leituras_indevidas() = '[]'::jsonb, public.agencia_leituras_indevidas()::text);
select sim.confere('conferência: campanha nova há menos de 24 h ainda não acusa',
  (select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'agencia_campanha_sem_dono') = 'ok', 'faltou ou acusou cedo');
update public.meta_ads_campanhas_dono set vista_em = now() - interval '2 days' where campanha_id = 'cX135b';
select sim.confere('conferência: campanha sem dono há mais de 24 h acusa em amarelo',
  (select x ->> 'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x ->> 'codigo' = 'agencia_campanha_sem_dono') = 'atencao', 'não acusou');
alter policy meta_ads_diario_agencia on public.meta_ads_diario using ((select public.sou_agencia()));
select sim.confere('conferência: policy da Meta sem o recorte por campanha é acusada',
  public.agencia_leituras_indevidas()::text ~ 'meta_ads_diario_agencia', public.agencia_leituras_indevidas()::text);
alter policy meta_ads_diario_agencia on public.meta_ads_diario using ((select public.sou_agencia()) and campanha_id in (select public.agencia_campanhas()));

-- 5) 0411: encerramento da Mari (handoff_em gravado) não conta como passada ao consultor; pedido de pessoa conta
update public.mari_conversas set handoff_motivo = 'fora_de_area', handoff_em = now() where id = :'g';
select sim.como('admin');
select (public.meta_ads_atendimento(null, null, true) -> 'total' ->> 'passadas_consultor')::int as pass_encerra \gset
select sim.como('servico');
update public.mari_conversas set handoff_motivo = 'pedido_humano', handoff_em = now() where id = :'g';
select sim.como('admin');
select (public.meta_ads_atendimento(null, null, true) -> 'total' ->> 'passadas_consultor')::int as pass_pede \gset
select sim.como('servico');
select sim.confere('atendimento: encerramento da Mari não conta como passada ao consultor; pedido de pessoa conta (0411)',
  :pass_encerra = 0 and :pass_pede = 1, :'pass_encerra' || ' / ' || :'pass_pede');
