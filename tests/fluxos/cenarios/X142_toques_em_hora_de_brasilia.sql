-- id: X142
-- titulo: Fuso encerrado (0422, Ricardo 26/11: "Vamos encerrar o fuso e ajustar a janela para 7h-21h"): os toques 9h–21h saem em hora de Brasília em TODOS os estados — Cuiabá (8h locais) e Rio Branco (7h locais) recebem junto com Juiz de Fora; nenhuma função de horário chama area_fuso (era o que deixava a ficha em 9 s); as 6 UFs seguem ligadas
-- tipo: atual

-- A) o fuso da cidade continua gravado, só como dado da UF
select sim.confere('fuso (dado): Cuiabá, Rio Branco, Manaus, Juiz de Fora e cidade desconhecida',
  public.area_fuso('Cuiabá') = 'America/Cuiaba' and public.area_fuso('Rio Branco') = 'America/Rio_Branco'
  and public.area_fuso('Manaus') = 'America/Manaus' and public.area_fuso('Juiz de Fora') = 'America/Sao_Paulo'
  and public.area_fuso(null) = 'America/Sao_Paulo' and public.area_fuso('Cidade Que Não Existe') = 'America/Sao_Paulo', null);
select sim.confere('25 cidades fora do fuso de Brasília, todas com o fuso da UF',
  (select count(*) from public.config_area where fuso <> 'America/Sao_Paulo') = 25
  and not exists (select 1 from public.config_area where fuso is distinct from public._area_fuso_uf(uf)), null);

-- B) a janela em hora de Brasília para todo mundo (01/12/2026, terça, sem feriado)
select sim.confere('12h00 UTC = 9h Brasília: Juiz de Fora, Cuiabá (8h locais) e Rio Branco (7h locais) no horário',
  public.mari_no_horario('2026-12-01 12:00+00', 'Juiz de Fora') and public.mari_no_horario('2026-12-01 12:00+00', 'Cuiabá')
  and public.mari_no_horario('2026-12-01 12:00+00', 'Rio Branco'), null);
select sim.confere('11h59 UTC = 8h59 Brasília: ninguém no horário',
  not public.mari_no_horario('2026-12-01 11:59+00', 'Juiz de Fora') and not public.mari_no_horario('2026-12-01 11:59+00', 'Cuiabá')
  and not public.mari_no_horario('2026-12-01 11:59+00', 'Rio Branco'), null);
select sim.confere('00h30 UTC = 21h30 em Brasília: fora para Juiz de Fora e para Cuiabá (20h30 locais)',
  not public.mari_no_horario('2026-12-02 00:30+00', 'Juiz de Fora') and not public.mari_no_horario('2026-12-02 00:30+00', 'Cuiabá'), null);
select sim.confere('próximo horário de Rio Branco a partir das 11h UTC = 12h UTC (9h de Brasília, 7h locais)',
  public.mari_proximo_horario('2026-12-01 11:00+00', 'Rio Branco') = '2026-12-01 12:00+00',
  public.mari_proximo_horario('2026-12-01 11:00+00', 'Rio Branco')::text);
select sim.confere('próximo horário de Juiz de Fora (11h UTC → 12h UTC)',
  public.mari_proximo_horario('2026-12-01 11:00+00', 'Juiz de Fora') = '2026-12-01 12:00+00', null);
select sim.confere('a janela configurada segue 9h–21h',
  (select valor ->> 'abre' = '09:00' and valor ->> 'fecha' = '21:00' from public.config_regras where chave = 'mari_horario_toques'), null);

-- C) desempenho: nenhuma função de horário chama o fuso por cidade (com RLS, area_fuso custa ~12 ms por chamada e a cadência
--    chamava dezenas de vezes por conversa — v_mari_quadro de uma conversa foi a 9,2 s e a ficha junto)
select sim.confere('mari_cadencia_avaliar, _retomada_tick, mari_no_horario e mari_proximo_horario sem area_fuso nem _cidade_toque',
  (select count(*) = 4 and bool_and(prosrc !~ 'area_fuso|_cidade_toque')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('mari_cadencia_avaliar', '_retomada_tick', 'mari_no_horario', 'mari_proximo_horario')), null);

-- D) carga: cidade nova de MT ainda nasce com o fuso de MT (dado)
insert into public.config_area (cidade, uf, ativo, cluster) values ('Cidade Teste X142', 'MT', false, 'regular');
select sim.confere('cidade nova de MT ganha America/Cuiaba pelo trigger',
  (select fuso from public.config_area where cidade = 'Cidade Teste X142') = 'America/Cuiaba', null);
delete from public.config_area where cidade = 'Cidade Teste X142';

-- E) as 6 UFs seguem ligadas e a conferência verde
select sim.confere('AC, AM, RR, RO, MT e MS ligadas (345 ativas)', (select count(*) from public.config_area where ativo) = 345, null);
select sim.confere('conferência: item area_fuso ok',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_fuso' and i ->> 'nivel' = 'ok'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_fuso'));

-- F) um lead de Cuiabá: às 9h de Brasília (8h locais) a Mari já está no horário, e a cadência avalia a conversa sem erro
select sim.lead_pronto('Cuca X142') as a \gset
select sim._servico();
update public.mari_conversas set cep = '78005000', cidade = 'Cuiabá', uf = 'MT', cluster = 'regular', dentro_area = true,
       endereco_cep = jsonb_build_object('logradouro', 'Rua Simulada', 'bairro', 'Centro', 'localidade', 'Cuiabá', 'uf', 'MT')
 where id = :'a';
select sim.confere('o horário que a Mari usa para Cuiabá às 12h UTC diz "dentro"',
  public.mari_no_horario('2026-12-01 12:00+00', (select cidade from public.mari_conversas where id = :'a')), null);
select sim.confere('a cadência avalia o lead de Cuiabá sem erro',
  (select count(*) from public.mari_cadencia_avaliar('2026-12-01 12:00+00'::timestamptz, :'a'::uuid)) >= 0, null);
