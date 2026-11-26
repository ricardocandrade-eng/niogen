-- id: X142
-- titulo: Fuso por UF (0418, Ricardo 26/11: "Coluna fuso por UF"): os toques 9h–21h valem na hora do cliente — Cuiabá (−4) e Rio Branco (−5) só recebem a partir das 9h locais; sem cidade, o DDD 65/68/… diz o fuso; o resto do país continua em Brasília; as 6 UFs ficam ligadas
-- tipo: atual

-- A) fuso da cidade e da UF
select sim.confere('fuso: Cuiabá, Rio Branco, Manaus, Juiz de Fora e cidade desconhecida',
  public.area_fuso('Cuiabá') = 'America/Cuiaba' and public.area_fuso('Rio Branco') = 'America/Rio_Branco'
  and public.area_fuso('Manaus') = 'America/Manaus' and public.area_fuso('Juiz de Fora') = 'America/Sao_Paulo'
  and public.area_fuso(null) = 'America/Sao_Paulo' and public.area_fuso('Cidade Que Não Existe') = 'America/Sao_Paulo', null);
select sim.confere('25 cidades fora do fuso de Brasília, todas com o fuso da UF',
  (select count(*) from public.config_area where fuso <> 'America/Sao_Paulo') = 25
  and not exists (select 1 from public.config_area where fuso is distinct from public._area_fuso_uf(uf)), null);

-- B) a janela na hora do cliente (01/12/2026, terça, sem feriado)
select sim.confere('12h00 UTC = 9h Brasília: Juiz de Fora no horário, Cuiabá (8h) e Rio Branco (7h) fora',
  public.mari_no_horario('2026-12-01 12:00+00', 'Juiz de Fora') and not public.mari_no_horario('2026-12-01 12:00+00', 'Cuiabá')
  and not public.mari_no_horario('2026-12-01 12:00+00', 'Rio Branco'), null);
select sim.confere('13h00 UTC: Cuiabá (9h) entra; Rio Branco (8h) ainda não',
  public.mari_no_horario('2026-12-01 13:00+00', 'Cuiabá') and not public.mari_no_horario('2026-12-01 13:00+00', 'Rio Branco'), null);
select sim.confere('00h30 UTC = 21h30 em Brasília (fora) e 20h30 em Cuiabá (dentro)',
  not public.mari_no_horario('2026-12-02 00:30+00', 'Juiz de Fora') and public.mari_no_horario('2026-12-02 00:30+00', 'Cuiabá'), null);
select sim.confere('próximo horário de Rio Branco a partir das 11h UTC = 14h UTC (9h locais)',
  public.mari_proximo_horario('2026-12-01 11:00+00', 'Rio Branco') = '2026-12-01 14:00+00',
  public.mari_proximo_horario('2026-12-01 11:00+00', 'Rio Branco')::text);
select sim.confere('próximo horário de Juiz de Fora não mudou (11h UTC → 12h UTC)',
  public.mari_proximo_horario('2026-12-01 11:00+00', 'Juiz de Fora') = '2026-12-01 12:00+00', null);

-- C) conversa sem cidade: o DDD dos estados de outro fuso decide; os outros DDDs seguem em Brasília
select sim.confere('DDD 65 → Cuiabá, 68 → Rio Branco, 97 → Manaus; DDD 32 → sem cidade (Brasília)',
  public._cidade_toque(null, '5565999990000') = 'Cuiabá' and public._cidade_toque('', '(68) 99999-0000') = 'Rio Branco'
  and public._cidade_toque(null, '5597999990000') = 'Manaus' and public._cidade_toque(null, '5532999990000') is null
  and public._cidade_toque('Juiz de Fora', '5565999990000') = 'Juiz de Fora', null);

-- D) a cadência e a Retomada não têm mais fuso fixo e passam a cidade do DDD
select sim.confere('mari_cadencia_avaliar e _retomada_tick sem America/Sao_Paulo fixo, com _cidade_toque',
  (select bool_and(prosrc !~ 'America/Sao_Paulo' and prosrc ~ '_cidade_toque\(c\.cidade, c\.telefone\)')
     from pg_proc where proname in ('mari_cadencia_avaliar', '_retomada_tick')), null);

-- E) carga: cidade nova de MT nasce com o fuso de MT
insert into public.config_area (cidade, uf, ativo, cluster) values ('Cidade Teste X142', 'MT', false, 'regular');
select sim.confere('cidade nova de MT ganha America/Cuiaba pelo trigger',
  (select fuso from public.config_area where cidade = 'Cidade Teste X142') = 'America/Cuiaba', null);
delete from public.config_area where cidade = 'Cidade Teste X142';

-- F) as 6 UFs ligadas e a conferência verde
select sim.confere('AC, AM, RR, RO, MT e MS ligadas (345 ativas)', (select count(*) from public.config_area where ativo) = 345, null);
select sim.confere('conferência: item area_fuso ok',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_fuso' and i ->> 'nivel' = 'ok'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_fuso'));

-- G) um lead de Cuiabá com venda: o lembrete não sai às 8h locais
select sim.lead_pronto('Cuca X142') as a \gset
select sim._servico();
update public.mari_conversas set cep = '78005000', cidade = 'Cuiabá', uf = 'MT', cluster = 'regular', dentro_area = true,
       endereco_cep = jsonb_build_object('logradouro', 'Rua Simulada', 'bairro', 'Centro', 'localidade', 'Cuiabá', 'uf', 'MT')
 where id = :'a';
select sim.confere('o horário que a Mari usa para Cuiabá às 12h UTC diz "fora"',
  not public.mari_no_horario('2026-12-01 12:00+00', (select cidade from public.mari_conversas where id = :'a')), null);
