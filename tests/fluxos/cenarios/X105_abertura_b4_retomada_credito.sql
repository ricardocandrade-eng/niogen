-- id: X105
-- titulo: 0381 (B4, Ricardo 24/11): o aviso de crédito aprovado pede a preferência de período quando falta (Parte 3); o D3 sai pela variante da etapa (nunca deu endereço · viu os planos · faltam os dados) só com o template aprovado — sem aprovação, o de sempre (Parte 4); a 1ª cutucada de quem não deu endereço é a saída honesta (BYAF); a Mari recebe o anúncio que abriu a conversa
-- tipo: atual

-- A) Crédito aprovado com plano e forma, sem a preferência de período: o aviso pede o período (sem prometer data)
select sim.lead_pronto('Ana X105') as a \gset
update public.mari_conversas set instalacao_preferencia = null where id = :'a';
select sim._servico();
select public.mari_credito_gravar(:'a', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select coalesce((select payload ->> 'content' from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem'
                  and payload ->> 'texto_chave' = 'bo_credito_aprovado_falta' order by criada_em desc limit 1), '') as ca \gset
select sim.confere('período: o aviso pede a preferência de manhã ou à tarde', :'ca' like '%de manhã ou à tarde%', :'ca');
select sim.confere('período: o aviso não fala de biometria nem promete data', :'ca' not ilike '%biometria%' and :'ca' not ilike '%agendad%', :'ca');

-- A2) Com o período combinado: o aviso de sempre (aprovado, sem pedir nada)
select sim.lead_pronto('Bia X105') as a2 \gset
select sim._servico();
select public.mari_credito_gravar(:'a2', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('período: com o período já dito, sai o aprovado de sempre',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'a2' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_aprovado'), null);

-- A3) Sem plano nem forma nem período: pede os três numa frase só
select sim.lead_novo('Caio X105') as a3 \gset
update public.mari_conversas set cep = '36010000', numero = '10', cidade = 'Juiz de Fora', uf = 'MG', dentro_area = true, segmento = 'varejo',
  dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('nome', 'Caio X105', 'cpf', sim.cpf(77), 'email', 'caio@exemplo.test')
 where id = :'a3';
select sim._servico();
select public.mari_credito_gravar(:'a3', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select coalesce((select payload ->> 'content' from public.chatwoot_acoes where conversa_id = :'a3' and tipo = 'mensagem'
                  and payload ->> 'texto_chave' = 'bo_credito_aprovado_falta' order by criada_em desc limit 1), '') as c3 \gset
select sim.confere('período: plano, forma e período na mesma pergunta',
  :'c3' like '%o plano, a forma de pagamento%' and :'c3' like '%e se prefere a instalação de manhã ou à tarde%', :'c3');

-- B) Variante do D3 pela etapa gravada
select sim.lead_novo('Duda X105') as b1 \gset
select (select tpl from public._retomada_variante((select m from public.mari_conversas m where m.id = :'b1'), 'Duda')) as t1 \gset
select sim.confere('variante: sem endereço → nio_retomada_d3_endereco', :'t1' = 'nio_retomada_d3_endereco', :'t1');
update public.mari_conversas set cep = '30110000', cidade = 'Belo Horizonte', uf = 'MG', cluster = 'regular', funil_etapa = 'viu_planos' where id = :'b1';
select (select tpl || ' | ' || (params ->> 1) from public._retomada_variante((select m from public.mari_conversas m where m.id = :'b1'), 'Duda')) as t2 \gset
select sim.confere('variante: viu os planos → planos, com a cidade e o "a partir de" do cluster dele',
  :'t2' = 'nio_retomada_d3_planos | os planos de fibra em Belo Horizonte, a partir de R$ ' ||
    (select trunc(min(preco))::text from public.config_planos where ativo and cluster = 'regular' and portfolio = 'varejo' and coalesce(variante, '') not ilike '%nfid%'
       and (vigencia_fim is null or vigencia_fim >= current_date)) || ' por mês', :'t2');
update public.mari_conversas set funil_etapa = 'area_ok' where id = :'b1';
select (select params ->> 1 from public._retomada_variante((select m from public.mari_conversas m where m.id = :'b1'), 'Duda')) as t3 \gset
select sim.confere('variante: deu endereço e não viu os planos → sem preço (nunca um valor que ele não viu)', :'t3' = 'os planos de fibra em Belo Horizonte', :'t3');
update public.mari_conversas set plano_escolhido = 'V-REG-FIBRA' where id = :'b1';
select (select tpl from public._retomada_variante((select m from public.mari_conversas m where m.id = :'b1'), 'Duda')) as t4 \gset
select sim.confere('variante: escolheu o plano → dados', :'t4' = 'nio_retomada_d3_dados', :'t4');
update public.config_mari_textos set texto = 'nao' where chave = 'retomada_variantes';
select count(*) as t5 from public._retomada_variante((select m from public.mari_conversas m where m.id = :'b1'), 'Duda') \gset
select sim.confere('variante: retomada_variantes = nao desliga', :t5 = 0, :'t5');
update public.config_mari_textos set texto = 'sim' where chave = 'retomada_variantes';

-- C) O D3 da escada: com o template da variante ainda PENDING sai o de sempre; aprovado, sai a variante
select sim.lead_novo('Edu X105') as c \gset
select sim.passa(:'c', interval '3 days 2 hours');
select coalesce((select proximo_passo || ':' || coalesce(template, '-') from public.mari_cadencia_avaliar(now(), :'c') limit 1), '?') as tc1 \gset
select sim.confere('D3: variante ainda não aprovada → nio_retomada_lead_d3', :'tc1' = 'D3:nio_retomada_lead_d3', :'tc1');
update public.config_templates_waba set status = 'APPROVED' where nome = 'nio_retomada_d3_endereco';
select coalesce((select proximo_passo || ':' || coalesce(template, '-') from public.mari_cadencia_avaliar(now(), :'c') limit 1), '?') as tc2 \gset
select sim.confere('D3: variante aprovada → nio_retomada_d3_endereco no lugar do D3 de sempre', :'tc2' = 'D3:nio_retomada_d3_endereco', :'tc2');
update public.config_templates_waba set status = 'PENDING' where nome = 'nio_retomada_d3_endereco';

-- D) 1ª cutucada de quem recebeu a abertura e não deu endereço = BYAF
select sim.lead_novo('Fabi X105') as d \gset
update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || '{"abertura": "b4_241126"}'::jsonb where id = :'d';
select public.mari_cadencia_texto((select m from public.mari_conversas m where m.id = :'d'), 'F1') as f1 \gset
select sim.confere('BYAF: a 1ª cutucada é a saída honesta', :'f1' like '%se não for o momento, sem problema nenhum%', :'f1');

-- E) A Mari recebe o anúncio que abriu a conversa (só antes de falar)
select sim.lead_novo('Gil X105', 'Oi, vi o anúncio', '5531990001055') as e \gset
update public.mari_conversas set ultima_msg_mari_at = null where id = :'e';
insert into public.meta_referrals (wamid, telefone, ad_id, source_type, titulo, recebido_em)
values ('wamid.X105', '5531990001055', '999000105', 'ad', 'Teste X105', now());
select (public.mari_contexto(:'e') -> 'anuncio' ->> 'ad_id') as ae \gset
select sim.confere('anúncio: o contexto traz o ad_id do referral', :'ae' = '999000105', :'ae');
update public.mari_conversas set ultima_msg_mari_at = now() where id = :'e';
select coalesce(public.mari_contexto(:'e') ->> 'anuncio', '') as ae2 \gset
select sim.confere('anúncio: depois da 1ª fala da Mari, não lê mais', :'ae2' = '', :'ae2');
